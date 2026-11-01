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

    /// Regression: the app used to create the node first and then fail the long
    /// prompt as a bare `Invalid value for "command"`.
    @Test("A long prompt is refused by name and leaves no node behind")
    func longPromptIsAtomic() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let groupsBefore = fixture.session.terminal.terminalGroups.count
        var call = CanvasAgentToolCall(tool: .terminalCreate)
        call.agent = "claude"
        call.prompt = String(repeating: "word ", count: 500)
        let response = await fixture.bridge.handle(
            CanvasBridgeRequest(
                token: fixture.token, operation: "tool", clientID: fixture.client,
                provider: "claude", agentCall: call))
        let error = try #require(response.error)
        #expect(error.contains("\"prompt\""))
        #expect(error.contains("1,024"))
        #expect(!error.contains("word word"))
        #expect(fixture.board.cards.count == 2)
        #expect(fixture.session.terminal.terminalGroups.count == groupsBefore)
        #expect(
            !CanvasAgentCenter.shared.log(for: fixture.board.id).contains {
                $0.outcome.contains("word word")
            })
    }

    @Test("An over-long terminal_send argument is refused with the limit")
    func longSendArgumentNamesTheLimit() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        var call = CanvasAgentToolCall(tool: .terminalSend)
        call.nodeID = fixture.cards[0].id.rawValue.uuidString
        call.command = ["echo", String(repeating: "x", count: 1_500)]
        let response = await fixture.bridge.handle(
            CanvasBridgeRequest(
                token: fixture.token, operation: "tool", clientID: fixture.client,
                provider: "claude", agentCall: call))
        let error = try #require(response.error)
        #expect(error.contains("argument 2"))
        #expect(error.contains("1,500 bytes"))
        #expect(error.contains("1,024"))
    }

    @Test("terminal_create link adds one message link from the caller to the new node")
    func createLinksThePeer() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let response = try await fixture.call(
            "terminal_create", ["title": "Helper Agent", "link": true])
        #expect(response.error == nil)
        let result = try #require(response.toolResult)
        #expect(fixture.board.cards.count == 3)
        let created = try #require(fixture.board.cards.last)
        #expect(result.nodeID == created.id.rawValue.uuidString)
        #expect(fixture.board.connections.count == 1)
        let edge = try #require(fixture.board.connections.first)
        #expect(edge.isMessageLink)
        #expect(edge.from == fixture.cards[0].id)
        #expect(edge.to == created.id)
        #expect(result.edgeID == edge.id.uuidString)
        #expect(result.mention == "@helper-agent")
        // Without `link` there is no edge and no mention.
        let plain = try await fixture.call("terminal_create", ["title": "Solo"])
        #expect(plain.toolResult?.edgeID == nil)
        #expect(plain.toolResult?.mention == nil)
        #expect(fixture.board.connections.count == 1)
    }

    @Test("A linked terminal_create under Ask pends, then returns the link")
    func createLinkUnderAsk() async throws {
        let fixture = try await CanvasAgentFixture()
        let task = Task { try await fixture.call("terminal_create", ["link": true]) }
        let approval = try #require(await fixture.pendingApproval())
        #expect(approval.summary.contains { $0.hasPrefix("Link:") })
        CanvasAgentCenter.shared.decide(approval.id, .once)
        let response = try await task.value
        #expect(response.error == nil)
        #expect(response.toolResult?.edgeID != nil)
        #expect(fixture.board.connections.count == 1)
        CanvasAgentCenter.shared.forgetGrants(on: fixture.board.id)
    }

    @Test("Text into a shell node without a connected agent points to the message link")
    func textIntoShellPointsToTheFix() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call("terminal_create", ["title": "Plain"])
        let nodeID = try #require(created.toolResult?.nodeID)
        let refused = try await fixture.call("terminal_send", ["node_id": nodeID, "text": "hello"])
        #expect(refused.error == CanvasAgentActions.noAgentTextMessage)
        #expect(refused.error?.contains("edge_create") == true)
        #expect(refused.error?.contains("link_set_state") == true)
        // A launched-agent hint labels the node in ensemble_describe but never
        // opens the text path: only a connected agent does.
        let card = try #require(fixture.board.cards.last)
        CanvasAgentCenter.shared.noteLaunchedAgent(card.id, agent: "claude")
        let described = try await fixture.call("ensemble_describe")
        #expect(described.toolResult?.nodes?.last?.agent == "claude")
        let again = try await fixture.call("terminal_send", ["node_id": nodeID, "text": "hello"])
        #expect(again.error == CanvasAgentActions.noAgentTextMessage)
    }
}

/// A text the tests plant in prompts and commands, to prove it never comes back
/// in a result or the activity log.
private let secretLine = "ZEBRA-SECRET-PROMPT"

/// Runs a body with the start wait cut to a few steps: no card view exists in
/// these tests, so a start is never confirmed and the full wait would only slow
/// them. The value is task-local, so parallel tests never see it.
@MainActor
private func withShortStartWait<T>(steps: Int = 1, _ body: () async throws -> T) async rethrows
    -> T
{
    try await CanvasTerminalStarter.$confirmSteps.withValue(steps) { try await body() }
}

@MainActor
private final class TypedLines {
    var lines: [String] = []
}

@Suite("Ensemble terminal start and queued lines")
@MainActor
struct CanvasTerminalStartTests {
    @Test("terminal_create that cannot start says stopped and queued, and never repeats the prompt")
    func createReportsStoppedAndQueued() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let response = try await withShortStartWait {
            try await fixture.call(
                "terminal_create", ["agent": "claude", "prompt": "fix \(secretLine) now"])
        }
        #expect(response.error == nil)
        let result = try #require(response.toolResult)
        #expect(result.state == "stopped")
        let message = try #require(result.message)
        #expect(message.contains("stopped"))
        #expect(message.contains("queued, not typed"))
        #expect(message.contains("terminal_start"))
        #expect(!message.contains(secretLine))
        let card = try #require(fixture.board.cards.last)
        #expect(fixture.board.pendingTerminalLineCount(for: card.id) == 1)
        #expect(
            !CanvasAgentCenter.shared.log(for: fixture.board.id).contains {
                $0.outcome.contains(secretLine) || $0.outcome.contains("Done")
            })
    }

    @Test("terminal_send into a stopped node says queued, not typing, and keeps the line")
    func sendIntoStoppedNodeIsQueued() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call("terminal_create", ["title": "Plain"])
        #expect(created.toolResult?.state == "stopped")
        let nodeID = try #require(created.toolResult?.nodeID)
        let response = try await withShortStartWait {
            try await fixture.call(
                "terminal_send", ["node_id": nodeID, "command": ["echo", secretLine]])
        }
        #expect(response.error == nil)
        let result = try #require(response.toolResult)
        #expect(result.state == "stopped")
        let message = try #require(result.message)
        #expect(message.contains("queued, not typed"))
        #expect(!message.contains("Typing"))
        #expect(!message.contains(secretLine))
        let card = try #require(fixture.board.cards.last)
        #expect(fixture.board.pendingTerminalLineCount(for: card.id) == 1)
        #expect(
            !CanvasAgentCenter.shared.log(for: fixture.board.id).contains {
                $0.outcome.contains(secretLine)
            })
    }

    @Test("terminal_start on a stopped node with queued lines says they stay queued")
    func startKeepsQueuedLines() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await withShortStartWait {
            try await fixture.call("terminal_create", ["agent": "codex", "prompt": "hello"])
        }
        let nodeID = try #require(created.toolResult?.nodeID)
        let started = try await withShortStartWait {
            try await fixture.call("terminal_start", ["node_id": nodeID])
        }
        let result = try #require(started.toolResult)
        #expect(result.state == "stopped")
        #expect(result.message?.contains("still stopped") == true)
        #expect(result.message?.contains("1 line stays queued") == true)
        // The same start request is not set twice, and the line is not doubled.
        let card = try #require(fixture.board.cards.last)
        #expect(fixture.board.pendingTerminalLineCount(for: card.id) == 1)
        #expect(fixture.board.terminalStartRequest == card.id)
    }

    @Test("A start request for another card is not overwritten")
    func startRequestIsNotOverwritten() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let other = fixture.cards[1].id
        fixture.board.terminalStartRequest = other
        let created = try await withShortStartWait {
            try await fixture.call("terminal_create", ["agent": "claude"])
        }
        #expect(created.error == nil)
        #expect(fixture.board.terminalStartRequest == other)
    }

    @Test("Starting a node far from the view pans it into view and says so")
    func startRevealsTheNode() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.board.visibleSize = CGSize(width: 1_000, height: 700)
        fixture.board.setViewport(CanvasViewport(scale: 1, x: -20_000, y: 0))
        let before = fixture.board.viewport
        let response = try await withShortStartWait {
            try await fixture.call("terminal_create", ["agent": "claude"])
        }
        let card = try #require(fixture.board.cards.last)
        #expect(fixture.board.viewport != before)
        #expect(fixture.board.viewport.scale == before.scale)
        let right = (card.rect.x + card.rect.width) * 1 + fixture.board.viewport.x
        #expect(right <= 1_000)
        #expect(response.toolResult?.message?.contains("moved your view") == true)
    }

    @Test("Starting a node while zoomed out zooms in to live content")
    func startZoomsInFromTheSummaryFace() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.board.visibleSize = CGSize(width: 1_000, height: 700)
        fixture.board.setViewport(CanvasViewport(scale: 0.3, x: 0, y: 0))
        _ = try await withShortStartWait {
            try await fixture.call("terminal_create", ["agent": "claude"])
        }
        #expect(CanvasZoomFace(scale: fixture.board.viewport.scale).showsLiveContent)
    }

    @Test("A node that is already running is not revealed or moved by a plain send")
    func sendToRunningNodeLeavesTheView() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        fixture.board.visibleSize = CGSize(width: 1_000, height: 700)
        fixture.board.setViewport(CanvasViewport(scale: 1, x: -20_000, y: 0))
        let before = fixture.board.viewport
        let report = try await CanvasTerminalStarter.start(
            card: fixture.cards[0],
            groupID: terminalGroupID(of: fixture.cards[0]), line: nil, board: fixture.board,
            session: fixture.session, onGiveUp: {})
        #expect(report.running)
        #expect(!report.viewMoved)
        #expect(fixture.board.viewport == before)
    }

    @Test("Ask mode returns the same truthful state once approved")
    func askModeReturnsTheState() async throws {
        let fixture = try await CanvasAgentFixture()
        let task = Task {
            try await withShortStartWait {
                try await fixture.call(
                    "terminal_create", ["agent": "claude", "prompt": secretLine])
            }
        }
        let approval = try #require(await fixture.pendingApproval())
        #expect(!approval.summary.joined().contains("types"))
        CanvasAgentCenter.shared.decide(approval.id, .once)
        let response = try await task.value
        #expect(response.toolResult?.state == "stopped")
        #expect(response.toolResult?.message?.contains(secretLine) == false)
        CanvasAgentCenter.shared.forgetGrants(on: fixture.board.id)
    }

    @Test("An unrelated alert during the start wait is not reported as a terminal manager refusal")
    func unrelatedAlertIsNotARefusal() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call("terminal_create", ["title": "Plain"])
        #expect(created.toolResult?.state == "stopped")
        let card = try #require(fixture.board.cards.last)
        let session = fixture.session
        // Runs when the start wait first suspends, after it noted the alerts.
        let raised = Task { @MainActor in
            session.openFolderErrorTitle = "Git Error"
            session.openFolderErrorMessage = "A Git command failed."
            session.isOpenFolderErrorPresented = true
        }
        let report = try await withShortStartWait(steps: 3) {
            try await CanvasTerminalStarter.start(
                card: card, groupID: terminalGroupID(of: card), line: nil, board: fixture.board,
                session: session, onGiveUp: {})
        }
        await raised.value
        #expect(session.isOpenFolderErrorPresented)
        #expect(report.hold != .refused)
        let message = CanvasAgentActions.startMessage(
            report, title: card.title, kind: .start, lineBytes: nil)
        #expect(!message.contains("terminal manager refused"))
        session.isOpenFolderErrorPresented = false
    }

    @Test("A Terminal Group alert during the start wait is reported as a refusal")
    func terminalGroupAlertIsARefusal() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call("terminal_create", ["title": "Plain"])
        #expect(created.toolResult?.state == "stopped")
        let card = try #require(fixture.board.cards.last)
        let session = fixture.session
        let raised = Task { @MainActor in
            session.openFolderErrorTitle = WorkspaceSession.terminalGroupErrorTitle
            session.openFolderErrorMessage = "The terminal could not start."
            session.isOpenFolderErrorPresented = true
        }
        let report = try await withShortStartWait(steps: 3) {
            try await CanvasTerminalStarter.start(
                card: card, groupID: terminalGroupID(of: card), line: nil, board: fixture.board,
                session: session, onGiveUp: {})
        }
        await raised.value
        #expect(report.hold == .refused)
        let message = CanvasAgentActions.startMessage(
            report, title: card.title, kind: .start, lineBytes: nil)
        #expect(message.contains("terminal manager refused"))
        session.isOpenFolderErrorPresented = false
    }

    @Test("A Terminal Group alert that was already shown is not read as a new refusal")
    func existingTerminalGroupAlertIsNotNew() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        let created = try await fixture.call("terminal_create", ["title": "Plain"])
        #expect(created.toolResult?.state == "stopped")
        let card = try #require(fixture.board.cards.last)
        let session = fixture.session
        session.openFolderErrorTitle = WorkspaceSession.terminalGroupErrorTitle
        session.isOpenFolderErrorPresented = true
        let report = try await withShortStartWait(steps: 2) {
            try await CanvasTerminalStarter.start(
                card: card, groupID: terminalGroupID(of: card), line: nil, board: fixture.board,
                session: session, onGiveUp: {})
        }
        #expect(report.hold != .refused)
        session.isOpenFolderErrorPresented = false
    }

    @Test("The drain types each queued line once, in order, and clears the queue")
    func drainTypesOnce() async throws {
        let fixture = try await CanvasAgentFixture()
        let lead = fixture.cards[0]
        let typed = TypedLines()
        #expect(fixture.board.queueTerminalLine("cd /tmp", for: lead.id))
        #expect(fixture.board.queueTerminalLine("claude", for: lead.id))
        let first = Task { await drain(fixture, lead, typed) }
        let second = Task { await drain(fixture, lead, typed) }
        _ = await (first.value, second.value)
        #expect(typed.lines == ["cd /tmp", "claude"])
        #expect(fixture.board.pendingTerminalLines[lead.id] == nil)
        let again = await drain(fixture, lead, typed)
        #expect(again)
        #expect(typed.lines.count == 2)
    }

    @Test("A refused send keeps the line at the front for the next drain")
    func refusedSendStaysQueued() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Queue"))
        try board.add(title: "T", content: .note(snapshot: ""))
        let card = try #require(board.cards.first).id
        #expect(board.queueTerminalLine("one", for: card))
        #expect(board.queueTerminalLine("two", for: card))
        #expect(board.drainPendingTerminalLines(for: card) { _ in false } == 0)
        #expect(board.pendingTerminalLines[card]?.map(\.text) == ["one", "two"])
        let typed = TypedLines()
        #expect(
            board.drainPendingTerminalLines(for: card) {
                typed.lines.append($0)
                return true
            }
                == 2)
        #expect(typed.lines == ["one", "two"])
        #expect(board.pendingTerminalLines[card] == nil)
    }

    @Test("The queue is bounded, expires, and goes with its node or board")
    func queueLifecycle() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Queue"))
        try board.add(title: "A", content: .note(snapshot: ""))
        try board.add(title: "B", content: .note(snapshot: ""))
        let a = board.cards[0].id
        let b = board.cards[1].id
        for index in 0..<CanvasBoardState.pendingTerminalLineLimit {
            #expect(board.queueTerminalLine("line \(index)", for: a))
        }
        #expect(!board.queueTerminalLine("one too many", for: a))
        // Old lines are dropped, not typed long after the request.
        let old = Date(timeIntervalSinceNow: -CanvasBoardState.pendingTerminalLineLifetime - 1)
        #expect(board.queueTerminalLine("stale", for: b, now: old))
        let typed = TypedLines()
        board.drainPendingTerminalLines(for: b) {
            typed.lines.append($0)
            return true
        }
        #expect(typed.lines.isEmpty)
        #expect(board.pendingTerminalLines[b] == nil)
        // Removing the card drops its lines.
        board.select([a])
        try board.removeSelection()
        #expect(board.pendingTerminalLines[a] == nil)
        #expect(board.queueTerminalLine("x", for: b))
        board.discardPendingTerminalLines()
        #expect(board.pendingTerminalLines.isEmpty)
    }

    @Test("A drain for a card that left the board clears its lines and stops")
    func drainStopsWhenTheCardIsGone() async throws {
        let fixture = try await CanvasAgentFixture()
        let lead = fixture.cards[0]
        let typed = TypedLines()
        let ghost = CanvasCardID()
        #expect(fixture.board.queueTerminalLine("x", for: ghost))
        let done = await drain(fixture, lead, typed, card: ghost)
        #expect(!done)
        #expect(typed.lines.isEmpty)
        #expect(fixture.board.pendingTerminalLines[ghost] == nil)
    }

    @Test("A link that cannot be made is reported, and the node stays")
    func linkFailureIsReportedNotThrown() async throws {
        let fixture = try await CanvasAgentFixture()
        fixture.board.setAgentControlMode(.allow)
        // A caller whose node is not on the board: the node is created, the edge
        // from the caller cannot be.
        let stranger = CanvasCard(
            title: "Gone", rect: CanvasRect(x: 0, y: 0, width: 300, height: 200),
            content: .note(snapshot: ""))
        let caller = CanvasAgentCaller(
            session: fixture.session, board: fixture.board, card: stranger,
            controllerID: UUID(), provider: "claude",
            sendMessage: { _, _ in .init() })
        var call = CanvasAgentToolCall(tool: .terminalCreate)
        call.title = "Orphan Peer"
        call.link = true
        let response = await CanvasAgentActions.perform(call, caller: caller)
        #expect(response.error == nil)
        let result = try #require(response.toolResult)
        #expect(fixture.board.cards.count == 3)
        #expect(fixture.board.connections.isEmpty)
        #expect(result.nodeID != nil)
        #expect(result.edgeID == nil)
        #expect(result.mention == "@orphan-peer")
        let message = try #require(result.message)
        #expect(message.contains("link was not made"))
        #expect(message.contains("edge_create"))
        #expect(message.contains("link_set_state"))
    }

    @Test("Start messages name the lease cap and the start limit, and never a line")
    func startMessagesNameTheReason() {
        var report = CanvasTerminalStartReport()
        report.queuedLines = 2
        report.hold = .leaseCap
        let cap = CanvasAgentActions.startMessage(
            report, title: "Peer", kind: .create, lineBytes: 120)
        #expect(cap.contains("Four Ensemble terminals"))
        #expect(cap.contains("120-byte"))
        #expect(cap.contains("queued, not typed"))
        report.hold = .unavailable
        let limit = CanvasAgentActions.startMessage(
            report, title: "Peer", kind: .send, lineBytes: 10)
        #expect(limit.contains("live-session limit"))
        report.hold = nil
        report.running = true
        let live = CanvasAgentActions.startMessage(
            report, title: "Peer", kind: .create, lineBytes: 120)
        #expect(live.contains("running"))
        #expect(live.contains("ensemble_describe"))
        #expect(!live.contains("queued, not typed"))
        #expect(CanvasAgentActions.queueFullMessage("Peer").contains("queued lines"))
    }

    private func drain(
        _ fixture: CanvasAgentFixture, _ lead: CanvasCard, _ typed: TypedLines,
        card: CanvasCardID? = nil
    ) async -> Bool {
        await CanvasTerminalStarter.drain(
            card: card ?? lead.id, groupID: terminalGroupID(of: lead), board: fixture.board,
            session: fixture.session, settle: 0, isReady: { _ in true },
            send: { _, line in
                typed.lines.append(line)
                return true
            })
    }

    private func terminalGroupID(of card: CanvasCard) -> TerminalGroupID {
        guard case .terminal(let id) = card.content else {
            preconditionFailure("not a terminal card")
        }
        return id
    }
}
