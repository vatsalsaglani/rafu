import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Agent History tabs and navigator", .serialized)
@MainActor
struct AgentHistoryTabTests {
    private func withWorkspace(
        _ body: (WorkspaceSession) async throws -> Void
    ) async throws {
        let suite = TestDefaultsSuite.name("dev.rafu.agent-history")
        let store = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        let session = WorkspaceSession(restorationStore: store)
        session.descriptor = WorkspaceDescriptor(
            displayName: "Agent history",
            location: .local(
                LocalWorkspaceReference(path: "/tmp/rafu-workspace-\(UUID().uuidString)")))
        defer { TestDefaultsSuite.remove(suite) }
        do {
            try await body(session)
        } catch {
            await session.flushWorkspaceState()?.value
            throw error
        }
        await session.flushWorkspaceState()?.value
    }

    /// A summary whose file does not exist: opening it fails visibly, which
    /// is enough for tab bookkeeping and never reads a real transcript.
    private func summary(_ id: String, title: String = "Fix the parser")
        -> AgentHistorySessionSummary
    {
        AgentHistorySessionSummary(
            key: AgentHistorySessionKey(provider: .claudeCode, sessionID: id), title: title,
            projectPath: "/tmp/agent-history-project", startedAt: nil, updatedAt: nil,
            gitBranch: "main", messageCount: 2, isMessageCountEstimated: false,
            fileURL: URL(fileURLWithPath: "/tmp/rafu-missing-\(UUID().uuidString).jsonl"),
            fileSize: 10, modificationDate: Date(timeIntervalSince1970: 0))
    }

    @Test("History is a navigator mode that survives restoration encoding")
    func historyModeRoundTrips() throws {
        let data = try JSONEncoder().encode(WorkspaceNavigatorMode.history)
        #expect(try JSONDecoder().decode(WorkspaceNavigatorMode.self, from: data) == .history)
        #expect(WorkspaceNavigatorMode.history.title == "History")
        #expect(WorkspaceNavigatorMode.history.symbolName == "clock.arrow.circlepath")
    }

    @Test("A tab reference is identified by its session key, not its title")
    func tabReferenceIdentity() {
        let key = AgentHistorySessionKey(provider: .codex, sessionID: "a")
        let first = AgentSessionTabReference(key: key, title: "One")
        let renamed = AgentSessionTabReference(key: key, title: "Two")
        #expect(first == renamed)
        #expect(Set([first, renamed]).count == 1)
        #expect(WorkspaceAuxiliaryTab.agentSession(first).title == "One")
        #expect(AgentHistoryProvider.claudeCode.cli == .claudeCode)
        #expect(AgentHistoryProvider.codex.cli == .codex)
    }

    @Test("Opening a session adds one tab, selects it, and closing releases it")
    func openAndCloseAgentSessionTab() async throws {
        try await withWorkspace { session in
            let first = summary("first")
            session.openAgentSession(first)
            session.openAgentSession(first)
            let reference = AgentSessionTabReference(key: first.key, title: first.title)
            #expect(session.auxiliaryTabs == [.agentSession(reference)])
            #expect(session.selectedAuxiliaryTab == .agentSession(reference))
            #expect(session.agentHistory.transcripts[first.key] != nil)

            let second = summary("second", title: "Second")
            session.openAgentSession(second)
            #expect(session.auxiliaryTabs.count == 2)
            #expect(session.agentHistory.visibleSession?.key == second.key)

            session.selectAuxiliaryTab(.agentSession(reference))
            #expect(session.agentHistory.visibleSession?.key == first.key)

            session.closeAuxiliaryTab(.agentSession(reference))
            #expect(session.agentHistory.transcripts[first.key] == nil)
            #expect(session.agentHistory.transcripts[second.key] != nil)
            #expect(session.selectedAuxiliaryTab != .agentSession(reference))
        }
    }

    @Test("Settings and an Agent Session tab never both show")
    func settingsAndAgentSessionAreExclusive() async throws {
        try await withWorkspace { session in
            let first = summary("first")
            session.openAgentSession(first)
            session.showSettings()
            #expect(session.selectedAuxiliaryTab == .settings)
            #expect(session.agentHistory.visibleSession == nil)
            session.openAgentSession(first)
            #expect(session.settingsVisible == false)
            #expect(
                session.selectedAuxiliaryTab
                    == .agentSession(AgentSessionTabReference(key: first.key, title: "")))
        }
    }

    @Test("A missing transcript file fails without a path in the message")
    func missingTranscriptFails() async throws {
        let model = AgentTranscriptModel(summary: summary("missing"))
        model.load()
        await model.loadTask?.value
        guard case .failed(let message) = model.phase else {
            Issue.record("Expected a failure, got \(model.phase)")
            return
        }
        #expect(!message.contains("/tmp"))
    }

    @Test("Show Agent History selects the History mode and can request search focus")
    func showAgentHistory() async throws {
        try await withWorkspace { session in
            session.showAgentHistory()
            #expect(session.navigatorMode == .history)
            let before = session.agentHistory.searchFocusRequest
            session.showAgentHistory(focusSearch: true)
            #expect(session.agentHistory.searchFocusRequest == before + 1)
            #expect(session.agentHistoryWorkspaceRoots.first?.hasPrefix("/tmp/") == true)
        }
    }
}
