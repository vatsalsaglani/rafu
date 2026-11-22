import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

@Suite("Meetings speech worker client")
struct MeetingWorkerClientTests {
    static let helper = URL(
        fileURLWithPath: "/Applications/Rafu Lightning.app/Contents/Helpers/RafuMeetingsWorker")

    static func fileRequest(_ engine: MeetingWorkerEngineID = .nemotronEnglish)
        -> MeetingWorkerRequest
    {
        MeetingWorkerRequest(
            engine: engine, modelFolder: "/Models/\(engine.model.rawValue)/rev-1",
            audioFile: "/Library/Meetings/m1/them.caf")
    }

    static let words1 = [
        MeetingWord(text: "we", start: 0, end: 0.2),
        MeetingWord(text: "ship", start: 0.2, end: 0.5),
    ]
    static let words2 = [MeetingWord(text: "it", start: 0.5, end: 0.9)]

    static let goodTextScript: [FakeWorkerStep] = [
        .lines([.preparing, .ready(loadMilliseconds: 7_400, cold: true), .progress(fraction: 0.5)]),
        .lines([.final(track: .them, words: words1), .final(track: .them, words: words2)]),
        .lines([
            .progress(fraction: 1),
            .stats(
                peakFootprintBytes: 491_000_000, chunkP50Milliseconds: nil,
                chunkP95Milliseconds: nil),
            .done(audioSeconds: 14.9),
        ]),
        .waitForInputClose,
        .exit(0),
    ]

    final class ProgressLog: Sendable {
        private let items = Mutex<[MeetingEngineProgress]>([])
        func add(_ item: MeetingEngineProgress) { items.withLock { $0.append(item) } }
        var all: [MeetingEngineProgress] { items.withLock { $0 } }
    }

    // MARK: File jobs

    @Test("Scripted lines become ordered words, progress and a result")
    func scriptedLines() async throws {
        let launcher = FakeWorkerLauncher(scripts: [Self.goodTextScript])
        let diagnostics = RecordingDiagnostics()
        let process = MeetingWorkerProcess(
            helperURL: Self.helper, launcher: launcher, diagnostics: diagnostics)
        let log = ProgressLog()
        let result = try await process.runFileJob(
            mode: .finalText, request: Self.fileRequest(), meeting: nil, progress: { log.add($0) })
        #expect(result.words == Self.words1 + Self.words2)
        #expect(result.loadMilliseconds == 7_400)
        #expect(result.coldLoad == true)
        #expect(result.peakFootprintBytes == 491_000_000)
        #expect(result.audioSeconds == 14.9)
        #expect(log.all == [.preparingModel, .working(fraction: 0.5), .working(fraction: 1)])
        #expect(launcher.connections[0].isInputClosed)
        #expect(process.registry.count == 0)
        #expect(
            diagnostics.recorded.contains(
                .helperStarted(mode: .finalText, engine: .text(.nemotronEnglish))))
        #expect(
            diagnostics.recorded.contains {
                if case .helperExited(.finalText, 0, nil, _, 491_000_000) = $0 { return true }
                return false
            })
    }

    @Test("The helper gets only mode and protocol as arguments, and three environment keys")
    func argumentsAndEnvironment() async throws {
        let launcher = FakeWorkerLauncher(scripts: [Self.goodTextScript])
        let environment = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "TMPDIR": "/var/folders/x/T/",
            "ANTHROPIC_API_KEY": "secret", "SSH_AUTH_SOCK": "/tmp/agent", "USER": "someone",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
        ]
        let process = MeetingWorkerProcess(
            helperURL: Self.helper, launcher: launcher, environment: environment)
        let request = Self.fileRequest()
        _ = try await process.runFileJob(mode: .finalText, request: request, meeting: nil) { _ in }
        let spec = try #require(launcher.specs.first)
        #expect(spec.executableURL == Self.helper)
        #expect(spec.arguments == ["--mode", "final-text", "--protocol", "1"])
        #expect(Set(spec.environment.keys) == ["PATH", "HOME", "TMPDIR"])
        #expect(spec.environment["HOME"] == "/Users/someone")
        let joined = spec.arguments.joined(separator: " ")
        #expect(!joined.contains(request.modelFolder))
        #expect(!joined.contains(request.audioFile ?? "-"))
        // The paths travel on standard input, in the request line.
        #expect(launcher.connections[0].request == request)
    }

    @Test("Cancel ends the helper and leaves no running job")
    func cancelEndsHelper() async throws {
        let launcher = FakeWorkerLauncher(scripts: [[.lines([.preparing]), .hang]])
        let process = MeetingWorkerProcess(helperURL: Self.helper, launcher: launcher)
        let job = Task {
            try await process.runFileJob(
                mode: .speakers, request: Self.fileRequest(.nemotron3), meeting: nil
            ) { _ in }
        }
        let connection = await launcher.connection(0)
        await connection.waitForRequest()
        job.cancel()
        await #expect(throws: MeetingWorkerError.cancelled) { try await job.value }
        #expect(connection.wasTerminated)
        #expect(process.registry.count == 0)
        #expect(await process.isRunningFileJob == false)
    }

    @Test(
        "A helper exit maps to a typed error",
        arguments: [
            ([FakeWorkerStep.exit(66)], MeetingWorkerError.modelMissing(.nemotronEnglish1120)),
            ([.exit(65)], .badRequest),
            ([.exit(64)], .badRequest),
            (
                [.lines([.error(domain: .engine, code: 2)]), .exit(70)],
                .engineFailed(domain: .engine, code: 2)
            ),
            ([.exit(75)], .cancelled),
            ([.signal(11)], .crashed(signal: 11)),
            ([.lines([.ready(loadMilliseconds: 1, cold: false)]), .exit(0)], .protocolViolation),
            ([.raw(Data("{\"type\":\"transcript\"}\n".utf8)), .hang], .protocolViolation),
            ([.raw(Data(repeating: 0x41, count: 70_000)), .hang], .protocolViolation),
        ])
    func exitMapsToError(_ script: [FakeWorkerStep], expected: MeetingWorkerError) async {
        let launcher = FakeWorkerLauncher(scripts: [script])
        let process = MeetingWorkerProcess(helperURL: Self.helper, launcher: launcher)
        await #expect(throws: expected) {
            try await process.runFileJob(
                mode: .finalText, request: Self.fileRequest(), meeting: nil
            ) { _ in }
        }
        #expect(process.registry.count == 0)
    }

    @Test("A missing helper is a typed error and starts nothing")
    func missingHelper() async {
        let launcher = FakeWorkerLauncher()
        let process = MeetingWorkerProcess(helperURL: nil, launcher: launcher)
        await #expect(throws: MeetingWorkerError.helperMissing) {
            try await process.runFileJob(
                mode: .finalText, request: Self.fileRequest(), meeting: nil
            ) { _ in }
        }
        #expect(launcher.specs.isEmpty)
        launcher.failNextLaunches(1)
        let refusing = MeetingWorkerProcess(helperURL: Self.helper, launcher: launcher)
        await #expect(throws: MeetingWorkerError.launchFailed) {
            try await refusing.runFileJob(
                mode: .finalText, request: Self.fileRequest(), meeting: nil
            ) { _ in }
        }
    }

    @Test("After-Stop jobs run one at a time")
    func oneJobAtATime() async throws {
        let launcher = FakeWorkerLauncher(defaultScript: Self.goodTextScript)
        let process = MeetingWorkerProcess(helperURL: Self.helper, launcher: launcher)
        try await withThrowingTaskGroup(of: MeetingWorkerFileResult.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await process.runFileJob(
                        mode: index.isMultiple(of: 2) ? .finalText : .speakers,
                        request: Self.fileRequest(
                            index.isMultiple(of: 2) ? .whisperKit : .speakerKit),
                        meeting: nil
                    ) { _ in }
                }
            }
            for try await result in group {
                #expect(result.words == Self.words1 + Self.words2)
            }
        }
        #expect(launcher.specs.count == 4)
        #expect(launcher.maximumRunning == 1)
    }

    @Test("Critical memory pressure stops the job, and the error says the audio is kept")
    func memoryPressure() async throws {
        let launcher = FakeWorkerLauncher(scripts: [[.lines([.preparing]), .hang]])
        let process = MeetingWorkerProcess(helperURL: Self.helper, launcher: launcher)
        let job = Task {
            try await process.runFileJob(
                mode: .speakers, request: Self.fileRequest(.speakerKit), meeting: nil
            ) { _ in }
        }
        let connection = await launcher.connection(0)
        await connection.waitForRequest()
        await process.stopFileJobForMemoryPressure()
        do {
            _ = try await job.value
            Issue.record("The job should stop")
        } catch let error as MeetingWorkerError {
            #expect(error == .memoryPressure)
            #expect(error.keepsAudio)
            #expect(error.userMessage.contains("audio is kept"))
        }
        #expect(connection.wasTerminated)
        #expect(process.registry.count == 0)
    }

    @Test("The registry ends each running helper at quit")
    func quitEndsHelpers() async throws {
        let launcher = FakeWorkerLauncher(scripts: [nil])
        let process = MeetingWorkerProcess(helperURL: Self.helper, launcher: launcher)
        let connection = try await process.launch(
            mode: .liveText,
            request: MeetingWorkerRequest(engine: .nemotronEnglish, modelFolder: "/m"))
        #expect(process.registry.count == 1)
        process.registry.terminateAll()
        #expect((connection as? FakeWorkerConnection)?.wasTerminated == true)
    }
}
