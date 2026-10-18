import Foundation
import RafuCore
import Testing

@testable import RafuApp

private func hookEvent(
    _ name: String, session: String = "s", at seconds: TimeInterval, tool: String? = nil
) -> AgentHookEvent {
    AgentHookEvent(
        provider: .claude, sessionID: session, hookEventName: name, cwd: "/repo/app",
        toolName: tool, time: Date(timeIntervalSince1970: seconds))
}

private func session(
    _ events: [AgentHookEvent]
) throws -> TrackedAgentSession {
    var ledger = AgentSessionLedger()
    for event in events { ledger.apply(event) }
    return try #require(ledger.sessions.first)
}

@MainActor
@Suite("Agent activity store")
struct AgentActivityStoreTests {
    private func makeStore() -> (AgentActivityStore, String) {
        let suite = "dev.rafu.tests.agent-activity.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rafu-activity-\(UUID().uuidString)/AgentTracking")
        let store = AgentActivityStore(
            paths: AgentTrackingPaths(root: root),
            defaults: UserDefaults(suiteName: suite) ?? .standard)
        return (store, suite)
    }

    @Test("Applied events become sessions; a later drain expires ended ones")
    func applyAndExpire() {
        let (store, suite) = makeStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.apply(
            [hookEvent("UserPromptSubmit", at: 1), hookEvent("PermissionRequest", at: 2)],
            at: Date(timeIntervalSince1970: 3))
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.state == .waitingForPermission)
        store.apply([hookEvent("SessionEnd", at: 4)], at: Date(timeIntervalSince1970: 5))
        #expect(store.sessions.first?.state == .ended)
        store.apply([], at: Date(timeIntervalSince1970: 500))
        #expect(store.sessions.isEmpty)
        store.stop()
    }

    @Test("Connected providers persist in the injected defaults")
    func connectedProviders() {
        let (store, suite) = makeStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        store.setConnected(.codex, true)
        store.setConnected(.claude, true)
        store.setConnected(.claude, false)
        #expect(store.connectedProviders == [.codex])
        let reloaded = AgentActivityStore(
            paths: store.paths, defaults: UserDefaults(suiteName: suite) ?? .standard)
        #expect(reloaded.connectedProviders == [.codex])
    }

    @Test("Draining the real spool folds files written by the helper format")
    func drainSpool() async throws {
        let (store, suite) = makeStore()
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.paths.root.deletingLastPathComponent())
        }
        try AgentHookSpool.write(
            AgentHookEvent(provider: .codex, sessionID: "c", hookEventName: "UserPromptSubmit"),
            to: store.paths.spool)
        await store.drain()
        #expect(store.sessions.map(\.id) == ["codex:c"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.paths.spool.path).isEmpty)
        store.stop()
    }

    @Test("A native directory notification drains an atomically written hook event")
    func watchSpool() async throws {
        let (store, suite) = makeStore()
        defer {
            store.stop()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.paths.root.deletingLastPathComponent())
        }
        let descriptor = try #require(await AgentActivityIO.openSpool(store.paths.spool))
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let watcher = AgentActivityIO.makeWatcher(descriptor: descriptor) {
            await store.drain()
            if store.sessions.first?.state == .needsInput { continuation.yield(()) }
        }
        watcher.resume()
        defer {
            watcher.cancel()
            continuation.finish()
        }
        try AgentHookSpool.write(
            AgentHookEvent(
                provider: .claude, sessionID: "native-watch", hookEventName: "PreToolUse",
                toolName: "AskUserQuestion"), to: store.paths.spool)
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events { return true }
                return false
            }
            group.addTask {
                // A failure deadline, not a delay used to synchronize the watcher.
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(received)
        #expect(store.sessions.first?.state == .needsInput)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.paths.spool.path).isEmpty)
    }
}

@Suite("Agent tracked phase")
struct AgentTrackedPhaseTests {
    private let now = Date(timeIntervalSince1970: 100)

    @Test("A Rafu terminal: hook work and attention win; the bell owns reply ready")
    func terminalPhase() throws {
        let working = try session([hookEvent("UserPromptSubmit", at: 90)])
        #expect(
            AgentTrackedPhase.terminalPhase(session: working, status: .running, now: now)
                == .working)
        let waiting = try session([hookEvent("PermissionRequest", at: 90)])
        #expect(
            AgentTrackedPhase.terminalPhase(session: waiting, status: .running, now: now)
                == .needsYou)
        let replied = try session([hookEvent("Stop", at: 90)])
        #expect(
            AgentTrackedPhase.terminalPhase(session: replied, status: .bell, now: now)
                == .replyReady)
        #expect(
            AgentTrackedPhase.terminalPhase(session: replied, status: .running, now: now)
                == .idle)
        #expect(
            AgentTrackedPhase.terminalPhase(session: replied, status: .exited(code: 0), now: now)
                == nil)
        #expect(AgentTrackedPhase.terminalPhase(session: nil, status: .running, now: now) == nil)
    }

    @Test("Stale work falls back to the output-based phase")
    func staleWork() throws {
        let working = try session([hookEvent("UserPromptSubmit", at: 0)])
        let later = Date(timeIntervalSince1970: TrackedAgentSession.staleInterval + 1)
        #expect(
            AgentTrackedPhase.terminalPhase(session: working, status: .running, now: later)
                == nil)
        #expect(AgentTrackedPhase.externalPhase(session: working, now: later) == .idle)
    }

    @Test("Outside Rafu: a reply is ready only while fresh")
    func externalReply() throws {
        let replied = try session([hookEvent("Stop", at: 90)])
        #expect(AgentTrackedPhase.externalPhase(session: replied, now: now) == .replyReady)
        let old = Date(timeIntervalSince1970: 90 + TrackedAgentSession.replyFreshInterval + 1)
        #expect(AgentTrackedPhase.externalPhase(session: replied, now: old) == .idle)
    }

    @Test("Node header words")
    func stateWords() throws {
        let waiting = try session([hookEvent("PermissionRequest", at: 90)])
        #expect(AgentTrackedPhase.stateWord(phase: .needsYou, session: waiting) == "Needs approval")
        let asking = try session([hookEvent("PreToolUse", at: 90, tool: "AskUserQuestion")])
        #expect(AgentTrackedPhase.stateWord(phase: .needsYou, session: asking) == "Needs input")
        #expect(AgentTrackedPhase.stateWord(phase: .working, session: asking) == "Working")
        #expect(AgentTrackedPhase.stateWord(phase: nil, session: asking) == nil)
    }

    @Test("Provider and CLI identities map both ways")
    func providerMapping() {
        for provider in AgentHookProvider.allCases {
            #expect(AgentHookProvider(cli: provider.cli) == provider)
        }
        #expect(AgentHookProvider(cli: .geminiCLI) == nil)
    }

    @Test("A notch row prefers the tracked phase over output timing")
    func notchRowPrefersTrackedPhase() {
        let input = NotchTerminalInput(
            id: UUID(), title: "claude", cli: .claudeCode, status: .running,
            isProducingOutput: false, trackedPhase: .needsYou)
        #expect(NotchAgentRow.rows(from: [input]).first?.phase == .needsYou)
        let fallback = NotchTerminalInput(
            id: UUID(), title: "claude", cli: .claudeCode, status: .running,
            isProducingOutput: true)
        #expect(NotchAgentRow.rows(from: [fallback]).first?.phase == .working)
    }
}
