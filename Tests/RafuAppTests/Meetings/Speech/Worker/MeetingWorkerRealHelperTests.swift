import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Tests that start the real helper. The request tests need only the built
/// helper (`.build/debug/RafuMeetingsWorker`, or `RAFU_MEETINGS_WORKER_BINARY`).
/// The engine tests also need `RAFU_MEETINGS_MODEL_DIR`: a folder with one
/// sub-folder for each model id (`nemotron-en-1120ms`,
/// `whisperkit-large-v3-626mb`, `nemotron-3-fast32`, `speakerkit-pyannote`),
/// each in the layout its load call needs. `RAFU_MEETINGS_TEST_AUDIO` can
/// name a short synthetic speech file; else the test makes 4 s of noise.
@Suite("Meetings speech worker, real helper", .serialized)
struct MeetingWorkerRealHelperTests {
    static let environment = ProcessInfo.processInfo.environment

    static let helperBinary: URL? = {
        if let path = environment["RAFU_MEETINGS_WORKER_BINARY"] {
            return URL(fileURLWithPath: path)
        }
        // Tests/RafuAppTests/Meetings/Speech/Worker/<file> → repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let built = root.appendingPathComponent(".build/debug/RafuMeetingsWorker")
        return FileManager.default.isExecutableFile(atPath: built.path) ? built : nil
    }()

    static let modelRoot: URL? = environment["RAFU_MEETINGS_MODEL_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    static var hasHelper: Bool { helperBinary != nil }
    static var hasModels: Bool { helperBinary != nil && modelRoot != nil }

    /// Runs one helper and collects its lines, the time from `done` to the
    /// exit, and the exit.
    struct Run {
        var events: [MeetingWorkerEvent] = []
        var termination: MeetingWorkerTermination?
        var secondsFromDoneToExit: Double?
    }

    static func run(
        mode: MeetingWorkerMode, request: Data, frames: [MeetingWorkerFrame] = []
    ) async throws -> Run {
        let helper = try #require(helperBinary)
        let connection = try MeetingWorkerProcessLauncher().launch(
            MeetingWorkerLaunchSpec(
                executableURL: helper, arguments: MeetingWorkerArguments.make(mode: mode),
                environment: MeetingWorkerProcess.helperEnvironment(
                    from: ProcessInfo.processInfo.environment)))
        connection.send(request, droppable: false)
        for frame in frames { connection.send(frame.encoded(), droppable: false) }
        if mode == .liveText { connection.closeInput() }
        var run = Run()
        var splitter = MeetingWorkerLineSplitter()
        var doneAt: ContinuousClock.Instant?
        for await bytes in connection.output {
            for line in try splitter.append(bytes) {
                let event = try MeetingWorkerEvent.decode(line: line)
                run.events.append(event)
                if case .done = event {
                    doneAt = .now
                    connection.closeInput()
                }
            }
        }
        run.termination = await connection.termination()
        if let doneAt {
            run.secondsFromDoneToExit = MeetingWorkerProcess.seconds(ContinuousClock.now - doneAt)
        }
        return run
    }

    static func line(_ request: MeetingWorkerRequest) throws -> Data {
        try request.encodedLine()
    }

    // MARK: Requests (helper only)

    @Test("The helper refuses a relative model path with exit 65", .enabled(if: hasHelper))
    func relativePath() async throws {
        let request = MeetingWorkerRequest(engine: .nemotronEnglish, modelFolder: "models/nemotron")
        let run = try await Self.run(mode: .liveText, request: Self.line(request))
        #expect(run.termination == .exited(65))
        #expect(
            run.events == [
                .error(domain: .request, code: MeetingWorkerRequestError.relativePath.wireCode)
            ])
    }

    @Test(
        "The helper refuses a symbolic link in the model path with exit 65", .enabled(if: hasHelper)
    )
    func symbolicLink() async throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-worker-link-\(UUID().uuidString)")
        let real = raw.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        let link = URL(fileURLWithPath: Self.realPath(raw)).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let request = MeetingWorkerRequest(engine: .nemotronEnglish, modelFolder: link.path)
        let run = try await Self.run(mode: .liveText, request: Self.line(request))
        #expect(run.termination == .exited(65))
        #expect(
            run.events
                == [
                    .error(
                        domain: .request,
                        code: MeetingWorkerRequestError.symbolicLinkInPath.wireCode)
                ])
    }

    @Test("The helper refuses wrong arguments with exit 64", .enabled(if: hasHelper))
    func usage() async throws {
        let helper = try #require(Self.helperBinary)
        let connection = try MeetingWorkerProcessLauncher().launch(
            MeetingWorkerLaunchSpec(
                executableURL: helper, arguments: ["--mode", "dictate"], environment: [:]))
        connection.closeInput()
        for await _ in connection.output {}
        #expect(await connection.termination() == .exited(64))
    }

    // MARK: Engines (helper and models)

    static func testAudio() throws -> URL {
        if let path = environment["RAFU_MEETINGS_TEST_AUDIO"] {
            return URL(fileURLWithPath: path)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-worker-noise-\(UUID().uuidString).wav")
        var samples = Data()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<(16_000 * 4) {
            let value = Int16.random(in: -800...800, using: &generator).littleEndian
            withUnsafeBytes(of: value) { samples.append(contentsOf: $0) }
        }
        var header = Data("RIFF".utf8)
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        append32(UInt32(36 + samples.count))
        header.append(Data("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(16_000)
        append32(32_000)
        append16(2)
        append16(16)
        header.append(Data("data".utf8))
        append32(UInt32(samples.count))
        try (header + samples).write(to: url)
        return url
    }

    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @Test(
        "One short file goes through each after-Stop engine, and the helper exits within 5 s",
        .enabled(if: hasModels),
        arguments: [
            (MeetingWorkerMode.finalText, MeetingWorkerEngineID.nemotronEnglish),
            (.finalText, .whisperKit), (.speakers, .nemotron3), (.speakers, .speakerKit),
        ])
    func fileEngine(mode: MeetingWorkerMode, engine: MeetingWorkerEngineID) async throws {
        let root = try #require(Self.modelRoot)
        let audio = try Self.testAudio()
        let request = MeetingWorkerRequest(
            engine: engine,
            modelFolder: Self.realPath(root.appendingPathComponent(engine.model.rawValue)),
            audioFile: Self.realPath(audio))
        let run = try await Self.run(mode: mode, request: Self.line(request))
        #expect(run.termination == .exited(0))
        #expect(run.events.contains(.preparing))
        #expect(run.events.contains { if case .ready = $0 { true } else { false } })
        #expect(run.events.contains { if case .done = $0 { true } else { false } })
        #expect((run.secondsFromDoneToExit ?? 99) <= 5)
        if Self.environment["RAFU_MEETINGS_TEST_AUDIO"] != nil {
            let found = run.events.contains {
                switch $0 {
                case .final(_, let words): !words.isEmpty
                case .segments(let segments): !segments.isEmpty
                default: false
                }
            }
            #expect(found)
        }
    }

    @Test(
        "Live text runs two tracks and exits within 5 s of the end of input",
        .enabled(if: hasModels))
    func liveText() async throws {
        let root = try #require(Self.modelRoot)
        let request = MeetingWorkerRequest(
            engine: .nemotronEnglish,
            modelFolder: Self.realPath(root.appendingPathComponent("nemotron-en-1120ms")))
        let frames = (0..<6).flatMap { second in
            MeetingTrack.allCases.map {
                MeetingWorkerFrame(
                    track: $0, startTime: Double(second), samples: Data(count: 32_000))
            }
        }
        let run = try await Self.run(mode: .liveText, request: Self.line(request), frames: frames)
        #expect(run.termination == .exited(0))
        #expect(run.events.contains { if case .stats = $0 { true } else { false } })
        #expect((run.secondsFromDoneToExit ?? 99) <= 5)
    }
}
