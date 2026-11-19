import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
private final class AgentRequestClock {
    var date = Date(timeIntervalSince1970: 1_000)
}

/// One terminal node with a bound Codex route, for the agent request operations.
@MainActor
private struct AgentRequestBridgeFixture {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let controller: WorkspaceTerminalController
    let store: AgentRequestStore
    let clock = AgentRequestClock()
    let bridge: CanvasLiveBridge
    let token = "agent-request-private-capability"
    let route = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
    let thread = UUID().uuidString

    init() throws {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.agent-request-bridge-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker())
        let board = CanvasBoardState(document: CanvasDocument(title: "Request test"))
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let group = try session.terminal.createLiveGroup(
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        let id = try #require(group.panes.first?.sessionID)
        let controller = try #require(session.terminal.sessions.first { $0.id == id })
        try board.add(title: "Terminal", content: .terminal(groupID: group.id))
        let card = try #require(board.cards.first)
        let store = AgentRequestStore()
        let clock = clock
        bridge = CanvasLiveBridge(
            location: { controllerID in
                controllerID == controller.id ? (session, board, card) : nil
            }, now: { clock.date },
            beginActivity: { _, _ in NSObject() }, endActivity: { _ in },
            expectsAgent: { _ in false }, sendToCodex: { _, _, _, _ in },
            agentRequests: store)
        self.store = store
        self.session = session
        self.board = board
        self.controller = controller
        bridge.install(controller: controller, token: token)
    }

    func supervisor(_ operation: String) -> CanvasBridgeRequest {
        CanvasBridgeRequest(
            token: token, operation: operation, provider: "codex", threadID: thread,
            endpoint: route)
    }

    func bind() async {
        var bind = supervisor("bind")
        bind.executable = "/local/bin/codex"
        #expect(await bridge.handle(bind).error == nil)
    }

    func open(_ request: CanvasAgentRequest) async -> CanvasBridgeResponse {
        var open = supervisor(CanvasAgentRequest.openOperation)
        open.approval = request
        return await bridge.handle(open)
    }

    func poll() async -> CanvasBridgeResponse {
        await bridge.handle(supervisor(CanvasAgentRequest.pollOperation))
    }

    func close(_ key: UUID) async -> CanvasBridgeResponse {
        var close = supervisor(CanvasAgentRequest.closeOperation)
        close.approvalKey = key
        return await bridge.handle(close)
    }
}

private func command() -> CanvasAgentRequest {
    CanvasAgentRequest(kind: .command, command: "python3 fix.py", cwd: "/repo")
}

@Suite("Agent request bridge operations")
@MainActor
struct CanvasLiveBridgeRequestTests {
    @Test("Open, choose, poll and close one request")
    func fullCycle() async throws {
        let fixture = try AgentRequestBridgeFixture()
        await fixture.bind()
        let request = command()
        #expect(await fixture.open(request).error == nil)
        #expect(fixture.store.current(for: fixture.controller.id) == request)
        let empty = await fixture.poll()
        #expect(empty.error == nil)
        #expect(empty.approvalDecision == nil)
        #expect(
            fixture.store.choose(
                controllerID: fixture.controller.id, key: request.key, decision: .accept)
                == .chosen)
        let polled = await fixture.poll()
        #expect(
            polled.approvalDecision == CanvasAgentRequestAnswer(key: request.key, decision: .accept)
        )
        #expect(await fixture.close(request.key).error == nil)
        #expect(fixture.store.current(for: fixture.controller.id) == nil)
        #expect(await fixture.poll().approvalDecision == nil)
    }

    @Test("A stale or unknown close is ignored")
    func staleClose() async throws {
        let fixture = try AgentRequestBridgeFixture()
        await fixture.bind()
        let request = command()
        _ = await fixture.open(request)
        #expect(await fixture.close(UUID()).error == nil)
        #expect(fixture.store.current(for: fixture.controller.id) == request)
        #expect(await fixture.close(request.key).error == nil)
        #expect(await fixture.close(request.key).error == nil)
        var bare = fixture.supervisor(CanvasAgentRequest.closeOperation)
        bare.approvalKey = nil
        #expect(await fixture.bridge.handle(bare).error == nil)
    }

    @Test("Only the bound Codex route of the terminal may use the operations")
    func routeChecks() async throws {
        let fixture = try AgentRequestBridgeFixture()
        // Not bound yet.
        #expect(await fixture.open(command()).error != nil)
        await fixture.bind()
        for operation in CanvasAgentRequest.operations {
            var wrongRoute = fixture.supervisor(operation)
            wrongRoute.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
            wrongRoute.approval = command()
            #expect(await fixture.bridge.handle(wrongRoute).error != nil)
            var wrongThread = fixture.supervisor(operation)
            wrongThread.threadID = UUID().uuidString
            wrongThread.approval = command()
            #expect(await fixture.bridge.handle(wrongThread).error != nil)
            var claude = fixture.supervisor(operation)
            claude.provider = "claude"
            claude.approval = command()
            #expect(await fixture.bridge.handle(claude).error != nil)
            var noRoute = fixture.supervisor(operation)
            noRoute.endpoint = nil
            noRoute.approval = command()
            #expect(await fixture.bridge.handle(noRoute).error != nil)
            var wrongToken = fixture.supervisor(operation)
            wrongToken.token = "not-a-capability"
            wrongToken.approval = command()
            #expect(await fixture.bridge.handle(wrongToken).error != nil)
        }
        #expect(fixture.store.current(for: fixture.controller.id) == nil)
        #expect(
            await fixture.bridge.handle(fixture.supervisor(CanvasAgentRequest.openOperation)).error
                != nil)
    }

    @Test("A terminal takes at most eight requests over the bridge")
    func bound() async throws {
        let fixture = try AgentRequestBridgeFixture()
        await fixture.bind()
        for _ in 0..<AgentRequestStore.perTerminalLimit {
            #expect(await fixture.open(command()).error == nil)
        }
        #expect(await fixture.open(command()).error != nil)
        // A retried open of a request that is already there is not an error.
        let first = try #require(fixture.store.current(for: fixture.controller.id))
        #expect(await fixture.open(first).error == nil)
    }

    @Test("Suspend refuses the operations and clears waiting requests")
    func suspend() async throws {
        let fixture = try AgentRequestBridgeFixture()
        await fixture.bind()
        let request = command()
        _ = await fixture.open(request)
        _ = fixture.store.choose(
            controllerID: fixture.controller.id, key: request.key, decision: .accept)
        var suspend = fixture.supervisor("suspend")
        suspend.reason = "transportLost"
        #expect(await fixture.bridge.handle(suspend).error == nil)
        #expect(fixture.store.current(for: fixture.controller.id) == nil)
        #expect(await fixture.open(command()).error != nil)
        let polled = await fixture.poll()
        #expect(polled.error != nil)
        #expect(polled.approvalDecision == nil)
    }

    @Test("Release, a new route and terminal removal clear waiting requests")
    func clearing() async throws {
        let fixture = try AgentRequestBridgeFixture()
        await fixture.bind()
        _ = await fixture.open(command())
        #expect(await fixture.bridge.handle(fixture.supervisor("release")).error == nil)
        #expect(fixture.store.current(for: fixture.controller.id) == nil)

        await fixture.bind()
        _ = await fixture.open(command())
        fixture.bridge.remove(fixture.controller)
        #expect(fixture.store.current(for: fixture.controller.id) == nil)

        fixture.bridge.install(controller: fixture.controller, token: fixture.token)
        await fixture.bind()
        _ = await fixture.open(command())
        // A new supervisor run replaces the stale route and its requests.
        fixture.clock.date += 60
        var rebind = fixture.supervisor("bind")
        rebind.endpoint = "unix:///tmp/rafu-cdx-\(UUID().uuidString)/socket"
        rebind.executable = "/local/bin/codex"
        #expect(await fixture.bridge.handle(rebind).error == nil)
        #expect(fixture.store.current(for: fixture.controller.id) == nil)
    }
}
