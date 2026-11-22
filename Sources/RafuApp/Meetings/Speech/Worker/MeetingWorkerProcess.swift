import Foundation
import RafuCore
import Synchronization

/// The result of one after-Stop helper job.
nonisolated struct MeetingWorkerFileResult: Sendable, Equatable {
    var words: [MeetingWord] = []
    var segments: [MeetingSpeakerSegment] = []
    var loadMilliseconds: Int?
    var coldLoad: Bool?
    var peakFootprintBytes: Int64?
    var audioSeconds: Double?
    var wallSeconds: Double = 0
}

/// Every running helper, so the app can end them all at quit with no
/// await (`NSApplication.willTerminateNotification` runs synchronously).
nonisolated final class MeetingWorkerRegistry: Sendable {
    private let connections = Mutex([ObjectIdentifier: any MeetingWorkerConnection]())

    func add(_ connection: any MeetingWorkerConnection) {
        connections.withLock { $0[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: any MeetingWorkerConnection) {
        _ = connections.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    var count: Int { connections.withLock { $0.count } }

    /// SIGTERM to each helper. Each helper also exits by itself when the
    /// app ends (it watches its parent).
    func terminateAll() {
        let all = connections.withLock { Array($0.values) }
        for connection in all { connection.terminate() }
    }
}

/// Starts helper processes and runs the after-Stop jobs, one at a time.
/// A live helper (`MeetingWorkerLiveHub`) can run beside an after-Stop job.
actor MeetingWorkerProcess {
    nonisolated let helperURL: URL?
    nonisolated let registry: MeetingWorkerRegistry
    private let launcher: any MeetingWorkerLaunching
    private let diagnostics: any MeetingDiagnosticsRecording
    private let environment: [String: String]

    private var jobRunning = false
    private var jobWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentJob: (any MeetingWorkerConnection)?
    private var currentJobStoppedForMemory = false

    init(
        helperURL: URL?,
        launcher: any MeetingWorkerLaunching = MeetingWorkerProcessLauncher(),
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: MeetingWorkerRegistry = MeetingWorkerRegistry()
    ) {
        self.helperURL = helperURL
        self.launcher = launcher
        self.diagnostics = diagnostics
        self.environment = Self.helperEnvironment(from: environment)
        self.registry = registry
    }

    /// The helper in this app bundle, when it is there and executable.
    nonisolated static func bundledHelperURL(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/RafuMeetingsWorker")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The helper's environment: `PATH`, `HOME` and `TMPDIR`, nothing else.
    nonisolated static func helperEnvironment(from environment: [String: String]) -> [String:
        String]
    {
        var result: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR"] {
            if let value = environment[key] { result[key] = value }
        }
        return result
    }

    /// Starts one helper for `mode` and sends it the request line.
    func launch(mode: MeetingWorkerMode, request: MeetingWorkerRequest) throws(MeetingWorkerError)
        -> any MeetingWorkerConnection
    {
        guard let helperURL else { throw .helperMissing }
        let line: Data
        do {
            line = try request.encodedLine()
        } catch {
            throw .badRequest
        }
        let connection: any MeetingWorkerConnection
        do {
            connection = try launcher.launch(
                MeetingWorkerLaunchSpec(
                    executableURL: helperURL, arguments: MeetingWorkerArguments.make(mode: mode),
                    environment: environment))
        } catch {
            throw .launchFailed
        }
        registry.add(connection)
        diagnostics.record(
            .helperStarted(mode: mode.diagnosticMode, engine: request.engine.anyEngineID),
            meeting: nil)
        connection.send(line, droppable: false)
        return connection
    }

    // MARK: - After-Stop jobs

    /// Runs one after-Stop job (final text or speakers) and returns its
    /// result. Jobs wait for each other: one runs at a time.
    func runFileJob(
        mode: MeetingWorkerMode, request: MeetingWorkerRequest, meeting: MeetingID?,
        progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws(MeetingWorkerError) -> MeetingWorkerFileResult {
        await acquireJobSlot()
        defer { releaseJobSlot() }
        if Task.isCancelled { throw .cancelled }

        let started = ContinuousClock.now
        let connection = try launch(mode: mode, request: request)
        currentJob = connection
        currentJobStoppedForMemory = false

        let outcome = await withTaskCancellationHandler {
            await Self.readFileJob(connection: connection, progress: progress)
        } onCancel: {
            connection.terminate()
        }
        let termination = await connection.termination()
        connection.closeInput()
        registry.remove(connection)
        currentJob = nil

        var result = outcome.result
        result.wallSeconds = Self.seconds(ContinuousClock.now - started)
        recordExit(mode: mode, termination: termination, result: result, meeting: meeting)
        if let lastError = outcome.lastError {
            diagnostics.record(
                .engineError(
                    engine: request.engine.anyEngineID,
                    domain: MeetingDiagnosticString("worker.\(lastError.0.rawValue)"),
                    code: lastError.1),
                meeting: meeting)
        }

        if currentJobStoppedForMemory { throw .memoryPressure }
        if Task.isCancelled { throw .cancelled }
        if outcome.protocolViolation { throw .protocolViolation }
        guard outcome.sawDone, termination == .exited(MeetingWorkerExitCode.done.rawValue) else {
            throw MeetingWorkerError.from(
                termination: termination, lastError: outcome.lastError, model: request.engine.model)
        }
        recordSuccess(mode: mode, request: request, result: result, meeting: meeting)
        return result
    }

    private struct FileJobOutcome: Sendable {
        var result = MeetingWorkerFileResult()
        var sawDone = false
        var lastError: (MeetingWorkerErrorDomain, Int)?
        var protocolViolation = false
    }

    /// Reads the helper's lines until standard output closes. Runs off the
    /// actor; the reads are bounded by the line splitter.
    private nonisolated static func readFileJob(
        connection: any MeetingWorkerConnection,
        progress: @Sendable (MeetingEngineProgress) -> Void
    ) async -> FileJobOutcome {
        var outcome = FileJobOutcome()
        var splitter = MeetingWorkerLineSplitter()
        for await bytes in connection.output {
            let lines: [Data]
            do {
                lines = try splitter.append(bytes)
            } catch {
                outcome.protocolViolation = true
                connection.terminate()
                break
            }
            for line in lines {
                let event: MeetingWorkerEvent
                do {
                    event = try MeetingWorkerEvent.decode(line: line)
                } catch {
                    outcome.protocolViolation = true
                    connection.terminate()
                    return outcome
                }
                switch event {
                case .ready(let loadMs, let cold):
                    outcome.result.loadMilliseconds = loadMs
                    outcome.result.coldLoad = cold
                case .preparing:
                    progress(.preparingModel)
                case .progress(let fraction):
                    progress(.working(fraction: fraction))
                case .final(_, let words):
                    outcome.result.words.append(contentsOf: words)
                case .segments(let segments):
                    outcome.result.segments.append(contentsOf: segments)
                case .stats(let peak, _, _):
                    outcome.result.peakFootprintBytes = peak
                case .done(let audioSeconds):
                    outcome.result.audioSeconds = audioSeconds
                    outcome.sawDone = true
                    // The job is over: closing input lets the helper exit.
                    connection.closeInput()
                case .error(let domain, let code):
                    outcome.lastError = (domain, code)
                case .volatile:
                    outcome.protocolViolation = true
                    connection.terminate()
                    return outcome
                }
            }
        }
        return outcome
    }

    private func acquireJobSlot() async {
        if !jobRunning {
            jobRunning = true
            return
        }
        await withCheckedContinuation { jobWaiters.append($0) }
    }

    private func releaseJobSlot() {
        if jobWaiters.isEmpty {
            jobRunning = false
        } else {
            jobWaiters.removeFirst().resume()
        }
    }

    /// Critical memory pressure: stop the after-Stop job. The audio stays;
    /// the caller gets `.memoryPressure`.
    func stopFileJobForMemoryPressure() {
        guard let currentJob else { return }
        currentJobStoppedForMemory = true
        diagnostics.record(
            .helperRestarted(mode: .finalText, reason: .memoryPressure), meeting: nil)
        currentJob.terminate()
    }

    /// True while an after-Stop job runs (for tests).
    var isRunningFileJob: Bool { currentJob != nil }

    // MARK: - Diagnostics

    private func recordExit(
        mode: MeetingWorkerMode, termination: MeetingWorkerTermination,
        result: MeetingWorkerFileResult, meeting: MeetingID?
    ) {
        Self.recordExit(
            diagnostics: diagnostics, mode: mode, termination: termination,
            wallSeconds: result.wallSeconds, peak: result.peakFootprintBytes, meeting: meeting)
    }

    nonisolated static func recordExit(
        diagnostics: any MeetingDiagnosticsRecording, mode: MeetingWorkerMode,
        termination: MeetingWorkerTermination, wallSeconds: Double, peak: Int64?,
        meeting: MeetingID?
    ) {
        let code: Int32?
        let signal: Int32?
        switch termination {
        case .exited(let value):
            code = value
            signal = nil
        case .signalled(let value):
            code = nil
            signal = value
        }
        diagnostics.record(
            .helperExited(
                mode: mode.diagnosticMode, exitCode: code, signal: signal, wallSeconds: wallSeconds,
                peakFootprintBytes: peak),
            meeting: meeting)
    }

    private func recordSuccess(
        mode: MeetingWorkerMode, request: MeetingWorkerRequest, result: MeetingWorkerFileResult,
        meeting: MeetingID?
    ) {
        let revision = MeetingDiagnosticString(
            URL(fileURLWithPath: request.modelFolder).lastPathComponent)
        if let loadMs = result.loadMilliseconds, case .text(let engine) = request.engine.anyEngineID
        {
            diagnostics.record(
                .textEngineLoaded(
                    engine: engine, model: request.engine.model, modelRevision: revision,
                    loadMilliseconds: loadMs, isCold: result.coldLoad ?? false),
                meeting: meeting)
        }
        switch request.engine.anyEngineID {
        case .text:
            break
        case .speaker(let engine):
            diagnostics.record(
                .speakersDone(
                    engine: engine, modelRevision: revision, audioSeconds: result.audioSeconds ?? 0,
                    wallSeconds: result.wallSeconds,
                    speakerCount: Set(result.segments.map(\.speaker)).count,
                    segmentCount: result.segments.count),
                meeting: meeting)
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
