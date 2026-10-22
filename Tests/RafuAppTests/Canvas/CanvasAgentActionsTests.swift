import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Removes the fixture's temporary workspace when the fixture goes away.
private final class CanvasAgentScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-agent-actions-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@MainActor
private struct CanvasAgentFixture {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let cards: [CanvasCard]
    let bridge: CanvasLiveBridge
    let token = "agent-tools-private-capability"
    let client = UUID().uuidString
    private let scratch = CanvasAgentScratchFolder()

    /// The board is open in the session's store, as in the app. `presented`
    /// also gives it a visible owner, like a selected Ensemble tab.
    init(presented: Bool = true) async throws {
        let scratch = scratch
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-agent-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await session.canvas.configure(root: scratch.url))
        let board = try #require(await session.canvas.create(title: "Agent test"))
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let group = try session.terminal.createLiveGroup(
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        let id = try #require(group.panes.first?.sessionID)
        let controller = try #require(session.terminal.sessions.first { $0.id == id })
        try board.add(title: "Lead", content: .terminal(groupID: group.id))
        try board.add(title: "Plan", content: .note(snapshot: "# Plan\n## Tasks\n"))
        let cards = board.cards
        let bridge = CanvasLiveBridge(location: { controllerID in
            guard controllerID == id, let card = board.cards.first else { return nil }
            return (session, board, card)
        })
        bridge.install(controller: controller, token: token)
        if presented {
            session.installCanvasResources(for: board)
            session.canvasResources[board.id]?.present(owner: UUID())
        }
        self.session = session
        self.board = board
        self.cards = cards
        self.bridge = bridge
        #expect(
            await bridge.handle(
                CanvasBridgeRequest(
                    token: token, operation: "register", clientID: client, provider: "claude")
            ).error == nil)
    }

    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws
        -> CanvasBridgeResponse
    {
        let call = try CanvasAgentToolCall.parse(tool: tool, arguments: arguments)
        return await bridge.handle(
            CanvasBridgeRequest(
                token: token, operation: "tool", clientID: client, provider: "claude",
                agentCall: call))
    }

    /// Bounded: yields until an approval for this board appears.
    func pendingApproval() async -> CanvasAgentApproval? {
        for _ in 0..<1_000 {
            if let approval = CanvasAgentCenter.shared.approvals(for: board.id).first {
                return approval
            }
            await Task.yield()
        }
        return nil
    }
}

@Suite("Ensemble agent actions")
@MainActor
struct CanvasAgentActionsTests {
    @Test("A board without Agent control decodes as Ask and round-trips a saved choice")
    func agentControlIsBackwardCompatible() throws {
        let legacy = try JSONEncoder().encode(CanvasDocument(title: "Old"))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("agentControl"))
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: legacy)
        #expect(decoded.agentControl == nil)
        #expect(CanvasBoardState(document: decoded).agentControlMode == .ask)
        var document = CanvasDocument(title: "New")
        document.agentControl = CanvasAgentControl(mode: .off)
        let reloaded = try JSONDecoder().decode(
            CanvasDocument.self, from: JSONEncoder().encode(document))
        #expect(reloaded.agentControl?.mode == .off)
    }

    @Test("Undo never changes Agent control")
    func undoKeepsAgentControl() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Undo"))
        try board.add(title: "Note", content: .note(snapshot: ""))
        board.setAgentControlMode(.allow)
        board.performUndo()
        #expect(board.cards.isEmpty)
        #expect(board.agentControlMode == .allow)
        board.performRedo()
        #expect(board.agentControlMode == .allow)
    }

    @Test("ensemble_describe reads without asking and names the caller")
    func describe() async throws {
        let fixture = try await CanvasAgentFixture(presented: false)
        fixture.board.setAgentControlMode(.off)
        let response = try await fixture.call("ensemble_describe")
        let result = try #require(response.toolResult)
        #expect(response.error == nil)
        #expect(result.callerNodeID == fixture.cards[0].id.rawValue.uuidString)
        #expect(result.agentControl == "off")
        #expect(result.nodes?.map(\.kind) == ["terminal", "note"])
        let note = try await fixture.call(
            "note_read", ["node_id": fixture.cards[1].id.rawValue.uuidString])
        #expect(note.toolResult?.text == "# Plan\n## Tasks\n")
    }

    @Test("Off blocks every change")
    func offBlocksChanges() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.off)
        let response = try await fixture.call("note_create", ["title": "Blocked"])
        #expect(response.error == CanvasAgentPolicy.offMessage)
        #expect(fixture.board.cards.count == 2)
    }

    @Test("An open Ensemble accepts changes while its tab is not on screen")
    func mutationWorksWhenBoardIsOpenButNotPresented() async throws {
        let fixture = try await CanvasAgentFixture(presented: false)
        #expect(fixture.session.canvasResources[fixture.board.id]?.isPresented != true)
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call("note_create", ["title": "Background"])
        #expect(created.error == nil)
        #expect(fixture.board.cards.count == 3)
        let noteID = fixture.cards[1].id.rawValue.uuidString
        let written = try await fixture.call(
            "note_write", ["node_id": noteID, "mode": "append", "text": "- from the background"])
        #expect(written.error == nil)
        let edge = try await fixture.call(
            "edge_create",
            [
                "from": noteID, "to": try #require(created.toolResult?.nodeID),
                "kind": "relationship",
            ])
        #expect(edge.error == nil)
        let stopped = try await fixture.call("terminal_create", ["title": "Parked shell"])
        #expect(stopped.error == nil)
        #expect(fixture.board.cards.count == 4)
    }

    @Test("Ask still gates a background change and pends without a visible Ensemble")
    func askPendsWhileBoardIsNotPresented() async throws {
        let fixture = try await CanvasAgentFixture(presented: false)
        let task = Task { try await fixture.call("note_create", ["title": "Asked"]) }
        let approval = try #require(await fixture.pendingApproval())
        CanvasAgentCenter.shared.decide(approval.id, .once)
        let response = try await task.value
        #expect(response.error == nil)
        #expect(fixture.board.cards.count == 3)
    }

    @Test("A closed Ensemble refuses changes even in Allow")
    func mutationRefusedWhenBoardIsClosed() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.session.canvas.forgetClosed(fixture.board.id)
        let response = try await fixture.call("note_create", ["title": "Closed"])
        #expect(response.error == CanvasAgentActions.hiddenMessage)
        #expect(response.error?.contains("closed") == true)
        #expect(fixture.board.cards.count == 2)
    }

    @Test("Opening apps and starting terminals still need the Ensemble on screen")
    func processAndAppToolsNeedTheBoardShown() async throws {
        let fixture = try await CanvasAgentFixture(presented: false)
        fixture.board.setAgentControlMode(.allow)
        let app = try await fixture.call("app_open", ["bundle_id": "com.apple.finder"])
        #expect(app.error == CanvasAgentActions.notShownMessage)
        let started = try await fixture.call(
            "terminal_create", ["title": "Agent", "agent": "claude"])
        #expect(started.error == CanvasAgentActions.notShownMessage)
        #expect(fixture.board.cards.count == 2)
    }

    @Test("Allow runs changes at once; each is undoable and logged")
    func allowRunsUndoableChanges() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call(
            "note_create",
            [
                "title": "Findings", "markdown": "- one",
                "near": fixture.cards[1].id.rawValue.uuidString,
            ])
        let id = try #require(created.toolResult?.nodeID)
        #expect(fixture.board.cards.count == 3)
        let card = try #require(fixture.board.cards.last)
        #expect(card.id.rawValue.uuidString == id)
        #expect(card.rect.x > fixture.cards[1].rect.x)
        let link = try await fixture.call(
            "edge_create",
            ["from": fixture.cards[1].id.rawValue.uuidString, "to": id, "kind": "relationship"])
        #expect(link.error == nil)
        #expect(fixture.board.connections.count == 1)
        fixture.board.performUndo()
        #expect(fixture.board.connections.isEmpty)
        fixture.board.performUndo()
        #expect(fixture.board.cards.count == 2)
        #expect(
            CanvasAgentCenter.shared.log(for: fixture.board.id).contains {
                $0.action == CanvasAgentTool.noteCreate.actionTitle
            })
    }

    @Test("Ask waits for the user; Allow Once runs the action")
    func askThenAllowOnce() async throws {
        let fixture = try await CanvasAgentFixture()
        let task = Task { try await fixture.call("note_create", ["title": "Asked"]) }
        let approval = try #require(await fixture.pendingApproval())
        #expect(approval.call.tool == .noteCreate)
        #expect(approval.allowsAlways)
        #expect(fixture.board.cards.count == 2)
        CanvasAgentCenter.shared.decide(approval.id, .once)
        let response = try await task.value
        #expect(response.error == nil)
        #expect(fixture.board.cards.count == 3)
    }

    @Test("Ask then Deny changes nothing")
    func askThenDeny() async throws {
        let fixture = try await CanvasAgentFixture()
        let task = Task { try await fixture.call("note_create", ["title": "Denied"]) }
        let approval = try #require(await fixture.pendingApproval())
        CanvasAgentCenter.shared.decide(approval.id, .deny)
        let response = try await task.value
        #expect(response.error == CanvasAgentActions.deniedMessage)
        #expect(fixture.board.cards.count == 2)
    }

    @Test("Always covers later edits on this Ensemble but never a removal")
    func alwaysCoversEditsOnly() async throws {
        let fixture = try await CanvasAgentFixture()
        let first = Task { try await fixture.call("note_create", ["title": "One"]) }
        let approval = try #require(await fixture.pendingApproval())
        CanvasAgentCenter.shared.decide(approval.id, .always)
        _ = try await first.value
        let second = try await fixture.call("note_create", ["title": "Two"])
        #expect(second.error == nil)
        #expect(fixture.board.cards.count == 4)
        let removal = Task {
            try await fixture.call(
                "node_remove", ["node_id": fixture.cards[1].id.rawValue.uuidString])
        }
        let question = try #require(await fixture.pendingApproval())
        #expect(question.call.tool == .nodeRemove)
        #expect(!question.allowsAlways)
        CanvasAgentCenter.shared.decide(question.id, .deny)
        _ = try await removal.value
        #expect(fixture.board.cards.count == 4)
        CanvasAgentCenter.shared.forgetGrants(on: fixture.board.id)
    }

    @Test("An agent cannot remove its own node or type into a terminal it did not create")
    func confinement() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let own = try await fixture.call(
            "node_remove", ["node_id": fixture.cards[0].id.rawValue.uuidString])
        #expect(own.error != nil)
        #expect(fixture.board.cards.count == 2)
        let typed = try await fixture.call(
            "terminal_send",
            ["node_id": fixture.cards[0].id.rawValue.uuidString, "command": ["ls"]])
        #expect(typed.error != nil)
    }

    @Test("note_write appends through the note and respects the note limit")
    func noteWrite() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let id = fixture.cards[1].id.rawValue.uuidString
        let response = try await fixture.call(
            "note_write",
            ["node_id": id, "mode": "insert_after_heading", "heading": "Tasks", "text": "- [ ] a"])
        #expect(response.error == nil)
        let read = try await fixture.call("note_read", ["node_id": id])
        #expect(read.toolResult?.text == "# Plan\n## Tasks\n- [ ] a\n")
        let big = String(repeating: "x", count: 16 * 1_024)
        var last = CanvasBridgeResponse()
        for _ in 0..<5 {
            last = try await fixture.call(
                "note_write", ["node_id": id, "mode": "append", "text": big])
        }
        #expect(last.error != nil)
    }
}
