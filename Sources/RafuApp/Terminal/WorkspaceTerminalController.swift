import AppKit
import Observation
import SwiftTerm

/// A terminal session's lifecycle: `.idle` until its view is first mounted
/// (spawn is lazy, ADR 0004), `.running` while the shell is alive, `.bell`
/// while it is alive but has requested attention (BEL received while
/// unfocused — terminal-manager.md T-E; cleared back to `.running` the
/// moment its tab is focused again, `WorkspaceTerminalController
/// .clearAttention()`), and `.exited(code:)` once it has quit — either
/// naturally (SwiftTerm's `processTerminated` delegate callback, `code`
/// carries the real exit status) or via explicit `shutdown()` (`code ==
/// nil`, since no process delivered one there).
nonisolated enum TerminalSessionStatus: Equatable, Sendable {
    case idle
    case running
    case bell
    case exited(code: Int32?)
}

/// Owns the set of terminal sessions for a workspace window (ADR 0004,
/// amended by ADR 0014 and the terminal-manager phase T-A: a session may be
/// parked without an editor tab — see
/// `WorkspaceSession.parkedTerminalSessions`). Sessions are created lazily —
/// the first when the panel opens, more via the tab strip — and all are
/// terminated when the workspace switches.
@Observable
@MainActor
final class WorkspaceTerminalManager {
    private(set) var sessions: [WorkspaceTerminalController] = []
    var selectedID: UUID?

    @ObservationIgnored
    private var sessionCounter = 0
    @ObservationIgnored
    private var parkCounter = 0

    /// Invoked whenever any session's shell exits naturally (never on an
    /// explicit `close`/`shutdown`). `WorkspaceSession` wires this lazily —
    /// see `installTerminalHandlersIfNeeded()`.
    @ObservationIgnored
    var sessionDidExit: (@MainActor (UUID, Int32?) -> Void)?

    /// Invoked whenever any session receives BEL (terminal-manager.md T-E).
    /// `WorkspaceSession.terminalSessionDidBell(_:)` decides whether that
    /// actually raises attention (the session's tab may already be
    /// focused) — wired lazily alongside `sessionDidExit`, see
    /// `installTerminalHandlersIfNeeded()`.
    @ObservationIgnored
    var sessionDidBell: (@MainActor (UUID) -> Void)?

    var selected: WorkspaceTerminalController? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    var hasSessions: Bool { !sessions.isEmpty }

    @discardableResult
    func newSession(startingDirectory: String, shell: TerminalShell) -> WorkspaceTerminalController
    {
        sessionCounter += 1
        let session = WorkspaceTerminalController(
            index: sessionCounter,
            startingDirectory: startingDirectory,
            shell: shell
        )
        session.onExit = { [weak self] id, exitCode in
            self?.sessionDidExit?(id, exitCode)
        }
        session.onBell = { [weak self] id in
            self?.sessionDidBell?(id)
        }
        sessions.append(session)
        selectedID = session.id
        return session
    }

    /// Bumps this session to most-recently-parked, driving
    /// `WorkspaceSession.parkedTerminalSessions`'s MRU ordering. A no-op for
    /// an unknown id.
    func notePark(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        parkCounter += 1
        session.markParked(sequence: parkCounter)
    }

    /// Terminates one session's shell and removes it. Selection moves to the
    /// nearest remaining session.
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].shutdown()
        sessions.remove(at: index)
        if selectedID == id {
            selectedID =
                sessions.indices.contains(index)
                ? sessions[index].id
                : sessions.last?.id
        }
    }

    func shutdownAll() {
        for session in sessions {
            session.shutdown()
        }
        sessions = []
        selectedID = nil
        sessionCounter = 0
        parkCounter = 0
    }
}

/// One terminal session: a lazily spawned login shell plus its SwiftTerm
/// view. All SwiftTerm types stay behind this boundary.
@Observable
@MainActor
final class WorkspaceTerminalController: Identifiable {
    nonisolated let id = UUID()
    let index: Int
    /// Directory the shell starts in; also the tooltip fallback until the
    /// shell reports its live working directory over OSC 7.
    let startingDirectory: String
    /// The shell binary this session spawns (terminal-manager.md T-C).
    let shell: TerminalShell
    private(set) var status: TerminalSessionStatus = .idle
    /// User-set name (terminal-manager.md T-D) — always wins in
    /// `displayName`. `nil` returns display to the auto name
    /// (`reportedTitle`, then the shell/index fallback). Trimming and the
    /// empty-clears-to-auto rule live in
    /// `WorkspaceSession.renameTerminalSession(_:to:)`, the one caller.
    var userName: String?
    /// Auto title from the shell's own OSC 0/2 report (agent CLIs set this
    /// — "✳ claude", "codex", …). `nil` until the shell reports one, or
    /// after an empty/whitespace-only report clears it. Never wins over
    /// `userName`.
    private(set) var reportedTitle: String?
    /// Color TAG (terminal-manager.md T-D) — a theme palette token, never a
    /// raw color, so themes restyle it. `nil` shows no dot/stripe. Not
    /// persisted (sessions don't restore across relaunch).
    var sessionColor: TerminalSessionColor?
    /// Live working directory reported by the shell via OSC 7, when the
    /// prompt emits it (starship/powerlevel10k do; stock zsh may not).
    private(set) var currentDirectoryPath: String?
    /// MRU sequence stamped by `WorkspaceTerminalManager.notePark(_:)` when
    /// this session's tab is hidden; drives
    /// `WorkspaceSession.parkedTerminalSessions`'s ordering. `0` until
    /// parked at least once.
    private(set) var parkSequence: Int = 0

    /// `userName`, then the shell's own OSC 0/2 title report, then a
    /// generated fallback — the single source of truth for every place
    /// this session's name is shown (panel row, tab label, `.help` text).
    var displayName: String {
        userName ?? reportedTitle ?? "\(shell.basename) \(index)"
    }

    init(index: Int, startingDirectory: String, shell: TerminalShell) {
        self.index = index
        self.startingDirectory = startingDirectory
        self.shell = shell
    }
    /// Bumped whenever a fresh terminal view must replace the old one.
    private(set) var generation = 0

    @ObservationIgnored
    private var terminalView: RafuTerminalView?
    @ObservationIgnored
    private var delegateProxy: DelegateProxy?
    @ObservationIgnored
    private var appliedStyleSignature = ""
    /// Invoked once, on natural process exit, forwarded up to
    /// `WorkspaceTerminalManager.sessionDidExit`. Wired by the manager in
    /// `newSession`; `nil` otherwise.
    @ObservationIgnored
    var onExit: (@MainActor (UUID, Int32?) -> Void)?
    /// Invoked once per BEL, forwarded up to
    /// `WorkspaceTerminalManager.sessionDidBell`. Wired by
    /// `RafuTerminalView.onBell` in `makeOrReuseView`; `nil` before a view
    /// mounts.
    @ObservationIgnored
    var onBell: (@MainActor (UUID) -> Void)?

    var isRunning: Bool { status == .running }

    var shellDisplayName: String { shell.basename }

    /// Whether this session's live view currently sits in the KEY window —
    /// part of the "not focused" test for bell attention (terminal-manager
    /// .md T-E): not the focused tab, OR the app inactive, OR the window
    /// not key. `false` when parked (no mounted view) or never spawned.
    var isHostWindowKey: Bool { terminalView?.window?.isKeyWindow ?? false }

    func markParked(sequence: Int) {
        parkSequence = sequence
    }

    /// Forces `.running` without spawning a real process. `makeOrReuseView`
    /// is the one PRODUCTION path to `.running`, and it genuinely spawns a
    /// shell inside a mounted AppKit view — something headless tests never
    /// do (ADR 0004's lazy spawn). Test-only, mirroring
    /// `processDidTerminate(exitCode:)`'s "internal so tests can drive it
    /// directly" precedent: exercises `noteBell()`/`clearAttention()` and
    /// the attention pipeline above them without a live pty.
    func markRunningForTesting() {
        status = .running
    }

    /// BEL received while the session is NOT the focused tab
    /// (terminal-manager.md T-E) — the guard also gives free coalescing: a
    /// second bell while already `.bell` is a no-op. Only a `.running`
    /// session can be asked to raise attention; the FOCUS decision itself
    /// lives one level up in `WorkspaceSession.terminalSessionDidBell(_:)`
    /// (`TerminalAttentionPolicy.shouldRaiseAttention`), which only calls
    /// this when it decided to raise.
    func noteBell() {
        guard status == .running else { return }
        status = .bell
    }

    /// Clears the attention state once the tab is focused again — both
    /// `WorkspaceSession.selectEditorTab` and `synchronizeSelectionFromLayout`
    /// call this on their `.terminal` branch, and `revealTerminalSession`
    /// calls it directly since it mutates `editorLayout`/`terminal
    /// .selectedID` without going through either. A no-op outside `.bell`.
    func clearAttention() {
        if status == .bell { status = .running }
    }

    /// Sends a notification reply's already-sanitized, single-line text
    /// into this session's live pty, followed by a trailing newline — the
    /// agent is blocked on a prompt, so exactly one line can ever be
    /// submitted this way (`TerminalAttentionPolicy.sanitizedReply` is the
    /// one caller that produces `text`). Returns `false` — never respawns,
    /// never queues — when there is no live view (parked with nothing
    /// mounted) or the shell has already exited.
    @discardableResult
    func sendReply(_ text: String) -> Bool {
        guard let terminalView else { return false }
        if case .exited = status { return false }
        terminalView.send(txt: text + "\n")
        clearAttention()
        return true
    }

    /// Bounded read of recent on-screen output for an attention
    /// notification's body (terminal-manager.md T-E) — `""` when there is
    /// no live view (e.g. a race where the shell exited between the bell
    /// and the notification actually posting). See
    /// `RafuTerminalView.recentOutputSnippet` for the bounds and privacy
    /// rules; never call this outside the one notification-posting path
    /// that needs it.
    func recentOutputSnippet() -> String {
        terminalView?.recentOutputSnippet() ?? ""
    }

    /// Returns the live terminal view, creating it and spawning the login
    /// shell on first use.
    func makeOrReuseView(theme: RafuTheme) -> LocalProcessTerminalView {
        if let terminalView {
            applyTheme(theme, to: terminalView)
            return terminalView
        }
        let view = RafuTerminalView(frame: .zero)
        let proxy = DelegateProxy(controller: self)
        delegateProxy = proxy
        view.processDelegate = proxy
        view.onBell = { [weak self] in
            guard let self else { return }
            self.onBell?(self.id)
        }
        applyTheme(theme, to: view)

        view.startProcess(
            executable: shell.path,
            args: shell.loginArguments,
            environment: nil,
            execName: "-\(shell.basename)",
            currentDirectory: startingDirectory
        )
        status = .running
        terminalView = view

        let shellPid = view.process.shellPid
        if shellPid != 0 {
            let controllerID = id
            let controllerIndex = index
            Task {
                await ProcessResourceRegistry.shared.register(
                    id: controllerID,
                    name: "Terminal \(controllerIndex)",
                    kind: .terminalShell,
                    pid: shellPid
                )
            }
        }

        return view
    }

    func restart() {
        shutdown()
        generation &+= 1
    }

    /// Terminates the shell and releases the emulator. Safe to call twice.
    /// Explicit close only — a shell that exits on its own goes through
    /// `processDidTerminate(exitCode:)` instead, which never calls
    /// `terminate()` since the process is already gone.
    func shutdown() {
        terminalView?.terminate()
        terminalView = nil
        delegateProxy = nil
        appliedStyleSignature = ""
        status = .exited(code: nil)

        let controllerID = id
        Task {
            await ProcessResourceRegistry.shared.unregister(id: controllerID)
        }
    }

    func applyTheme(_ theme: RafuTheme, to view: LocalProcessTerminalView) {
        let signature = "\(theme.name)|\(theme.editor.background)|\(theme.editorFontSize)"
        guard signature != appliedStyleSignature else { return }
        appliedStyleSignature = signature
        view.nativeBackgroundColor = NSColor(rafuHex: theme.editor.background)
        view.nativeForegroundColor = NSColor(rafuHex: theme.editor.foreground)
        view.caretColor = NSColor(rafuHex: theme.editor.cursor)
        view.font = Self.terminalFont(for: theme)
        view.installColors(Self.ansiPalette(for: theme))
    }

    /// Shell prompts (powerlevel10k, starship) rely on Nerd Font glyphs the
    /// system mono font lacks. When the theme does not name an explicit
    /// editor family, prefer an installed patched font before falling back.
    private static func terminalFont(for theme: RafuTheme) -> NSFont {
        let size = theme.editorFontSize
        if let family = theme.fonts?.editor?.family,
            !["system", "SF Mono", ""].contains(family),
            let themed = NSFont(name: family, size: size)
        {
            return themed
        }
        let patchedCandidates = [
            "MesloLGS NF",
            "MesloLGS Nerd Font",
            "JetBrainsMono Nerd Font Mono",
            "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono",
        ]
        for name in patchedCandidates {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Natural process exit (SwiftTerm's delegate callback, not an explicit
    /// `close`/`shutdown`). Per the terminal-manager T-A coordinator
    /// decision, the session lingers as `.exited(code:)` — its tab (or
    /// parked row) stays so the exit code and Restart Shell affordance
    /// remain visible/usable; nothing here removes it from
    /// `WorkspaceTerminalManager.sessions` or any tab. The emulator view is
    /// released since it is unusable once the process is gone. Internal
    /// (not `fileprivate`) so tests can drive it directly.
    func processDidTerminate(exitCode: Int32?) {
        status = .exited(code: exitCode)
        terminalView = nil
        delegateProxy = nil
        appliedStyleSignature = ""

        let controllerID = id
        Task {
            await ProcessResourceRegistry.shared.unregister(id: controllerID)
        }
        onExit?(id, exitCode)
    }

    /// OSC 0/2 title report from the shell (terminal-manager.md T-D — agent
    /// CLIs set this, e.g. "✳ claude"). An empty/whitespace-only report
    /// clears the auto title back to the shell/index fallback rather than
    /// storing blank text; `userName`, when set, always wins regardless
    /// (`displayName`). Internal (not `fileprivate`, mirroring
    /// `processDidTerminate(exitCode:)`) so tests can drive it directly
    /// without a live SwiftTerm delegate callback.
    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        reportedTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// OSC 7 delivers the shell's cwd as a `file://host/path` URI; some
    /// shells send a bare path instead. `nil` clears the report.
    fileprivate func updateCurrentDirectory(_ directory: String?) {
        guard let directory, !directory.isEmpty else {
            currentDirectoryPath = nil
            return
        }
        if directory.hasPrefix("file://"), let url = URL(string: directory) {
            currentDirectoryPath = url.path
        } else {
            currentDirectoryPath = directory
        }
    }

    /// 16-entry ANSI palette derived from theme tokens. Black/white anchor on
    /// text/background tokens so both light and dark themes stay readable.
    private static func ansiPalette(for theme: RafuTheme) -> [SwiftTerm.Color] {
        let ui = theme.ui
        let git = theme.git
        let dark = theme.isDark
        let black = dark ? (ui.borderStrong ?? ui.borderSubtle) : ui.textPrimary
        let white = dark ? ui.textPrimary : ui.appBackground
        let red = ui.error ?? "#E06C75"
        let green = ui.success ?? "#7CC08A"
        let yellow = ui.warning ?? "#D4A24E"
        let blue = ui.info ?? "#82A7F0"
        let magenta = git?.conflict ?? "#C678DD"
        let cyan = ui.remoteIndicator ?? "#74BFCB"
        let normal = [black, red, green, yellow, blue, magenta, cyan, white]
        let bright = [
            dark ? (ui.textMuted ?? ui.textSecondary) : black,
            red, green, yellow, blue, magenta, cyan,
            dark ? ui.textPrimary : white,
        ]
        return (normal + bright).map(terminalColor)
    }

    private static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let nsColor = NSColor(rafuHex: hex).usingColorSpace(.sRGB) ?? .black
        return SwiftTerm.Color(
            red: UInt16(max(0, min(1, nsColor.redComponent)) * 65535),
            green: UInt16(max(0, min(1, nsColor.greenComponent)) * 65535),
            blue: UInt16(max(0, min(1, nsColor.blueComponent)) * 65535)
        )
    }
}

/// Nonisolated shim between SwiftTerm's delegate (called on the main thread,
/// but not actor-annotated) and the MainActor controller.
private final class DelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
    private weak var controller: WorkspaceTerminalController?

    init(controller: WorkspaceTerminalController) {
        self.controller = controller
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // SwiftTerm delivers delegate callbacks on the main thread.
        MainActor.assumeIsolated {
            controller?.updateTitle(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            controller?.updateCurrentDirectory(directory)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            controller?.processDidTerminate(exitCode: exitCode)
        }
    }
}
