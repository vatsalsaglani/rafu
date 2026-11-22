import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

/// A process handle that ignores SIGTERM and ends only on SIGKILL.
private final class StubbornHandle: MeetingAgentProcessHandle {
    private struct State {
        var running = true
        var forceKills = 0
        var waiters: [CheckedContinuation<MeetingAgentTermination, Never>] = []
    }

    let output = AsyncStream<Data> { $0.finish() }
    private let state = Mutex(State())

    var forceKills: Int { state.withLock { $0.forceKills } }

    func terminate() {}

    func forceKill() {
        let waiters = state.withLock { state in
            state.forceKills += 1
            state.running = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: .signalled(9)) }
    }

    func termination() async -> MeetingAgentTermination {
        await withCheckedContinuation { continuation in
            let ended = state.withLock { state -> Bool in
                if !state.running { return true }
                state.waiters.append(continuation)
                return false
            }
            if ended { continuation.resume(returning: .signalled(9)) }
        }
    }
}

@Suite("Meetings integration: seams")
struct MeetingsIntegrationSeamTests {
    // MARK: Meetings menu

    @Test("Start Recording: active before the feature exists and when Record can start")
    func menuStart() {
        let before = MeetingsMenuState(
            isAvailable: true, featureExists: false, canStartRecording: false,
            recorderState: .idle)
        #expect(before.recordTitle == "Start Recording")
        #expect(before.isRecordEnabled)
        #expect(!before.isPauseEnabled)
        #expect(before.pauseTitle == "Pause Recording")

        let oldMac = MeetingsMenuState(
            isAvailable: false, featureExists: false, canStartRecording: false,
            recorderState: .idle)
        #expect(!oldMac.isRecordEnabled)
        #expect(!oldMac.isPauseEnabled)

        let busy = MeetingsMenuState(
            isAvailable: true, featureExists: true, canStartRecording: false,
            recorderState: .stopping(MeetingID()))
        #expect(busy.recordTitle == "Start Recording")
        #expect(!busy.isRecordEnabled)
        #expect(!busy.isPauseEnabled)
    }

    @Test("Stop, Pause and Resume follow the recording")
    func menuStopPauseResume() {
        let meeting = MeetingID()
        let recording = MeetingsMenuState(
            isAvailable: true, featureExists: true, canStartRecording: false,
            recorderState: .recording(meeting))
        #expect(recording.recordTitle == "Stop Recording")
        #expect(recording.isRecordEnabled)
        #expect(recording.pauseTitle == "Pause Recording")
        #expect(recording.isPauseEnabled)

        let paused = MeetingsMenuState(
            isAvailable: true, featureExists: true, canStartRecording: false,
            recorderState: .paused(meeting))
        #expect(paused.recordTitle == "Stop Recording")
        #expect(paused.pauseTitle == "Resume Recording")
        #expect(paused.isPauseEnabled)
    }

    @MainActor
    @Test("The menu state reads the session model")
    func menuFromSession() {
        let session = MeetingsSessionModel()
        #expect(!MeetingsMenuState(isAvailable: true, session: session).isRecordEnabled)
        session.isDriverInstalled = true
        #expect(MeetingsMenuState(isAvailable: true, session: session).isRecordEnabled)
        #expect(MeetingsMenuState(isAvailable: true, session: nil).featureExists == false)
    }

    @Test("The Meetings menu has the recording items and makes the feature only on Start")
    func menuSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/RafuApp/App/RafuAppCommands.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "private var meetingsRecordingItems"))
        let end = try #require(source.range(of: "private var meetingsExportDiagnosticsButton"))
        let items = String(source[start.upperBound..<end.lowerBound])
        #expect(items.components(separatedBy: ".resolve()").count == 2)
        #expect(items.contains("feature?.session.stop()"))
        #expect(!items.contains(".keyboardShortcut"))
    }

    // MARK: Diagnostics at quit

    @MainActor
    @Test("The quit flush writes the queued events to disk")
    func quitFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MeetingsQuitFlush-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MeetingsDiagnosticsRuntime(directory: directory)
        let meeting = MeetingID()
        runtime.recorder.record(.recordingPaused, meeting: meeting)
        #expect(MeetingsDiagnosticsRuntime.flushBeforeQuit(runtime.recorder, timeout: .seconds(5)))
        let file = directory.appending(path: "\(meeting.uuidString).jsonl")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Hidden agent quit path and folders

    @Test("Quit: SIGKILL after the grace time, then the clean-ups run, in one call")
    func agentQuitPath() {
        let registry = MeetingAgentProcessRegistry()
        let handle = StubbornHandle()
        registry.add(handle)
        let cleaned = Mutex(0)
        registry.addQuitCleanup { cleaned.withLock { $0 += 1 } }
        let endedInTime = registry.terminateAllForQuit(grace: .milliseconds(50))
        #expect(!endedInTime)
        #expect(handle.forceKills == 1)
        #expect(cleaned.withLock { $0 } == 1)
    }

    @Test("Quit with no process runs the clean-ups at once")
    func agentQuitNoProcess() {
        let registry = MeetingAgentProcessRegistry()
        let cleaned = Mutex(0)
        registry.addQuitCleanup { cleaned.withLock { $0 += 1 } }
        #expect(registry.terminateAllForQuit())
        #expect(cleaned.withLock { $0 } == 1)
    }

    @Test("Run and snapshot folders carry the app variant; remove-all keeps the root")
    func variantFolders() throws {
        #expect(
            MeetingAgentRunFolders.variantFolderName("MeetingAgentRuns", identity: .lightning)
                == "MeetingAgentRuns-RafuLightning")
        #expect(
            MeetingAgentRunFolders.variantFolderName("MeetingAgentSnapshots", identity: .release)
                == "MeetingAgentSnapshots-Rafu")
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-variant-runs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try MeetingAgentRunFolders.make(in: base)
        MeetingAgentRunFolders.removeAll(in: base)
        #expect(!FileManager.default.fileExists(atPath: run.root.path))
        #expect(FileManager.default.fileExists(atPath: base.path))
    }

    // MARK: Detail view runs

    @MainActor
    @Test("Leaving the detail view cancels a running question")
    func detailCancelsOnDisappear() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(store: fixture.store, behaviour: .waitForCancel)
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.requestAsk("When?")
        model.confirmConsent()
        let task = try #require(model.runTask)
        model.cancelRunsOnDisappear()
        await task.value
        #expect(task.isCancelled)
        #expect(model.askState == .idle)
        #expect(model.pendingConsent == nil)
    }

    // MARK: Source policy

    @Test("Model sizes come from the catalog: no literal size in the sources")
    func noLiteralModelSize() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
        var hits: [String] = []
        // The catalog is the one place that may name a size (its comments).
        for case let path as String in enumerator
        where path.hasSuffix(".swift") && !path.hasSuffix("MeetingModelCatalog.swift") {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            for literal in ["613 MB", "626.2 MB", "629.5 MB", "199.1 MB", "11.2 MB"]
            where text.contains(literal) {
                hits.append("\(path): \(literal)")
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }
}
