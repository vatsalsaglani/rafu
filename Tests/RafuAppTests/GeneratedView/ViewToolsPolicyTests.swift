import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Removes the fixture's temporary workspace.
private final class ViewPolicyScratchFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-view-policy-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// An open Ensemble and a Claude caller on one of its nodes. No terminal and
/// no MCP socket: the calls go straight to `CanvasAgentActions.handle`, the
/// same entry the bridge uses after it checked the token.
@MainActor
private struct ViewPolicyFixture {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let caller: CanvasAgentCaller
    private let scratch = ViewPolicyScratchFolder()

    init(mode: CanvasAgentControlMode) async throws {
        let scratch = scratch
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.view-policy-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: scratch.url.appending(path: "state"))
            ))
        #expect(await session.canvas.configure(root: scratch.url))
        let board = try #require(await session.canvas.create(title: "View policy"))
        try board.add(title: "Lead", content: .note(snapshot: ""))
        board.setAgentControlMode(mode)
        let card = try #require(board.cards.first)
        self.session = session
        self.board = board
        caller = CanvasAgentCaller(
            session: session, board: board, card: card, controllerID: UUID(),
            provider: "claude", sendMessage: { _, _ in CanvasBridgeResponse(error: "No link.") })
    }

    func handle(_ tool: String, _ arguments: [String: Any]) async throws -> CanvasBridgeResponse {
        let call = try CanvasAgentToolCall.parse(tool: tool, arguments: arguments)
        return await CanvasAgentActions.handle(call, caller: caller)
    }

    /// Bounded: yields until an approval for this board appears.
    func pendingApproval() async -> CanvasAgentApproval? {
        for _ in 0..<10_000 {
            if let approval = CanvasAgentCenter.shared.approvals(for: board.id).first {
                return approval
            }
            await Task.yield()
        }
        return nil
    }

    var views: [CanvasCard] {
        board.cards.filter { CanvasAgentKinds.kind(of: $0.content) == "view" }
    }
}

private var threeElementSpec: [String: Any] {
    [
        "root": "card",
        "elements": [
            "card": [
                "type": "Card", "props": ["title": "Secret title"], "children": ["t", "x"],
            ],
            "t": [
                "type": "Table",
                "props": ["columns": ["Name"], "rows": [["private row"]]], "children": [],
            ],
            "x": ["type": "Text", "props": ["text": "private words"], "children": []],
        ],
    ]
}

/// The card implementation (jr-4a) installs the host at app start. Until it
/// merges, the paths that need a real card answer "not available", and the
/// checks that need the card return early here.
@MainActor
private var hostInstalled: Bool { GeneratedViewHostRegistry.shared.host != nil }

@Suite("View tools under Agent control")
@MainActor
struct ViewToolsPolicyTests {
    @Test("Off refuses view_render and view_update with the Off message")
    func offRefuses() async throws {
        let fixture = try await ViewPolicyFixture(mode: .off)
        let render = try await fixture.handle("view_render", ["spec": threeElementSpec])
        #expect(render.error == CanvasAgentPolicy.offMessage)
        let update = try await fixture.handle(
            "view_update",
            ["node_id": fixture.board.cards[0].id.rawValue.uuidString, "reset": true])
        #expect(update.error == CanvasAgentPolicy.offMessage)
        #expect(fixture.views.isEmpty)
    }

    @Test("Ask shows counts and types only; approving runs the call")
    func askShowsCountsAndTypes() async throws {
        let fixture = try await ViewPolicyFixture(mode: .ask)
        let task = Task {
            try await fixture.handle("view_render", ["spec": threeElementSpec, "title": "Report"])
        }
        let approval = try #require(await fixture.pendingApproval())
        let summary = approval.summary.joined(separator: "\n")
        #expect(summary.contains("View: 3 elements; Card, Table, Text"))
        #expect(!summary.contains("Secret"))
        #expect(!summary.contains("private"))
        #expect(approval.allowsAlways)
        CanvasAgentCenter.shared.decide(approval.id, .once)
        let response = try await task.value
        guard hostInstalled else {
            #expect(response.error == GeneratedViewCopy.unavailable)
            #expect(fixture.views.isEmpty)
            return
        }
        #expect(response.error == nil)
        #expect(fixture.views.count == 1)
        #expect(fixture.board.notice?.action?.title == "Undo")
        fixture.board.performUndo()
        #expect(fixture.views.isEmpty)
    }

    @Test("Allow runs at once")
    func allowRuns() async throws {
        let fixture = try await ViewPolicyFixture(mode: .allow)
        let response = try await fixture.handle("view_render", ["spec": threeElementSpec])
        #expect(CanvasAgentCenter.shared.approvals(for: fixture.board.id).isEmpty)
        guard hostInstalled else {
            #expect(response.error == GeneratedViewCopy.unavailable)
            return
        }
        #expect(response.error == nil)
        #expect(fixture.views.count == 1)
    }

    @Test("A spec that is not root plus elements is refused before any approval")
    func shapeRefusedAtParse() async throws {
        #expect(throws: CanvasAgentToolError.self) {
            _ = try CanvasAgentToolCall.parse(tool: "view_render", arguments: ["spec": ["root": 3]])
        }
        do {
            _ = try CanvasAgentToolCall.parse(tool: "view_render", arguments: ["spec": "text"])
            Issue.record("A text spec parsed")
        } catch {
            #expect(error.message.hasPrefix("Invalid value for \"spec\":"))
        }
    }

    @Test("An invalid component returns the validator's message as the tool error")
    func invalidComponent() async throws {
        let fixture = try await ViewPolicyFixture(mode: .allow)
        let response = try await fixture.handle(
            "view_render",
            ["spec": ["root": "b", "elements": ["b": ["type": "NoSuchThing", "props": [:]]]]])
        guard hostInstalled else {
            #expect(response.error == GeneratedViewCopy.unavailable)
            return
        }
        #expect(response.error?.hasPrefix("Invalid value for \"spec\":") == true)
        #expect(fixture.views.isEmpty)
    }

    @Test("view_update on a note is refused for node_id")
    func updateOnANote() async throws {
        let fixture = try await ViewPolicyFixture(mode: .allow)
        let response = try await fixture.handle(
            "view_update",
            ["node_id": fixture.board.cards[0].id.rawValue.uuidString, "reset": true])
        guard hostInstalled else {
            #expect(response.error == GeneratedViewCopy.unavailable)
            return
        }
        #expect(response.error == CanvasAgentToolError.invalidArgument("node_id").message)
    }
}
