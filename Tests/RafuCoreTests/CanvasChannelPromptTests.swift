import Foundation
import Testing

@testable import RafuCore

/// The matcher, the gates, the watch, and the launch announcement for Claude
/// Code's "Loading development channels" dialog (ADR 0026).
struct CanvasChannelPromptTests {
    // MARK: Fixtures

    private static let intro = [
        "WARNING: Loading development channels",
        "",
        "--dangerously-load-development-channels is for local channel development only. Do not use this option to run channels you have downloaded off the internet.",
        "",
        "Please use --channels to run a list of approved channels.",
        "",
    ]

    private static func dialog(
        channels: [String] = ["Channels: server:rafu"],
        options: [String] = ["❯ 1. I am using this for local development", "  2. Exit"],
        hint: String? = "Enter to confirm · Esc to cancel",
        width: Int? = nil
    ) -> [String] {
        var rows = intro.flatMap { wrap($0, width: width) }
        rows += channels + [""] + options + [""]
        if let hint { rows.append(hint) }
        return rows
    }

    /// Word wrap, as Claude's own layout does.
    private static func wrap(_ text: String, width: Int?) -> [String] {
        guard let width, text.count > width else { return [text] }
        var rows: [String] = []
        var row = ""
        for word in text.split(separator: " ") {
            if row.isEmpty {
                row = String(word)
            } else if row.count + 1 + word.count <= width {
                row += " " + word
            } else {
                rows.append(row)
                row = String(word)
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// Character wrap, as the terminal itself does for a row that is too long.
    private static func hardWrap(_ rows: [String], width: Int) -> [String] {
        rows.flatMap { row -> [String] in
            guard row.count > width else { return [row] }
            return stride(from: 0, to: row.count, by: width).map {
                String(row.dropFirst($0).prefix(width))
            }
        }
    }

    // MARK: Matcher, positive

    @Test func exactDialogMatches() {
        #expect(CanvasChannelPrompt.matches(Self.dialog()))
    }

    @Test func spacingVariantsMatch() {
        var rows = Self.dialog().map { "  " + $0 + "   " }
        #expect(CanvasChannelPrompt.matches(rows))
        rows = Self.dialog(
            channels: ["Channels:   server:rafu"],
            options: ["❯  1.  I am using this for local development", "   2.  Exit"])
        #expect(CanvasChannelPrompt.matches(rows))
        // Screen rows above the dialog do not matter.
        #expect(CanvasChannelPrompt.matches(["$ claude", ""] + Self.dialog()))
    }

    @Test(arguments: [60, 80, 120])
    func wrappedDialogMatches(width: Int) {
        #expect(CanvasChannelPrompt.matches(Self.dialog(width: width)))
        #expect(CanvasChannelPrompt.matches(Self.hardWrap(Self.dialog(), width: width)))
    }

    // MARK: Matcher, negative

    @Test func anotherChannelDoesNotMatch() {
        #expect(!CanvasChannelPrompt.matches(Self.dialog(channels: ["Channels: server:evil"])))
        #expect(!CanvasChannelPrompt.matches(Self.dialog(channels: ["Channels: server:rafu2"])))
        #expect(!CanvasChannelPrompt.matches(Self.dialog(channels: ["Channels: Server:rafu"])))
    }

    @Test func extraEntriesDoNotMatch() {
        for channels in [
            ["Channels: server:rafu, server:evil"],
            ["Channels: server:rafu server:evil"],
            ["Channels: server:rafu", "          server:evil"],
            ["Channels: server:evil, server:rafu"],
            ["Channels: server:rafu, plugin:chat@market"],
            ["Channels: server:rafu server:rafu"],
        ] {
            #expect(!CanvasChannelPrompt.matches(Self.dialog(channels: channels)))
        }
    }

    @Test func pluginChannelDoesNotMatch() {
        #expect(
            !CanvasChannelPrompt.matches(
                Self.dialog(channels: ["Channels: plugin:chat@marketplace"])))
    }

    @Test func missingOrEmptyChannelsLineDoesNotMatch() {
        #expect(!CanvasChannelPrompt.matches(Self.dialog(channels: [])))
        #expect(!CanvasChannelPrompt.matches(Self.dialog(channels: ["Channels:"])))
        #expect(
            !CanvasChannelPrompt.matches(
                Self.dialog(channels: ["Channels: server:rafu", "Channels: server:rafu"])))
    }

    @Test func secondOptionSelectedDoesNotMatch() {
        #expect(
            !CanvasChannelPrompt.matches(
                Self.dialog(options: [
                    "  1. I am using this for local development", "❯ 2. Exit",
                ])))
        #expect(
            !CanvasChannelPrompt.matches(
                Self.dialog(options: ["  1. I am using this for local development", "  2. Exit"])))
        #expect(!CanvasChannelPrompt.matches(Self.dialog(options: ["❯ 1. Exit"])))
    }

    @Test func missingConfirmHintDoesNotMatch() {
        #expect(!CanvasChannelPrompt.matches(Self.dialog(hint: nil)))
        #expect(!CanvasChannelPrompt.matches(Self.dialog(hint: "Esc to cancel")))
    }

    @Test func missingTitleOrFlagDoesNotMatch() {
        var rows = Self.dialog()
        rows[0] = "Loading channels"
        #expect(!CanvasChannelPrompt.matches(rows))
        rows = Self.dialog()
        rows[2] = "This option is for local channel development only."
        #expect(!CanvasChannelPrompt.matches(rows))
    }

    @Test func otherDialogsDoNotMatch() {
        let folderTrust = [
            "Do you trust the files in this folder?", "",
            " /Users/example/project", "",
            "❯ 1. Yes, proceed", "  2. No, exit", "",
            "Enter to confirm · Esc to cancel",
        ]
        let mcpConsent = [
            "New MCP server found in .mcp.json: rafu", "",
            "❯ 1. Use this and all future MCP servers in this project",
            "  2. Use this MCP server",
            "  3. Continue without using this MCP server", "",
            "Enter to confirm · Esc to cancel",
        ]
        let toolPermission = [
            "Bash command", "", "  rm -rf build", "",
            "Do you want to proceed?",
            "❯ 1. Yes", "  2. Yes, and don't ask again for rm commands", "  3. No", "",
            "Esc to cancel",
        ]
        for rows in [folderTrust, mcpConsent, toolPermission] {
            #expect(!CanvasChannelPrompt.matches(rows))
        }
    }

    @Test func dialogFollowedByAnotherPromptDoesNotMatch() {
        // An agent prints the dialog text, then asks for a tool permission: the
        // dialog is no longer the last thing on the screen.
        let toolPermission = [
            "Bash command", "", "  rm -rf build", "",
            "Do you want to proceed?",
            "❯ 1. Yes", "  2. Yes, and don't ask again for rm commands", "  3. No", "",
            "Esc to cancel",
        ]
        #expect(!CanvasChannelPrompt.matches(Self.dialog() + toolPermission))
        #expect(!CanvasChannelPrompt.matches(Self.dialog() + ["", "Done.", ""]))
        // Blank rows after the dialog are fine; they are not content.
        #expect(CanvasChannelPrompt.matches(Self.dialog() + ["", "   ", ""]))
    }

    @Test func quotedWarningTextDoesNotMatch() {
        // Ordinary output that quotes the warning text in a code block.
        let quoted =
            ["Claude printed this dialog:", "", "```text"] + Self.dialog() + ["```", "$ "]
        #expect(!CanvasChannelPrompt.matches(quoted))
        // The same text quoted without a fence: the rows no longer start the way
        // the dialog's rows do.
        let prefixed = Self.dialog().map { "> " + $0 }
        #expect(!CanvasChannelPrompt.matches(prefixed))
        let echoed = ["$ echo 'Channels: server:rafu'", "Channels: server:rafu"]
        #expect(!CanvasChannelPrompt.matches(echoed))
        #expect(!CanvasChannelPrompt.matches([]))
    }

    // MARK: Gates

    @Test func gatingTable() {
        let modes = CanvasAgentControlMode.allCases
        for mode in modes {
            for settingOn in [false, true] {
                for launched in [false, true] {
                    let expected = mode == .allow && settingOn && launched
                    #expect(
                        CanvasChannelPrompt.mayConfirm(
                            mode: mode, settingOn: settingOn, launchedByRafu: launched)
                            == expected,
                        "\(mode) setting=\(settingOn) launched=\(launched)")
                }
            }
        }
        #expect(CanvasChannelPrompt.mayConfirm(mode: .allow, settingOn: true, launchedByRafu: true))
        #expect(!CanvasChannelPrompt.mayConfirm(mode: .ask, settingOn: true, launchedByRafu: true))
        #expect(!CanvasChannelPrompt.mayConfirm(mode: .off, settingOn: true, launchedByRafu: true))
    }

    // MARK: Watch

    private let sample = Self.dialog()

    @Test func watchSendsOneReturnThenConfirmsWhenTheDialogIsGone() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: ["$ claude"], eligible: true) == .wait)
        #expect(watch.advance(now: 2, lines: sample, eligible: true) == .sendReturn)
        #expect(watch.hasSentReturn)
        // Still visible inside the grace time: wait, never a second Return.
        #expect(watch.advance(now: 2.25, lines: sample, eligible: true) == .wait)
        #expect(watch.advance(now: 2.5, lines: ["Welcome"], eligible: true) == .confirmed)
        #expect(watch.isFinished)
        #expect(watch.advance(now: 3, lines: sample, eligible: true) == .stop)
    }

    @Test func watchDoesNotSendAgainWhenTheDialogShowsAgain() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: true) == .sendReturn)
        #expect(watch.advance(now: 1.5, lines: ["Welcome"], eligible: true) == .confirmed)
        for time in stride(from: 2.0, through: 40.0, by: 0.25) {
            #expect(watch.advance(now: time, lines: sample, eligible: true) == .stop)
        }
    }

    @Test func watchGivesUpAfterTheGraceTime() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: true) == .sendReturn)
        #expect(watch.advance(now: 2.75, lines: sample, eligible: true) == .wait)
        #expect(watch.advance(now: 3, lines: sample, eligible: true) == .couldNotConfirm)
        #expect(watch.advance(now: 3.25, lines: sample, eligible: true) == .stop)
    }

    @Test func watchEndsWhenTheWindowEnds() {
        var watch = CanvasChannelPromptWatch(startedAt: 10)
        #expect(watch.advance(now: 39.75, lines: ["$ claude"], eligible: true) == .wait)
        #expect(watch.advance(now: 40, lines: sample, eligible: true) == .stop)
        #expect(watch.isFinished)
        #expect(!watch.hasSentReturn)
    }

    @Test func watchEndsWithoutReadingWhenAGateFails() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: false) == .stop)
        #expect(!watch.hasSentReturn)
        // A closed gate also stops a watch that has not sent its Return.
        var later = CanvasChannelPromptWatch(startedAt: 0)
        #expect(later.advance(now: 1, lines: ["$ claude"], eligible: true) == .wait)
        #expect(later.advance(now: 2, lines: sample, eligible: false) == .stop)
    }

    @Test func gateChangeAfterTheReturnDoesNotCancelTheResult() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: true) == .sendReturn)
        #expect(watch.advance(now: 1.25, lines: ["Welcome"], eligible: false) == .confirmed)
    }

    @Test func watchWithoutAViewWaitsThenEnds() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: nil, eligible: true) == .wait)
        #expect(watch.advance(now: 30, lines: nil, eligible: true) == .stop)
        var sent = CanvasChannelPromptWatch(startedAt: 0)
        #expect(sent.advance(now: 1, lines: sample, eligible: true) == .sendReturn)
        #expect(sent.advance(now: 1.25, lines: nil, eligible: true) == .wait)
        #expect(sent.advance(now: 3, lines: nil, eligible: true) == .stop)
    }

    @Test func refusedReturnIsOneAttempt() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: true) == .sendReturn)
        #expect(watch.returnFailed() == .couldNotConfirm)
        #expect(watch.advance(now: 1.25, lines: sample, eligible: true) == .stop)
    }

    @Test func samplingStaysAtOrBelowFourPerSecond() {
        #expect(CanvasChannelPromptWatch.sampleInterval >= 0.25)
        #expect(CanvasChannelPromptWatch.window <= 30)
    }

    // MARK: Launch announcement

    private let environment = [
        "RAFU_CANVAS_TOKEN": "private-capability", "RAFU_CANVAS_SOCKET": "/tmp/rafu.sock",
    ]

    @Test func claudeLaunchWithTheRafuFlagIsAnnounced() throws {
        for arguments in [[], ["--resume"], ["Fix the failing test"]] {
            let request = try #require(
                CanvasChannelPrompt.launchRequest(
                    provider: "claude", arguments: arguments, environment: environment))
            #expect(request.operation == CanvasChannelPrompt.launchOperation)
            #expect(request.token == "private-capability")
            #expect(request.provider == "claude")
            #expect(request.text == nil)
        }
    }

    @Test func launchesWithoutTheRafuFlagAreNotAnnounced() {
        // Codex, non-interactive Claude, Claude subcommands, and a missing token.
        #expect(
            CanvasChannelPrompt.launchRequest(
                provider: "codex", arguments: [], environment: environment) == nil)
        for arguments in [["--print", "hi"], ["mcp", "list"], ["--version"], ["--help"]] {
            #expect(
                CanvasChannelPrompt.launchRequest(
                    provider: "claude", arguments: arguments, environment: environment) == nil)
        }
        #expect(
            CanvasChannelPrompt.launchRequest(
                provider: "claude", arguments: [], environment: [:]) == nil)
        #expect(
            CanvasChannelPrompt.launchRequest(
                provider: "claude", arguments: [], environment: ["RAFU_CANVAS_TOKEN": ""]) == nil)
    }
}
