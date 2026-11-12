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

    @Test func footerWordingDoesNotDecideTheMatch() {
        // Claude Code builds the footer from its active key bindings, so its
        // words change between releases. The dialog must be the tail, not say
        // "Enter to confirm".
        #expect(CanvasChannelPrompt.matches(Self.dialog(hint: nil)))
        for hint in [
            "Esc to cancel", "Enter to select · Esc to cancel",
            "↑/↓ to navigate · Enter to select · Esc to cancel", "Enter to confirm",
            "Enter confirm · Esc cancel",
        ] {
            #expect(CanvasChannelPrompt.matches(Self.dialog(hint: hint)), Comment(rawValue: hint))
        }
    }

    @Test func aFooterThatIsNotAKeyHintDoesNotMatch() {
        for hint in [
            "Run the tests now", "Enter to confirm · rm -rf build", "Enter", "Esc",
            "Done. Esc to cancel", "Ctrl+C to cancel",
        ] {
            #expect(!CanvasChannelPrompt.matches(Self.dialog(hint: hint)), Comment(rawValue: hint))
        }
    }

    @Test func aMissingExitOptionDoesNotMatch() {
        #expect(
            !CanvasChannelPrompt.matches(
                Self.dialog(options: ["❯ 1. I am using this for local development"])))
        #expect(
            !CanvasChannelPrompt.matches(
                Self.dialog(options: [
                    "❯ 1. I am using this for local development", "  2. Stay",
                ])))
    }

    // MARK: Matcher, the real dialog (Claude Code 2.1.322)

    /// Laid out from Claude Code's `DevChannelsDialog` component (found in the
    /// installed 2.1.322 binary; see `docs/references/canvas-live-sessions.md`):
    /// a pane with a top rule, the bold title, a column with a blank row between
    /// the two paragraphs and the dim `Channels:` row, then the select with
    /// "I am using this for local development" first and "Exit" second, then the
    /// footer. The pane indents every row by one column.
    private static func realDialog(
        footer: String? = "Enter to confirm · Esc to cancel", width: Int = 100
    )
        -> [String]
    {
        var rows = [String(repeating: "─", count: width)]
        rows += [" WARNING: Loading development channels", ""]
        rows += wrap(
            "--dangerously-load-development-channels is for local channel development only. Do not use this option to run channels you have downloaded off the internet.",
            width: width - 2
        ).map { " " + $0 }
        rows += ["", " Please use --channels to run a list of approved channels.", ""]
        rows += [" Channels: server:rafu", ""]
        rows += [" ❯ 1. I am using this for local development", "   2. Exit", ""]
        if let footer { rows.append(" " + footer) }
        return rows
    }

    @Test(arguments: [40, 60, 80, 100, 160])
    func theRealDialogMatchesAtEveryWidth(width: Int) {
        #expect(CanvasChannelPrompt.matches(Self.realDialog(width: width)))
        #expect(CanvasChannelPrompt.matches(Self.realDialog(footer: nil, width: width)))
        #expect(CanvasChannelPrompt.matches(Self.realDialog(footer: "Esc to cancel", width: width)))
    }

    @Test func theRealDialogMatchesWithBlankRowsBelowAndTerminalRowsAbove() {
        // The viewport sample has every screen row, also the empty ones below.
        let screen = ["$ claude", ""] + Self.realDialog() + Array(repeating: "", count: 12)
        #expect(CanvasChannelPrompt.matches(screen))
    }

    @Test func theChannelsRowMayTouchTheOptions() {
        // No blank row between the `Channels:` row and the select.
        var rows = Self.realDialog()
        rows.removeAll { $0.isEmpty }
        #expect(CanvasChannelPrompt.matches(rows))
    }

    @Test func theRealDialogWithAnExtraChannelDoesNotMatch() throws {
        var rows = Self.realDialog()
        let index = try #require(rows.firstIndex { $0.contains("Channels:") })
        rows[index] = " Channels: server:rafu, plugin:chat@market"
        #expect(!CanvasChannelPrompt.matches(rows))
        rows[index] = " Channels: server:evil"
        #expect(!CanvasChannelPrompt.matches(rows))
    }

    @Test func theRealDialogFollowedByOtherOutputDoesNotMatch() {
        #expect(!CanvasChannelPrompt.matches(Self.realDialog() + ["", "Done.", ""]))
        #expect(
            !CanvasChannelPrompt.matches(
                Self.realDialog() + [
                    "Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel",
                ]))
    }

    // MARK: Folder trust (extends the window, is never answered)

    private static let folderTrust = [
        "────────────────────────────────────────",
        " Accessing workspace:", "", " /Users/example/project", "",
        " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.",
        "", " Claude Code'll be able to read, edit, and execute files here.", "",
        " Security guide", "", " ❯ 1. Yes, I trust this folder", "   2. No, exit", "",
        " Enter to confirm · Esc to cancel",
    ]

    @Test func theFolderTrustDialogIsRecognisedButNeverMatches() {
        #expect(CanvasChannelPrompt.isFolderTrust(Self.folderTrust))
        #expect(!CanvasChannelPrompt.matches(Self.folderTrust))
        #expect(!CanvasChannelPrompt.isFolderTrust(Self.realDialog()))
        #expect(!CanvasChannelPrompt.isFolderTrust([]))
        // A quotation is not the dialog.
        #expect(!CanvasChannelPrompt.isFolderTrust(["```text"] + Self.folderTrust + ["```"]))
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
        #expect(watch.advance(now: 69.75, lines: ["$ claude"], eligible: true) == .wait)
        #expect(watch.advance(now: 70, lines: sample, eligible: true) == .stop)
        #expect(watch.isFinished)
        #expect(!watch.hasSentReturn)
    }

    @Test func aClosedGateWaitsAndNeverSendsWhileItIsClosed() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: false) == .wait)
        #expect(watch.advance(now: 2, lines: nil, eligible: false) == .wait)
        #expect(!watch.hasSentReturn)
        // The same dialog, still on screen, is answered once the gate opens
        // (the user switched the board to Allow after the start).
        #expect(watch.advance(now: 30, lines: sample, eligible: true) == .sendReturn)
        // A gate that closes again before the dialog shows sends nothing.
        var later = CanvasChannelPromptWatch(startedAt: 0)
        #expect(later.advance(now: 1, lines: ["$ claude"], eligible: true) == .wait)
        #expect(later.advance(now: 2, lines: sample, eligible: false) == .wait)
        #expect(!later.hasSentReturn)
    }

    @Test func aClosedGateStillEndsWhenTheWindowEnds() {
        var watch = CanvasChannelPromptWatch(startedAt: 5)
        #expect(watch.advance(now: 64.75, lines: nil, eligible: false) == .wait)
        #expect(watch.advance(now: 65, lines: sample, eligible: true) == .stop)
        #expect(watch.isFinished)
        #expect(!watch.hasSentReturn)
    }

    @Test func theFolderTrustDialogKeepsTheWatchOpenButIsNeverAnswered() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        // Claude's own dialog first; the user takes minutes to answer it.
        for time in stride(from: 1.0, through: 200.0, by: 1.0) {
            #expect(watch.advance(now: time, lines: Self.folderTrust, eligible: true) == .wait)
        }
        #expect(!watch.hasSentReturn)
        // The channel dialog then shows up and is answered once.
        #expect(watch.advance(now: 230, lines: sample, eligible: true) == .sendReturn)
    }

    @Test func theWindowRestartsAfterTheFolderTrustDialogIsGone() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 50, lines: Self.folderTrust, eligible: true) == .wait)
        // The window now ends 60 s after the last sample that showed the dialog.
        #expect(watch.advance(now: 109.75, lines: ["$ claude"], eligible: true) == .wait)
        #expect(watch.advance(now: 110, lines: ["$ claude"], eligible: true) == .stop)
    }

    @Test func theFolderTrustExtensionHasAHardCap() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        var last = CanvasChannelPromptWatch.Action.wait
        for time in stride(from: 1.0, through: 700.0, by: 1.0) {
            last = watch.advance(now: time, lines: Self.folderTrust, eligible: true)
            if last == .stop { break }
        }
        #expect(last == .stop)
        #expect(watch.isFinished)
        #expect(!watch.hasSentReturn)
        // The window ends at the cap, however long the dialog stays.
        var capped = CanvasChannelPromptWatch(startedAt: 0)
        for time in stride(from: 30.0, through: 570.0, by: 30.0) {
            #expect(capped.advance(now: time, lines: Self.folderTrust, eligible: true) == .wait)
        }
        let cap = CanvasChannelPromptWatch.maxWindow
        #expect(capped.advance(now: cap - 1, lines: Self.folderTrust, eligible: true) == .wait)
        #expect(capped.advance(now: cap, lines: Self.folderTrust, eligible: true) == .stop)
    }

    @Test func aClosedGateDoesNotExtendTheWindowForFolderTrust() {
        // Nothing is read while a gate is closed, so the trust dialog is not seen.
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 59, lines: Self.folderTrust, eligible: false) == .wait)
        #expect(watch.advance(now: 60, lines: Self.folderTrust, eligible: false) == .stop)
    }

    @Test func gateChangeAfterTheReturnDoesNotCancelTheResult() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: sample, eligible: true) == .sendReturn)
        #expect(watch.advance(now: 1.25, lines: ["Welcome"], eligible: false) == .confirmed)
    }

    @Test func watchWithoutAViewWaitsThenEnds() {
        var watch = CanvasChannelPromptWatch(startedAt: 0)
        #expect(watch.advance(now: 1, lines: nil, eligible: true) == .wait)
        #expect(watch.advance(now: 59, lines: nil, eligible: true) == .wait)
        #expect(watch.advance(now: 60, lines: nil, eligible: true) == .stop)
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
        #expect(CanvasChannelPromptWatch.idleInterval >= CanvasChannelPromptWatch.sampleInterval)
        #expect(CanvasChannelPromptWatch.window <= 60)
        #expect(CanvasChannelPromptWatch.maxWindow <= 600)
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
