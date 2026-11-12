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

    /// A scripted terminal screen for the watch: what it reads and answers.
    @MainActor
    final class Screen {
        var rows: [String]?
        /// Rows shown once a Return arrives.
        var rowsAfterReturn: [String]? = ["Welcome to Claude Code", "> "]
        private(set) var reads = 0
        private(set) var returns = 0
        private(set) var sleeps = 0

        var io: CanvasChannelPromptConfirmer.TerminalIO {
            .init(
                read: {
                    self.reads += 1
                    return self.rows
                },
                sendReturn: {
                    self.returns += 1
                    if let after = self.rowsAfterReturn { self.rows = after }
                    return true
                })
        }

        func slept() { sleeps += 1 }
    }

    static let dialog = [
        "WARNING: Loading development channels", "",
        "--dangerously-load-development-channels is for local channel development only.",
        "", "Channels: server:rafu", "",
        "❯ 1. I am using this for local development", "  2. Exit", "",
        "Enter to confirm · Esc to cancel",
    ]

    @MainActor
    private struct Fixture {
        let screen = Screen()
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
            // Each pass sleeps one real millisecond, so a test sees the watch react.
            let screen = self.screen
            let confirmer = CanvasChannelPromptConfirmer(
                now: { 0 },
                sleep: { _ in
                    screen.slept()
                    try? await Task.sleep(for: .milliseconds(1))
                })
            let bridge = CanvasLiveBridge(
                location: { $0 == id ? (session, board, card) : nil }, now: { clock.date },
                channelPrompt: confirmer, terminalIO: { _ in screen.io })
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

    /// Bounded: yields until `condition` holds.
    private func until(
        _ label: String, _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(label)")
        throw CancellationError()
    }

    @Test(arguments: [CanvasAgentControlMode.off, .ask])
    func aLaunchInAnOffOrAskBoardWaitsButNeverReadsTheTerminal(
        mode: CanvasAgentControlMode
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(mode)
        fixture.screen.rows = Self.dialog
        #expect(await fixture.launch().error == nil)
        // The watch runs, since the user may switch to Allow, and looks several
        // times without reading a row or pressing a key.
        #expect(fixture.confirmer.isWatching(fixture.controller.id))
        try await until("three passes") { fixture.screen.sleeps >= 3 }
        #expect(fixture.screen.reads == 0)
        #expect(fixture.screen.returns == 0)
        #expect(fixture.board.notice == nil)
    }

    @Test func aLaunchInAnAllowBoardConfirmsTheDialogThroughTheBridge() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.allow)
        fixture.screen.rows = Self.dialog
        #expect(await fixture.launch().error == nil)
        try await until("the watch to end") { !fixture.confirmer.isWatching(fixture.controller.id) }
        #expect(fixture.screen.returns == 1)
        #expect(fixture.board.notice?.message == CanvasChannelPrompt.confirmedNotice)
    }

    @Test func switchingTheBoardToAllowAfterTheLaunchConfirmsTheDialog() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.ask)
        fixture.screen.rows = Self.dialog
        #expect(await fixture.launch().error == nil)
        try await until("two passes") { fixture.screen.sleeps >= 2 }
        #expect(fixture.screen.returns == 0)
        // The user flips the Agent control while the dialog waits.
        fixture.board.setAgentControlMode(.allow)
        try await until("the watch to end") { !fixture.confirmer.isWatching(fixture.controller.id) }
        #expect(fixture.screen.returns == 1)
        #expect(fixture.board.notice?.message == CanvasChannelPrompt.confirmedNotice)
    }

    @Test func aDialogAnsweredByHandInAskModeGetsNoReturn() async throws {
        let fixture = try Fixture()
        defer { fixture.confirmer.cancel(controllerID: fixture.controller.id) }
        fixture.board.setAgentControlMode(.ask)
        fixture.screen.rows = Self.dialog
        #expect(await fixture.launch().error == nil)
        try await until("two passes") { fixture.screen.sleeps >= 2 }
        // The user answers; the board then goes to Allow. Nothing is on screen.
        fixture.screen.rows = ["Welcome to Claude Code", "> "]
        fixture.board.setAgentControlMode(.allow)
        try await until("a read") { fixture.screen.reads >= 1 }
        #expect(fixture.screen.returns == 0)
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

/// Rafu voice starts Claude with `terminal_create`, which creates an ordinary
/// terminal card on the board and types `claude` into its shell. The `claude`
/// wrapper then announces its launch with the terminal's private token, like a
/// Claude the user starts by hand, so the board's Agent control decides
/// (ADR 0026, amendment 2026-11-12). Voice has no allow/ask setting of its own.
@Suite("Channel prompt for Voice-started Claude")
@MainActor
struct CanvasChannelPromptVoiceTests {
    private struct Started {
        let controller: WorkspaceTerminalController
        let card: CanvasCard
    }

    /// Runs Voice's `terminal_create` for Claude and returns the new terminal.
    private func voiceStartsClaude(_ fixture: ComposeFixture) async throws -> Started {
        // Starting a terminal needs the Ensemble shown (a card starts its shell
        // through its view).
        fixture.workspace.installCanvasResources(for: fixture.board)
        fixture.workspace.canvasResources[fixture.board.id]?.present(owner: UUID())
        let outcome = await CanvasTerminalStarter.$confirmSteps.withValue(1) {
            await VoiceToolExecutor.run(
                name: "terminal_create",
                argumentsJSON: #"{"agent":"Claude Code","title":"Voice Claude"}"#,
                host: fixture.host)
        }
        #expect(!outcome.isError, Comment(rawValue: outcome.output))
        let card = try #require(fixture.board.cards.first { $0.title == "Voice Claude" })
        guard case .terminal(let groupID) = card.content else {
            Issue.record("Voice created a card that is not a terminal")
            throw CancellationError()
        }
        // Voice's card is a stopped terminal until its view starts the shell. The
        // test binds the lazy controller to the same pane the view would bind it to.
        let pane = try #require(fixture.workspace.terminal.terminalGroup(groupID)?.panes.first)
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let controller = try fixture.workspace.terminal.startPane(
            pane.id,
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        return Started(controller: controller, card: card)
    }

    private func bridge(
        for started: Started, fixture: ComposeFixture,
        screen: CanvasChannelPromptLaunchTests.Screen,
        confirmer: CanvasChannelPromptConfirmer, token: String
    ) -> CanvasLiveBridge {
        let id = started.controller.id
        let workspace = fixture.workspace
        let board = fixture.board
        let card = started.card
        let bridge = CanvasLiveBridge(
            location: { $0 == id ? (workspace, board, card) : nil },
            channelPrompt: confirmer, terminalIO: { _ in screen.io })
        bridge.install(controller: started.controller, token: token)
        return bridge
    }

    private func confirmer(_ screen: CanvasChannelPromptLaunchTests.Screen)
        -> CanvasChannelPromptConfirmer
    {
        CanvasChannelPromptConfirmer(
            now: { 0 },
            sleep: { _ in
                screen.slept()
                try? await Task.sleep(for: .milliseconds(1))
            })
    }

    private func until(_ label: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(label)")
        throw CancellationError()
    }

    @Test func aVoiceStartedClaudeInAnAllowBoardIsConfirmed() async throws {
        let fixture = try await ComposeFixture(mode: .allow)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let started = try await voiceStartsClaude(fixture)
        let screen = CanvasChannelPromptLaunchTests.Screen()
        screen.rows = CanvasChannelPromptLaunchTests.dialog
        let confirmer = confirmer(screen)
        defer { confirmer.cancel(controllerID: started.controller.id) }
        let bridge = bridge(
            for: started, fixture: fixture, screen: screen, confirmer: confirmer,
            token: "voice-private-capability")
        let response = await bridge.handle(
            CanvasBridgeRequest(
                token: "voice-private-capability", operation: CanvasChannelPrompt.launchOperation,
                provider: "claude"))
        #expect(response.error == nil)
        try await until("the watch to end") { !confirmer.isWatching(started.controller.id) }
        #expect(screen.returns == 1)
        #expect(fixture.board.notice?.message == CanvasChannelPrompt.confirmedNotice)
    }

    @Test func aVoiceStartedClaudeInAnAskBoardWaitsForTheUser() async throws {
        let fixture = try await ComposeFixture(mode: .ask)
        defer { TestDefaultsSuite.remove(fixture.suite) }
        let started = try await voiceStartsClaude(fixture)
        let screen = CanvasChannelPromptLaunchTests.Screen()
        screen.rows = CanvasChannelPromptLaunchTests.dialog
        let confirmer = confirmer(screen)
        defer { confirmer.cancel(controllerID: started.controller.id) }
        let bridge = bridge(
            for: started, fixture: fixture, screen: screen, confirmer: confirmer,
            token: "voice-private-capability")
        let response = await bridge.handle(
            CanvasBridgeRequest(
                token: "voice-private-capability", operation: CanvasChannelPrompt.launchOperation,
                provider: "claude"))
        #expect(response.error == nil)
        try await until("three passes") { screen.sleeps >= 3 }
        #expect(screen.reads == 0)
        #expect(screen.returns == 0)
    }
}
