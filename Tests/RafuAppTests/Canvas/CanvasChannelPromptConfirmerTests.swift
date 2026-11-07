import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Gates, one-shot behaviour, and the bounded window of the channel-prompt
/// confirmer, driven by a fake clock and a scripted terminal (ADR 0026).
@Suite("Channel prompt confirmer")
@MainActor
struct CanvasChannelPromptConfirmerTests {
    private static let dialog = [
        "WARNING: Loading development channels", "",
        "--dangerously-load-development-channels is for local channel development only.",
        "", "Channels: server:rafu", "",
        "❯ 1. I am using this for local development", "  2. Exit", "",
        "Enter to confirm · Esc to cancel",
    ]
    private static let welcome = ["Welcome to Claude Code", "> "]

    /// A scripted terminal plus the board-side state the hooks read.
    @MainActor
    private final class Terminal {
        var mode = CanvasAgentControlMode.allow
        var settingOn = true
        var rows: [String]? = ["$ claude"]
        /// Rows shown once a Return arrives; `nil` keeps the current rows.
        var rowsAfterReturn: [String]? = CanvasChannelPromptConfirmerTests.welcome
        var refusesReturn = false
        var clock: TimeInterval = 0
        private(set) var reads = 0
        private(set) var returns = 0
        private(set) var notices: [(String, CanvasBoardNotice.Tone)] = []
        let id = UUID()

        var hooks: CanvasChannelPromptConfirmer.Hooks {
            .init(
                mode: { self.mode }, settingOn: { self.settingOn },
                read: {
                    self.reads += 1
                    return self.rows
                },
                sendReturn: {
                    guard !self.refusesReturn else { return false }
                    self.returns += 1
                    if let after = self.rowsAfterReturn { self.rows = after }
                    return true
                },
                notice: { self.notices.append(($0, $1)) })
        }

        func confirmer() -> CanvasChannelPromptConfirmer {
            CanvasChannelPromptConfirmer(
                now: { self.clock },
                sleep: { duration in
                    self.clock +=
                        Double(duration.components.seconds)
                        + Double(duration.components.attoseconds) / 1e18
                    // A scripted change of the screen at a chosen time.
                    self.onTick?(self.clock)
                    await Task.yield()
                })
        }

        var onTick: ((TimeInterval) -> Void)?
    }

    @Test func confirmsOnceWhenTheDialogAppearsAndTheScreenMoves() async {
        let terminal = Terminal()
        let confirmer = terminal.confirmer()
        // The dialog appears once, at 3 s; after the Return the screen moves on.
        terminal.onTick = { time in
            if time >= 3, terminal.returns == 0 { terminal.rows = Self.dialog }
        }
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        #expect(confirmer.isWatching(terminal.id))
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 1)
        #expect(terminal.notices.count == 1)
        #expect(
            terminal.notices.first?.0
                == "Rafu confirmed the development-channel prompt for server:rafu.")
        #expect(terminal.notices.first?.1 == .info)
        #expect(!confirmer.isWatching(terminal.id))
    }

    @Test func aSecondMatchInTheSameLaunchSendsNothing() async {
        let terminal = Terminal()
        let confirmer = terminal.confirmer()
        terminal.rows = Self.dialog
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 1)
        // The dialog shows again after the watch ended: nobody is looking.
        terminal.rows = Self.dialog
        let reads = terminal.reads
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 1)
        #expect(terminal.reads == reads)
        #expect(!confirmer.isWatching(terminal.id))
    }

    @Test func aDialogThatStaysGetsOneReturnAndANotice() async {
        let terminal = Terminal()
        terminal.rows = Self.dialog
        terminal.rowsAfterReturn = nil
        let confirmer = terminal.confirmer()
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 1)
        #expect(terminal.notices.count == 1)
        #expect(
            terminal.notices.first?.0
                == "Rafu could not confirm the channel prompt; answer it in the terminal.")
        #expect(terminal.notices.first?.1 == .warn)
    }

    @Test func aRefusedReturnIsNotRetried() async {
        let terminal = Terminal()
        terminal.rows = Self.dialog
        terminal.refusesReturn = true
        let confirmer = terminal.confirmer()
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 0)
        #expect(terminal.notices.map(\.0) == [CanvasChannelPrompt.unconfirmedNotice])
    }

    @Test(arguments: [CanvasAgentControlMode.off, .ask])
    func offAndAskNeverReadOrAct(mode: CanvasAgentControlMode) async {
        let terminal = Terminal()
        terminal.mode = mode
        terminal.rows = Self.dialog
        let confirmer = terminal.confirmer()
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        #expect(!confirmer.isWatching(terminal.id))
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.reads == 0)
        #expect(terminal.returns == 0)
        #expect(terminal.notices.isEmpty)
    }

    @Test func aSwitchedOffSettingNeverReadsOrActs() async {
        let terminal = Terminal()
        terminal.settingOn = false
        terminal.rows = Self.dialog
        let confirmer = terminal.confirmer()
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        #expect(!confirmer.isWatching(terminal.id))
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.reads == 0)
        #expect(terminal.returns == 0)
    }

    @Test func aTerminalWithoutALaunchRecordNeverActs() async {
        let terminal = Terminal()
        terminal.rows = Self.dialog
        let confirmer = terminal.confirmer()
        // No `recordLaunch`: a Claude the user started by hand is not watched.
        #expect(!confirmer.isWatching(terminal.id))
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.reads == 0)
        #expect(terminal.returns == 0)
    }

    @Test func leavingAllowDuringTheWindowStopsTheWatch() async {
        let terminal = Terminal()
        let confirmer = terminal.confirmer()
        terminal.onTick = { time in
            if time >= 2 { terminal.mode = .ask }
            if time >= 3 { terminal.rows = Self.dialog }
        }
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 0)
        #expect(terminal.notices.isEmpty)
    }

    @Test func theWatchEndsWhenTheWindowEndsAndSamplesAtMostFourTimesASecond() async {
        let terminal = Terminal()
        let confirmer = terminal.confirmer()
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 0)
        #expect(terminal.notices.isEmpty)
        #expect(terminal.clock >= CanvasChannelPromptWatch.window)
        #expect(terminal.clock <= CanvasChannelPromptWatch.window + 1)
        #expect(Double(terminal.reads) <= CanvasChannelPromptWatch.window * 4 + 1)
        #expect(!confirmer.isWatching(terminal.id))
    }

    @Test func aDialogAfterTheWindowIsNotAnswered() async {
        let terminal = Terminal()
        let confirmer = terminal.confirmer()
        terminal.onTick = { time in if time >= 31 { terminal.rows = Self.dialog } }
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 0)
    }

    @Test func cancelEndsTheWatchAtOnce() async {
        let terminal = Terminal()
        let confirmer = terminal.confirmer()
        confirmer.recordLaunch(controllerID: terminal.id, hooks: terminal.hooks)
        confirmer.cancel(controllerID: terminal.id)
        #expect(!confirmer.isWatching(terminal.id))
        terminal.rows = Self.dialog
        await confirmer.finishedWatching(terminal.id)
        #expect(terminal.returns == 0)
    }

    @Test func theSettingDefaultsOn() throws {
        let name = TestDefaultsSuite.name("dev.rafu.channel-prompt-preference")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { TestDefaultsSuite.remove(name) }
        #expect(CanvasChannelPromptPreference.isOn(defaults))
        defaults.set(false, forKey: CanvasChannelPromptPreference.key)
        #expect(!CanvasChannelPromptPreference.isOn(defaults))
        defaults.set(true, forKey: CanvasChannelPromptPreference.key)
        #expect(CanvasChannelPromptPreference.isOn(defaults))
    }
}
