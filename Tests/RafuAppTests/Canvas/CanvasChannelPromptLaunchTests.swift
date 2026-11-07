import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// The launch announcement is the only thing that starts a channel-prompt watch
/// (ADR 0026): who may send it, and which boards and terminals it starts.
@Suite("Channel prompt launch record")
@MainActor
struct CanvasChannelPromptLaunchTests {
    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    @MainActor
    private struct Fixture {
        let clock = Clock()
        let session: WorkspaceSession
        let board: CanvasBoardState
        let controller: WorkspaceTerminalController
        let confirmer: CanvasChannelPromptConfirmer
        let bridge: CanvasLiveBridge
        let token = "channel-prompt-private-capability"

        init() throws {
            let clock = self.clock
            let session = WorkspaceSession(
                restorationStore: WorkspaceRestorationStore(
                    defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.channel-prompt-tests"),
                    bookmarkMaker: { _ in throw CancellationError() }),
                closeSaveTracker: WorkspaceCloseSaveTracker())
            let board = CanvasBoardState(document: CanvasDocument(title: "Channel prompt"))
            let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
            let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
            let group = try session.terminal.createLiveGroup(
                instantiation: .ordinaryShell(
                    startingDirectory: "/tmp", shell: shell, profile: profile))
            let id = try #require(group.panes.first?.sessionID)
            let controller = try #require(session.terminal.sessions.first { $0.id == id })
            try board.add(title: "Terminal", content: .terminal(groupID: group.id))
            let card = try #require(board.cards.first)
            // The scripted clock never advances, so a started watch stays pending.
            let confirmer = CanvasChannelPromptConfirmer(
                now: { 0 },
                sleep: { _ in
                    try? await Task.sleep(for: .seconds(3600))
                })
            let bridge = CanvasLiveBridge(
                location: { $0 == id ? (session, board, card) : nil }, now: { clock.date },
                channelPrompt: confirmer)
            bridge.install(controller: controller, token: token)
            self.session = session
            self.board = board
            self.controller = controller
            self.confirmer = confirmer
            self.bridge = bridge
        }

        func launch(
            provider: String = "claude", token: String? = nil
        ) async -> CanvasBridgeResponse {
            await bridge.handle(
                CanvasBridgeRequest(
                    token: token ?? self.token, operation: CanvasChannelPrompt.launchOperation,
                    provider: provider))
        }
    }

    @Test func aClaudeLaunchInAnAllowBoardStartsOneWatch() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        #expect(await fixture.launch().error == nil)
        #expect(fixture.confirmer.isWatching(fixture.controller.id))
        fixture.bridge.remove(fixture.controller)
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
    }

    @Test(arguments: [CanvasAgentControlMode.off, .ask])
    func aLaunchInAnOffOrAskBoardStartsNothing(mode: CanvasAgentControlMode) async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(mode)
        #expect(await fixture.launch().error == nil)
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
    }

    @Test func aLaunchWhileAFreshClaudeClientIsRegisteredStartsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        let client = UUID().uuidString
        let registration = CanvasBridgeRequest(
            token: fixture.token, operation: "register", clientID: client, provider: "claude")
        #expect(await fixture.bridge.handle(registration).error == nil)
        // An agent that reads the token cannot open a watch for its own Claude.
        #expect(await fixture.launch().error != nil)
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
        // A repeated attempt changes nothing.
        #expect(await fixture.launch().error != nil)
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
    }

    @Test func aLaunchAfterTheRegisteredClientWentStaleStartsAWatch() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        let registration = CanvasBridgeRequest(
            token: fixture.token, operation: "register", clientID: UUID().uuidString,
            provider: "claude")
        #expect(await fixture.bridge.handle(registration).error == nil)
        // Fresh for 15 s, the same rule as `register`.
        fixture.clock.date.addTimeInterval(14)
        #expect(await fixture.launch().error != nil)
        fixture.clock.date.addTimeInterval(2)
        #expect(await fixture.launch().error == nil)
        #expect(fixture.confirmer.isWatching(fixture.controller.id))
    }

    @Test func aCodexLaunchStartsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        _ = await fixture.launch(provider: "codex")
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
    }

    @Test func anUnknownTokenStartsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        #expect(await fixture.launch(token: "another-terminal").error != nil)
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
    }

    @Test func aTerminalNobodyLaunchedIsNotWatched() throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        #expect(!fixture.confirmer.isWatching(fixture.controller.id))
    }
}
