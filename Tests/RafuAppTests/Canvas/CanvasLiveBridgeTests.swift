import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
private final class CanvasBridgeClock {
    var date = Date(timeIntervalSince1970: 1_000)
}

/// Records the begin/end activity calls the bridge makes instead of changing
/// the test process's power assertions.
@MainActor
private final class CanvasActivityProbe {
    private(set) var options: [ProcessInfo.ActivityOptions] = []
    private(set) var reasons: [String] = []
    private(set) var ended = 0
    var active: Int { options.count - ended }

    func begin(_ value: ProcessInfo.ActivityOptions, _ reason: String) -> any NSObjectProtocol {
        options.append(value)
        reasons.append(reason)
        return NSObject()
    }

    func end() { ended += 1 }
}

@MainActor
private struct CanvasLiveBridgeFixture {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let controllers: [WorkspaceTerminalController]
    let cards: [CanvasCard]
    let tokens = [
        "first-private-capability", "second-private-capability", "third-private-capability",
    ]
    let clients = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
    let clock: CanvasBridgeClock
    let bridge: CanvasLiveBridge
    let edge: UUID

    init(activity: CanvasActivityProbe? = nil) throws {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-bridge-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker())
        let board = CanvasBoardState(document: CanvasDocument(title: "Bridge test"))
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        var controllers: [WorkspaceTerminalController] = []
        for index in 0..<3 {
            let group = try session.terminal.createLiveGroup(
                instantiation: .ordinaryShell(
                    startingDirectory: "/tmp", shell: shell, profile: profile))
            let id = try #require(group.panes.first?.sessionID)
            controllers.append(try #require(session.terminal.sessions.first { $0.id == id }))
            try board.add(title: "Terminal \(index)", content: .terminal(groupID: group.id))
        }
        let cards = board.cards
        try board.addConnection(from: cards[0].id, to: cards[1].id, behavior: .session)
        let edge = try #require(board.connections.first?.id)
        let routes = Dictionary(uniqueKeysWithValues: zip(controllers.map(\.id), cards.map(\.id)))
        let clock = CanvasBridgeClock()
        let bridge = CanvasLiveBridge(
            location: { id in
                guard let cardID = routes[id],
                    let card = board.cards.first(where: { $0.id == cardID })
                else { return nil }
                return (session, board, card)
            }, now: { clock.date },
            beginActivity: { options, reason in
                activity?.begin(options, reason) ?? NSObject()
            },
            endActivity: { _ in activity?.end() })
        board.revokeSessionLinks = { [weak bridge, weak board] edges in
            guard let board else { return }
            for edge in edges { bridge?.disable(edge, in: board) }
        }
        self.session = session
        self.board = board
        self.controllers = controllers
        self.cards = cards
        self.clock = clock
        self.bridge = bridge
        self.edge = edge
        for index in 0..<3 { bridge.install(controller: controllers[index], token: tokens[index]) }
    }

    func request(
        _ index: Int, _ operation: String, destination: Int? = nil, text: String? = nil,
        client: String? = nil, provider: String = "claude"
    ) -> CanvasBridgeRequest {
        CanvasBridgeRequest(
            token: tokens[index], operation: operation, clientID: client ?? clients[index],
            provider: provider, destination: destination.map { cards[$0].id.rawValue.uuidString },
            text: text)
    }

    func registerPair() async {
        #expect(await bridge.handle(request(0, "register")).error == nil)
        #expect(await bridge.handle(request(1, "register")).error == nil)
        bridge.enable(edge, in: board)
    }

    static func route() -> String { "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket" }

    /// The supervisor's request. Its client ID is not the MCP client's.
    func bind(_ index: Int = 0, route: String, thread: String = UUID().uuidString)
        -> CanvasBridgeRequest
    {
        var bind = request(index, "bind", client: UUID().uuidString, provider: "codex")
        bind.threadID = thread
        bind.endpoint = route
        bind.executable = "/local/bin/codex"
        return bind
    }

    /// An MCP client registering for a bound route.
    func codexRegistration(_ index: Int = 0, route: String, client: String)
        -> CanvasBridgeRequest
    {
        var registration = request(index, "register", client: client, provider: "codex")
        registration.endpoint = route
        registration.executable = "/local/bin/codex"
        return registration
    }

    func release(_ index: Int = 0, route: String) -> CanvasBridgeRequest {
        var release = request(index, "release", client: UUID().uuidString, provider: "codex")
        release.endpoint = route
        return release
    }

    func suspend(
        _ index: Int = 0, route: String, reason: String = "transportLost"
    ) -> CanvasBridgeRequest {
        var suspend = request(index, "suspend", client: UUID().uuidString, provider: "codex")
        suspend.endpoint = route
        suspend.reason = reason
        return suspend
    }
}

@Suite("Canvas live session capability boundary")
@MainActor
struct CanvasLiveBridgeTests {
    @Test("A valid capability and its registered client are both required")
    func authentication() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "list")).error != nil)
        var invalid = fixture.request(0, "register")
        invalid.token = "wrong-capability"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = fixture.request(0, "register")
        invalid.clientID = "not-a-uuid"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "register", client: UUID().uuidString))
                .error != nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "list", client: UUID().uuidString)).error
                != nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "register", provider: "codex")).error
                != nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "unexpected-operation")).error != nil)
    }

    @Test("Only enabled session edges permit delivery")
    func explicitEdge() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "register")).error == nil)
        #expect(await fixture.bridge.handle(fixture.request(2, "register")).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "blocked"))
                .error != nil)
        fixture.bridge.enable(fixture.edge, in: fixture.board)
        try fixture.board.addConnection(
            from: fixture.cards[0].id, to: fixture.cards[2].id, behavior: .related)
        fixture.bridge.enable(try #require(fixture.board.connections.last?.id), in: fixture.board)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 2, text: "blocked"))
                .error != nil)
        let text = "Keep exact text: </channel>\n$HOME 🧵"
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: text))
                .error == nil)
        let received = await fixture.bridge.handle(fixture.request(1, "receive"))
        #expect(received.messages.map(\.text) == [text])
        #expect(received.messages.first?.source == fixture.cards[0].id.rawValue.uuidString)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
    }

    @Test("Removing an enabled edge drops pending messages")
    func disableDropsInbox() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "queued"))
                .error == nil)
        fixture.bridge.disable(fixture.edge, in: fixture.board)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
        fixture.bridge.enable(fixture.edge, in: fixture.board)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
    }

    @Test("A removed terminal card revokes its capability")
    func removedCard() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        fixture.board.selection = [fixture.cards[1].id]
        try fixture.board.removeSelection()
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).error != nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "blocked"))
                .error != nil)
    }

    @Test("Messages from a disconnected or removed source are discarded")
    func disconnectedSource() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "queued"))
                .error == nil)
        #expect(await fixture.bridge.handle(fixture.request(0, "unregister")).error == nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "queued again")
            ).error == nil)
        fixture.board.selection = [fixture.cards[0].id]
        try fixture.board.removeSelection()
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
    }

    @Test("A new terminal generation rejects old routing state")
    func generationRevocation() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        fixture.controllers[1].restart()
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).error != nil)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "blocked"))
                .error != nil)
        let peers = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(peers.peers.first?.connected == false)
    }

    @Test("Disconnect and stale-client takeover clear queued messages")
    func disconnectAndTakeover() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "old"))
                .error == nil)
        fixture.clock.date.addTimeInterval(16)
        let replacement = UUID().uuidString
        #expect(
            await fixture.bridge.handle(fixture.request(1, "register", client: replacement)).error
                == nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).error != nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "receive", client: replacement)).messages
                .isEmpty)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "unregister", client: replacement)).error
                == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "list", client: replacement)).error
                != nil)
        fixture.bridge.remove(fixture.controllers[0])
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error != nil)
    }

    @Test("Inbox size and UTF-8 message limits reject excess data without spending send quota")
    func capacityAndByteBounds() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(
            await fixture.bridge.handle(
                fixture.request(
                    0, "send", destination: 1,
                    text: String(repeating: "é", count: 8_193))
            ).error != nil)
        for index in 0..<16 {
            #expect(
                await fixture.bridge.handle(
                    fixture.request(0, "send", destination: 1, text: "\(index)")
                ).error == nil)
        }
        for _ in 0..<5 {
            #expect(
                await fixture.bridge.handle(
                    fixture.request(0, "send", destination: 1, text: "full")
                ).error != nil)
        }
        var received: [String] = []
        for _ in 0..<16 {
            let batch = await fixture.bridge.handle(fixture.request(1, "receive"))
            #expect(batch.messages.count == 1)
            received.append(contentsOf: batch.messages.map(\.text))
        }
        #expect(received == (0..<16).map(String.init))
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
        for _ in 0..<4 {
            #expect(
                await fixture.bridge.handle(
                    fixture.request(0, "send", destination: 1, text: "allowed")
                ).error == nil)
        }
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "rate limit")
            ).error != nil)
        fixture.clock.date.addTimeInterval(61)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "allowed again")
            ).error == nil)
    }

    @Test("Codex routes reject arbitrary executables and non-private endpoints")
    func codexRouteValidation() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        var request = fixture.request(0, "register", provider: "codex")
        request.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        request.executable = "/bin/sh"
        #expect(await fixture.bridge.handle(request).error != nil)
        request.executable = "/local/bin/codex"
        request.endpoint = "unix:///tmp/other/socket"
        #expect(await fixture.bridge.handle(request).error != nil)
        request.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        #expect(await fixture.bridge.handle(request).error == nil)
        // This check validates route shape only. Delivery validates filesystem ownership off-main.
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id).contains(
                "list Ensemble connections"))
    }

    @Test("A full inbox drains in bounded frames without losing large messages")
    func boundedReceiveFrames() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        let texts = (0..<16).map { "\($0):" + String(repeating: "x", count: 16_000) }
        for text in texts {
            #expect(
                await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: text))
                    .error == nil)
        }
        var received: [String] = []
        for _ in texts {
            let response = await fixture.bridge.handle(fixture.request(1, "receive"))
            #expect(response.messages.count == 1)
            #expect(try JSONEncoder().encode(response).count < 24 * 1_024)
            received.append(contentsOf: response.messages.map(\.text))
        }
        #expect(received == texts)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
    }

    @Test("JSON escaping cannot turn a small accepted message into an oversized frame")
    func escapedMessageBound() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        let text = String(repeating: "\u{0001}", count: 8_000)
        #expect(text.utf8.count < 16_384)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: text))
                .error != nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "next"))
                .error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "receive")).messages.map(\.text) == [
                "next"
            ])
    }

    @Test("Peer lists have unique identities and bounded encoded titles")
    func boundedPeerList() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        for _ in 3..<100 {
            try fixture.board.add(
                title: String(repeating: "🧵", count: 120), content: .note(snapshot: ""))
        }
        for card in fixture.board.cards.dropFirst() {
            try fixture.board.addConnection(from: fixture.cards[0].id, to: card.id)
        }
        let response = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(response.peers.count == 99)
        #expect(Set(response.peers.map(\.id)).count == 99)
        #expect(response.peers.allSatisfy { $0.title.unicodeScalars.count <= 40 })
        #expect(try JSONEncoder().encode(response).count <= 24 * 1_024)
    }

    @Test("Deleting an edge and undoing the deletion does not restore session permission")
    func edgeUndoDoesNotRestorePermission() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        try fixture.board.edit { $0.connections.removeAll { $0.id == fixture.edge } }
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        fixture.board.performUndo()
        #expect(fixture.board.connections.contains { $0.id == fixture.edge })
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "blocked"))
                .error != nil)
        fixture.board.performRedo()
        fixture.board.performUndo()
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        fixture.bridge.enable(fixture.edge, in: fixture.board)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "explicit approval")
            ).error == nil)
    }

    @Test("Changing an edge endpoint under the same identity revokes session permission")
    func edgeRetargetRevokesPermission() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(await fixture.bridge.handle(fixture.request(2, "register")).error == nil)
        try fixture.board.edit { value in
            let index = try #require(value.connections.firstIndex { $0.id == fixture.edge })
            value.connections[index].to = fixture.cards[2].id
        }
        #expect(fixture.board.connections.first?.id == fixture.edge)
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 2, text: "blocked"))
                .error != nil)
        fixture.board.performUndo()
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "still blocked")
            ).error != nil)
    }

    @Test("Changing an edge label keeps its existing session permission")
    func edgeLabelPreservesPermission() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        try fixture.board.edit { value in
            let index = try #require(value.connections.firstIndex { $0.id == fixture.edge })
            value.connections[index].label = "Review"
        }
        #expect(fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        fixture.board.performUndo()
        #expect(fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        fixture.board.performRedo()
        #expect(fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "allowed"))
                .error == nil)
    }

    @Test("Supervisor binding before MCP registration preserves the visible thread")
    func codexBindBeforeRegistration() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let supervisorClient = UUID().uuidString
        let thread = UUID().uuidString
        let endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        var bind = fixture.request(0, "bind", client: supervisorClient, provider: "codex")
        bind.threadID = thread
        bind.endpoint = endpoint
        bind.executable = "/local/bin/codex"
        #expect(await fixture.bridge.handle(bind).error == nil)
        #expect(await fixture.bridge.handle(bind).error == nil)
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id)
                == "Run claude or codex to connect")
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "list", client: supervisorClient, provider: "codex")
            ).error != nil)

        var registration = fixture.request(0, "register", provider: "codex")
        registration.endpoint = endpoint
        registration.executable = "/local/bin/codex"
        #expect(registration.threadID == nil)
        #expect(await fixture.bridge.handle(registration).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
        // A different bind would succeed if initial MCP registration had erased the thread.
        bind.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(bind).error != nil)
        // The active MCP client can still report the TUI's explicit /new thread.
        registration.threadID = bind.threadID
        #expect(await fixture.bridge.handle(registration).error == nil)
        #expect(await fixture.bridge.handle(bind).error == nil)
    }

    @Test("Supervisor binding after MCP registration supplies identity without taking its client")
    func codexBindAfterRegistration() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        var registration = fixture.request(0, "register", provider: "codex")
        registration.endpoint = endpoint
        registration.executable = "/local/bin/codex"
        #expect(await fixture.bridge.handle(registration).error == nil)
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id).contains(
                "list Ensemble connections"))

        let supervisorClient = UUID().uuidString
        var bind = fixture.request(0, "bind", client: supervisorClient, provider: "codex")
        bind.threadID = UUID().uuidString
        bind.endpoint = endpoint
        bind.executable = "/local/bin/codex"
        #expect(await fixture.bridge.handle(bind).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
        #expect(
            await fixture.bridge.handle(fixture.request(0, "list", provider: "codex")).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "list", client: supervisorClient, provider: "codex")
            ).error != nil)
    }

    @Test("Binding requires its terminal capability and cannot replace an established thread")
    func codexBindRejectsInvalidAuthority() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        var bind = fixture.request(0, "bind", client: UUID().uuidString, provider: "codex")
        bind.threadID = UUID().uuidString
        bind.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        bind.executable = "/local/bin/codex"
        var invalid = bind
        invalid.token = "wrong-capability"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = bind
        invalid.endpoint = "unix:///tmp/unowned/socket"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = bind
        invalid.executable = "/bin/sh"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = bind
        invalid.threadID = "not-a-thread"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        #expect(await fixture.bridge.handle(bind).error == nil)
        invalid = bind
        invalid.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = bind
        invalid.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        #expect(await fixture.bridge.handle(bind).error == nil)
    }

    @Test("A supervisor cannot bind a Codex thread over an active Claude client")
    func codexBindCannotReplaceClaude() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        var bind = fixture.request(0, "bind", client: UUID().uuidString, provider: "codex")
        bind.threadID = UUID().uuidString
        bind.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        bind.executable = "/local/bin/codex"
        #expect(await fixture.bridge.handle(bind).error != nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Claude connected")
        #expect(await fixture.bridge.handle(fixture.request(0, "list")).error == nil)
    }

    @Test("The same saved board in another window has separate session permissions")
    func sessionPermissionsBelongToBoardInstance() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let otherWindow = CanvasBoardState(document: try fixture.board.snapshot())
        #expect(otherWindow.id == fixture.board.id)
        #expect(otherWindow.connections.first?.id == fixture.edge)
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "register")).error == nil)

        fixture.bridge.enable(fixture.edge, in: otherWindow)
        #expect(fixture.bridge.isEnabled(fixture.edge, in: otherWindow))
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "blocked"))
                .error != nil)

        fixture.bridge.enable(fixture.edge, in: fixture.board)
        fixture.bridge.disable(fixture.edge, in: otherWindow)
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: otherWindow))
        #expect(fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "allowed"))
                .error == nil)

        let reopened = CanvasBoardState(document: try fixture.board.snapshot())
        #expect(!fixture.bridge.isEnabled(fixture.edge, in: reopened))
        #expect(fixture.bridge.isEnabled(fixture.edge, in: fixture.board))
    }

    @Test("Supervisor suspension disconnects the peer and blocks all later session operations")
    func suspendedCodexCannotReconnect() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        let endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        var registration = fixture.request(1, "register", provider: "codex")
        registration.threadID = UUID().uuidString
        registration.endpoint = endpoint
        registration.executable = "/local/bin/codex"
        #expect(await fixture.bridge.handle(registration).error == nil)
        fixture.bridge.enable(fixture.edge, in: fixture.board)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "list")).peers.first?.connected == true)

        var suspend = fixture.request(1, "suspend", client: UUID().uuidString, provider: "codex")
        suspend.endpoint = endpoint
        #expect(suspend.clientID != registration.clientID)
        #expect(await fixture.bridge.handle(suspend).error == nil)
        #expect(await fixture.bridge.handle(suspend).error == nil)
        #expect(
            fixture.bridge.status(for: fixture.controllers[1].id)
                == "Session changed. Run codex again to reconnect.")
        #expect(
            await fixture.bridge.handle(fixture.request(0, "list")).peers.first?.connected == false)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "blocked"))
                .error != nil)

        for operation in ["register", "bind", "list", "send", "receive"] {
            var request = registration
            request.operation = operation
            request.destination = fixture.cards[0].id.rawValue.uuidString
            request.text = "blocked"
            #expect(await fixture.bridge.handle(request).error != nil)
        }
        fixture.clock.date.addTimeInterval(16)
        registration.clientID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error != nil)
    }

    @Test("Suspension requires the terminal capability, Codex provider, and matching bound route")
    func invalidSuspensionDoesNotDisconnect() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        var registration = fixture.request(0, "register", provider: "codex")
        registration.endpoint = endpoint
        registration.executable = "/local/bin/codex"
        registration.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error == nil)
        var suspend = fixture.request(0, "suspend", client: UUID().uuidString, provider: "codex")
        suspend.endpoint = endpoint
        var invalid = suspend
        invalid.token = "wrong-capability"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = suspend
        invalid.clientID = "not-a-client"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = suspend
        invalid.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = suspend
        invalid.endpoint = nil
        #expect(await fixture.bridge.handle(invalid).error != nil)
        invalid = suspend
        invalid.provider = "claude"
        #expect(await fixture.bridge.handle(invalid).error != nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
        #expect(
            await fixture.bridge.handle(fixture.request(0, "list", provider: "codex")).error == nil)

        #expect(await fixture.bridge.handle(fixture.request(1, "register")).error == nil)
        suspend.token = fixture.tokens[1]
        #expect(await fixture.bridge.handle(suspend).error != nil)
        #expect(fixture.bridge.status(for: fixture.controllers[1].id) == "Claude connected")
    }

    @Test("Only a new terminal capability clears suspension")
    func replacementCapabilityClearsSuspension() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        var registration = fixture.request(0, "register", provider: "codex")
        registration.endpoint = endpoint
        registration.executable = "/local/bin/codex"
        registration.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error == nil)
        var suspend = registration
        suspend.operation = "suspend"
        suspend.clientID = UUID().uuidString
        #expect(await fixture.bridge.handle(suspend).error == nil)

        let replacement = "replacement-private-capability"
        fixture.bridge.install(controller: fixture.controllers[0], token: replacement)
        #expect(await fixture.bridge.handle(registration).error != nil)
        #expect(await fixture.bridge.handle(suspend).error != nil)
        registration.token = replacement
        registration.clientID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
    }

    @Test("Peer providers identify live Claude and Codex without exposing private routes")
    func livePeerProviders() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        fixture.bridge.enable(fixture.edge, in: fixture.board)
        let initial = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(initial.peers.first?.connected == false)
        #expect(initial.peers.first?.linkState == "disconnected")
        #expect(initial.peers.first?.provider == nil)

        var registration = fixture.request(1, "register", provider: "codex")
        registration.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        registration.executable = "/local/bin/codex"
        registration.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error == nil)
        let claudePeers = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(claudePeers.peers.first?.provider == "codex")
        #expect(claudePeers.peers.first?.title == fixture.cards[1].title)
        #expect(claudePeers.peers.first?.kind == "Terminal")
        #expect(claudePeers.peers.first?.connected == true)
        #expect(claudePeers.peers.first?.linkState == "live")
        let codexPeers = await fixture.bridge.handle(fixture.request(1, "list", provider: "codex"))
        #expect(codexPeers.peers.first?.provider == "claude")
        let encoded = String(decoding: try JSONEncoder().encode(claudePeers), as: UTF8.self)
        #expect(!encoded.contains(fixture.tokens[1]))
        #expect(!encoded.contains("/local/bin"))
        #expect(!encoded.contains("rafu-cdx-"))

        fixture.bridge.disable(fixture.edge, in: fixture.board)
        let paused = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(paused.peers.first?.provider == nil)
        #expect(paused.peers.first?.connected == false)
        #expect(paused.peers.first?.linkState == "paused")
        let denied = await fixture.bridge.handle(
            fixture.request(0, "send", destination: 1, text: "blocked"))
        #expect(denied.error?.contains("Resume it in Rafu Ensemble") == true)
        fixture.bridge.enable(fixture.edge, in: fixture.board)
        fixture.controllers[1].restart()
        let stopped = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(stopped.peers.first?.provider == nil)
        #expect(stopped.peers.first?.connected == false)
    }

    @Test("Renamed peers route by current mention and preserve UUID routing")
    func renamedPeerMentions() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        try fixture.board.edit { value in
            let index = try #require(value.cards.firstIndex { $0.id == fixture.cards[1].id })
            value.cards[index].title = "Frontend Claude"
        }
        let peers = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(peers.peers.first?.mention == "@frontend-claude")
        var named = fixture.request(0, "send", text: "first")
        named.destination = "@frontend-claude"
        #expect(await fixture.bridge.handle(named).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "receive")).messages.map(\.text) == [
                "first"
            ])

        try fixture.board.edit { value in
            let index = try #require(value.cards.firstIndex { $0.id == fixture.cards[1].id })
            value.cards[index].title = "Docs Reviewer"
        }
        #expect(await fixture.bridge.handle(named).error != nil)
        named.destination = "@DOCS-REVIEWER"
        named.text = "renamed"
        #expect(await fixture.bridge.handle(named).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "receive")).messages.map(\.text) == [
                "renamed"
            ])
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "by UUID"))
                .error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "receive")).messages.map(\.text) == [
                "by UUID"
            ])
    }

    @Test("Duplicate normalized names require a peer UUID and never choose a recipient")
    func duplicateMentionsRequireIdentity() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(await fixture.bridge.handle(fixture.request(2, "register")).error == nil)
        try fixture.board.addConnection(
            from: fixture.cards[0].id, to: fixture.cards[2].id, behavior: .session)
        fixture.bridge.enable(try #require(fixture.board.connections.last?.id), in: fixture.board)
        try fixture.board.edit { value in
            for index in value.cards.indices where value.cards[index].id != fixture.cards[0].id {
                value.cards[index].title = index == 1 ? "Résumé" : "Resume"
            }
        }
        let peers = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(peers.peers.filter { $0.mention == "@resume" && $0.connected }.count == 2)
        var named = fixture.request(0, "send", text: "must not be delivered")
        named.destination = "@resume"
        let rejected = await fixture.bridge.handle(named)
        #expect(rejected.error?.contains("More than one") == true)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
        #expect(await fixture.bridge.handle(fixture.request(2, "receive")).messages.isEmpty)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "explicit identity")
            ).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "receive")).messages.map(\.text) == [
                "explicit identity"
            ])
        #expect(await fixture.bridge.handle(fixture.request(2, "receive")).messages.isEmpty)
    }

    @Test("Unknown, unrelated, and paused mentions do not grant access")
    func mentionsRequireAuthorizedConnection() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(await fixture.bridge.handle(fixture.request(2, "register")).error == nil)
        try fixture.board.edit { value in
            let index = try #require(value.cards.firstIndex { $0.id == fixture.cards[2].id })
            value.cards[index].title = "Other Agent"
        }
        try fixture.board.addConnection(
            from: fixture.cards[0].id, to: fixture.cards[2].id, behavior: .related)
        fixture.bridge.enable(try #require(fixture.board.connections.last?.id), in: fixture.board)
        for mention in ["@unknown", "@other-agent", "@", "@!!!"] {
            var request = fixture.request(0, "send", text: "blocked")
            request.destination = mention
            #expect(await fixture.bridge.handle(request).error != nil)
        }
        let listed = await fixture.bridge.handle(fixture.request(0, "list"))
        #expect(
            listed.peers.first(where: { $0.id == fixture.cards[2].id.rawValue.uuidString })?.mention
                == nil)
        fixture.bridge.disable(fixture.edge, in: fixture.board)
        var paused = fixture.request(0, "send", text: "blocked")
        paused.destination = "@terminal-1"
        #expect(await fixture.bridge.handle(paused).error != nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.isEmpty)
        #expect(await fixture.bridge.handle(fixture.request(2, "receive")).messages.isEmpty)
    }

    @Test("A transport failure shows connection loss and remains closed")
    func suspensionDistinguishesTransportLoss() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        var registration = fixture.request(0, "register", provider: "codex")
        registration.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        registration.executable = "/local/bin/codex"
        registration.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error == nil)
        var suspend = registration
        suspend.operation = "suspend"
        suspend.clientID = UUID().uuidString
        suspend.reason = "transportLost"
        #expect(await fixture.bridge.handle(suspend).error == nil)
        let expected = "Connection lost. Run codex again to reconnect."
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == expected)
        #expect(
            fixture.bridge.notice
                == "Codex lost its terminal connection. Run codex again in its terminal to reconnect."
        )
        #expect(await fixture.bridge.handle(registration).error == expected)
        // A legacy retry cannot replace the first cause with a navigation message.
        suspend.reason = nil
        #expect(await fixture.bridge.handle(suspend).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == expected)
    }

    @Test("Suspension accepts fixed causes only and never displays raw failure text")
    func suspensionReasonAllowlist() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        var registration = fixture.request(0, "register", provider: "codex")
        registration.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        registration.executable = "/local/bin/codex"
        registration.threadID = UUID().uuidString
        #expect(await fixture.bridge.handle(registration).error == nil)
        var suspend = registration
        suspend.operation = "suspend"
        suspend.clientID = UUID().uuidString
        suspend.reason = "malformed frame: private payload"
        #expect(await fixture.bridge.handle(suspend).error == "Unsupported suspension reason.")
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
        #expect(fixture.bridge.notice == nil)
        suspend.reason = "sessionChanged"
        #expect(await fixture.bridge.handle(suspend).error == nil)
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id)
                == "Session changed. Run codex again to reconnect.")
        #expect(
            fixture.bridge.notice
                == "Codex changed sessions. Run codex again in its terminal to reconnect.")
    }

    // MARK: Relaunching Codex in the same terminal

    @Test("A relaunched Codex binds and registers after the previous run released the route")
    func codexRebindAfterPreviousCodexExit() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let first = CanvasLiveBridgeFixture.route()
        let second = CanvasLiveBridgeFixture.route()
        let firstClient = UUID().uuidString
        #expect(await fixture.bridge.handle(fixture.bind(route: first)).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: first, client: firstClient)
            ).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")

        #expect(await fixture.bridge.handle(fixture.release(route: first)).error == nil)
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id)
                == "Run claude or codex to connect")

        let secondThread = UUID().uuidString
        #expect(
            await fixture.bridge.handle(fixture.bind(route: second, thread: secondThread)).error
                == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: second, client: UUID().uuidString)
            ).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
    }

    @Test("A relaunched Codex replaces a route whose agent never unregistered")
    func codexRebindAfterUnregisterFailed() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let first = CanvasLiveBridgeFixture.route()
        let second = CanvasLiveBridgeFixture.route()
        let firstClient = UUID().uuidString
        let secondClient = UUID().uuidString
        #expect(await fixture.bridge.handle(fixture.bind(route: first)).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: first, client: firstClient)
            ).error == nil)

        fixture.clock.date.addTimeInterval(16)
        #expect(await fixture.bridge.handle(fixture.bind(route: second)).error == nil)
        // The old client lost its registration, and it cannot retake the new route.
        var receive = fixture.request(0, "receive", client: firstClient, provider: "codex")
        let lost = await fixture.bridge.handle(receive)
        #expect(lost.error == CanvasBridgeResponse.unregisteredMessage)
        #expect(lost.code == CanvasBridgeResponse.unregisteredCode)
        receive = fixture.codexRegistration(route: first, client: firstClient)
        #expect(await fixture.bridge.handle(receive).error != nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: second, client: secondClient)
            ).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
    }

    @Test("A relaunched Codex replaces a suspended route at once and clears its notice")
    func codexRebindAfterSuspension() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let first = CanvasLiveBridgeFixture.route()
        let second = CanvasLiveBridgeFixture.route()
        #expect(await fixture.bridge.handle(fixture.bind(route: first)).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: first, client: UUID().uuidString)
            ).error == nil)
        #expect(await fixture.bridge.handle(fixture.suspend(route: first)).error == nil)
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id)
                == "Connection lost. Run codex again to reconnect.")
        #expect(fixture.bridge.notice != nil)

        #expect(await fixture.bridge.handle(fixture.bind(route: second)).error == nil)
        #expect(fixture.bridge.notice == nil)
        let client = UUID().uuidString
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: second, client: client)
            ).error == nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "list", client: client, provider: "codex")
            ).error == nil)
    }

    @Test("A second agent is refused while the first holds a fresh route")
    func concurrentSecondAgentStillRefused() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let first = CanvasLiveBridgeFixture.route()
        let second = CanvasLiveBridgeFixture.route()
        #expect(await fixture.bridge.handle(fixture.bind(route: first)).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: first, client: UUID().uuidString)
            ).error == nil)

        #expect(await fixture.bridge.handle(fixture.bind(route: second)).error != nil)
        var claude = fixture.request(0, "register", client: UUID().uuidString)
        #expect(await fixture.bridge.handle(claude).error != nil)
        claude = fixture.codexRegistration(route: second, client: UUID().uuidString)
        #expect(await fixture.bridge.handle(claude).error != nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")

        fixture.clock.date.addTimeInterval(16)
        #expect(await fixture.bridge.handle(fixture.bind(route: second)).error == nil)
    }

    @Test("Release needs the matching route and changes nothing otherwise")
    func releaseRequiresMatchingEndpoint() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let route = CanvasLiveBridgeFixture.route()
        #expect(await fixture.bridge.handle(fixture.bind(route: route)).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.codexRegistration(route: route, client: UUID().uuidString)
            ).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.release(route: CanvasLiveBridgeFixture.route()))
                .error != nil)
        var claude = fixture.release(route: route)
        claude.provider = "claude"
        #expect(await fixture.bridge.handle(claude).error != nil)
        var other = fixture.release(1, route: route)
        other.token = "wrong-capability"
        #expect(await fixture.bridge.handle(other).error != nil)
        #expect(fixture.bridge.status(for: fixture.controllers[0].id) == "Codex connected")
    }

    @Test("An agent can unregister while its route is suspended")
    func unregisterWorksWhileSuspended() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let route = CanvasLiveBridgeFixture.route()
        let client = UUID().uuidString
        #expect(await fixture.bridge.handle(fixture.bind(route: route)).error == nil)
        #expect(
            await fixture.bridge.handle(fixture.codexRegistration(route: route, client: client))
                .error == nil)
        #expect(await fixture.bridge.handle(fixture.suspend(route: route)).error == nil)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "unregister", client: client, provider: "codex")
            ).error == nil)
        // The route stays suspended until a new run replaces it.
        #expect(
            fixture.bridge.status(for: fixture.controllers[0].id)
                == "Connection lost. Run codex again to reconnect.")
        #expect(
            await fixture.bridge.handle(fixture.request(0, "list", client: client)).error != nil)
        #expect(
            await fixture.bridge.handle(fixture.bind(route: CanvasLiveBridgeFixture.route()))
                .error == nil)
    }

    @Test("An unknown client is told to register again")
    func unknownClientGetsAStableCode() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        let unknown = await fixture.bridge.handle(
            fixture.request(0, "list", client: UUID().uuidString))
        #expect(unknown.code == CanvasBridgeResponse.unregisteredCode)
    }

    @Test("The power activity is held only while an agent route exists")
    func activityHeldOnlyWhileAgentsAreConnected() async throws {
        let probe = CanvasActivityProbe()
        let fixture = try CanvasLiveBridgeFixture(activity: probe)
        #expect(probe.options.isEmpty)

        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(probe.options.count == 1)
        #expect(await fixture.bridge.handle(fixture.request(1, "register")).error == nil)
        #expect(probe.options.count == 1)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "unregister")).error == nil)
        #expect(probe.active == 1)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "unregister")).error == nil)
        #expect(probe.active == 0)

        let route = CanvasLiveBridgeFixture.route()
        #expect(await fixture.bridge.handle(fixture.bind(route: route)).error == nil)
        #expect(probe.active == 1)
        #expect(await fixture.bridge.handle(fixture.suspend(route: route)).error == nil)
        #expect(probe.active == 0)
        #expect(
            await fixture.bridge.handle(fixture.bind(route: CanvasLiveBridgeFixture.route()))
                .error == nil)
        #expect(probe.active == 1)
        fixture.bridge.remove(fixture.controllers[0])
        #expect(probe.active == 0)

        // Prevent App Nap only. Never keep the Mac or the display awake.
        for options in probe.options {
            #expect(options == .userInitiatedAllowingIdleSystemSleep)
            #expect(!options.contains(.idleSystemSleepDisabled))
            #expect(!options.contains(.idleDisplaySleepDisabled))
        }
    }

    @Test("A released Codex route ends the activity")
    func releaseEndsActivity() async throws {
        let probe = CanvasActivityProbe()
        let fixture = try CanvasLiveBridgeFixture(activity: probe)
        let route = CanvasLiveBridgeFixture.route()
        #expect(await fixture.bridge.handle(fixture.bind(route: route)).error == nil)
        #expect(probe.active == 1)
        #expect(await fixture.bridge.handle(fixture.release(route: route)).error == nil)
        #expect(probe.active == 0)
    }

    // MARK: Per-link state (redesign W6b)

    @Test("A new message link is Paused until the user resumes it, and pause is per link")
    func perLinkPauseAndResume() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        let edge = try #require(fixture.board.connections.first)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .paused)
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(await fixture.bridge.handle(fixture.request(1, "register")).error == nil)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .paused)
        fixture.bridge.resume(fixture.edge, in: fixture.board)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
        fixture.bridge.pause(fixture.edge, in: fixture.board)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .paused)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "held"))
                .error != nil)

        try fixture.board.addConnection(
            from: fixture.cards[0].id, to: fixture.cards[2].id, behavior: .session)
        let second = try #require(fixture.board.connections.last)
        fixture.bridge.resumeAll(in: fixture.board)
        let states = fixture.bridge.linkStates(in: fixture.board)
        #expect(states[fixture.edge] == .live)
        // The third terminal has a capability but no connected agent.
        #expect(states[second.id] == .disconnected(.agentNotRunning))
        fixture.bridge.pauseAll(in: fixture.board)
        #expect(
            fixture.bridge.linkStates(in: fixture.board).values.allSatisfy { $0 == .paused })
    }

    @Test("A stopped terminal makes the link Disconnected, not Failed")
    func stoppedTerminalDisconnects() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        let edge = try #require(fixture.board.connections.first)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
        fixture.bridge.remove(fixture.controllers[1])
        #expect(
            fixture.bridge.linkState(of: edge, in: fixture.board)
                == .disconnected(.sessionEnded))
    }

    @Test("A quit agent leaves the terminal running but the link Disconnected")
    func quitAgentDisconnects() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        let edge = try #require(fixture.board.connections.first)
        #expect(await fixture.bridge.handle(fixture.request(0, "unregister")).error == nil)
        #expect(
            fixture.bridge.linkState(of: edge, in: fixture.board)
                == .disconnected(.agentNotRunning))
        #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
    }

    @Test("A changed Codex conversation and a lost transport map to their own reasons")
    func suspensionMapsToDisconnected() async throws {
        for (reason, expected) in [
            ("sessionChanged", CanvasLinkDisconnectReason.conversationChanged),
            ("transportLost", CanvasLinkDisconnectReason.connectionLost),
        ] {
            let fixture = try CanvasLiveBridgeFixture()
            #expect(await fixture.bridge.handle(fixture.request(0, "register")).error == nil)
            var registration = fixture.request(1, "register", provider: "codex")
            registration.threadID = UUID().uuidString
            registration.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
            registration.executable = "/local/bin/codex"
            #expect(await fixture.bridge.handle(registration).error == nil)
            fixture.bridge.resume(fixture.edge, in: fixture.board)
            let edge = try #require(fixture.board.connections.first)
            #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
            var suspend = registration
            suspend.operation = "suspend"
            suspend.clientID = UUID().uuidString
            suspend.reason = reason
            #expect(await fixture.bridge.handle(suspend).error == nil)
            #expect(
                fixture.bridge.linkState(of: edge, in: fixture.board) == .disconnected(expected))
        }
    }

    @Test("A refused send marks the link Failed until the next accepted message or user action")
    func refusedSendFails() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        let edge = try #require(fixture.board.connections.first)
        for index in 0..<16 {
            #expect(
                await fixture.bridge.handle(
                    fixture.request(0, "send", destination: 1, text: "m\(index)")
                ).error == nil)
        }
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
        let refused = await fixture.bridge.handle(
            fixture.request(0, "send", destination: 1, text: "overflow"))
        #expect(refused.error == "The destination inbox is full.")
        #expect(
            fixture.bridge.linkState(of: edge, in: fixture.board)
                == .failed("The destination inbox is full."))
        // Draining makes room, and the next accepted message clears the failure.
        #expect(await fixture.bridge.handle(fixture.request(1, "receive")).messages.count == 1)
        #expect(
            await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "ok"))
                .error == nil)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
        // Pausing and resuming also clear a recorded refusal.
        _ = await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "full"))
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board).kind == .failed)
        fixture.bridge.pause(fixture.edge, in: fixture.board)
        fixture.bridge.resume(fixture.edge, in: fixture.board)
        #expect(fixture.bridge.linkState(of: edge, in: fixture.board) == .live)
    }

    @Test("An accepted message publishes its connection and direction, never its body")
    func acceptedMessageEvent() async throws {
        let fixture = try CanvasLiveBridgeFixture()
        await fixture.registerPair()
        #expect(fixture.bridge.lastMessageEvent == nil)
        #expect(
            fixture.bridge.activity(of: fixture.edge, in: fixture.board).count == 0)
        #expect(
            await fixture.bridge.handle(
                fixture.request(0, "send", destination: 1, text: "forward")
            ).error == nil)
        var event = try #require(fixture.bridge.lastMessageEvent)
        #expect(event.connectionID == fixture.edge)
        #expect(event.direction == .forward)
        #expect(
            await fixture.bridge.handle(fixture.request(1, "send", destination: 0, text: "back"))
                .error == nil)
        event = try #require(fixture.bridge.lastMessageEvent)
        #expect(event.direction == .reverse)
        let activity = fixture.bridge.activity(of: fixture.edge, in: fixture.board)
        #expect(activity.count == 2)
        #expect(activity.serial == 2)
        // A refused send is not an event.
        fixture.bridge.pause(fixture.edge, in: fixture.board)
        _ = await fixture.bridge.handle(fixture.request(0, "send", destination: 1, text: "held"))
        #expect(fixture.bridge.activity(of: fixture.edge, in: fixture.board).count == 2)
    }
}
