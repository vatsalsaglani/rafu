import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// Pure timing rules for the hold-⌘ shortcut badges on the Activity Rail.
///
/// The badges show only when ⌘ is held alone for `revealDelay` with no key
/// pressed in between. A key press, another modifier, or a change of key
/// window hides them, and they stay hidden until ⌘ is pressed again. So a
/// quick ⌘S or ⌘B never flashes them. Time is passed in, so tests need no
/// sleeps.
nonisolated struct NavigatorShortcutHintState: Equatable, Sendable {
    static let revealDelay: TimeInterval = 0.5

    /// When ⌘ went down alone and nothing has cancelled it since.
    private(set) var commandHeldSince: TimeInterval?
    private var isCommandDown = false
    /// Set by a key press or another modifier while ⌘ is down; cleared only
    /// when ⌘ is released.
    private var isCancelled = false

    private static let relevantFlags: NSEvent.ModifierFlags = [
        .command, .shift, .option, .control,
    ]

    /// True while the timer is armed: ⌘ is down alone and nothing cancelled it.
    var isArmed: Bool { commandHeldSince != nil }

    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) {
        let held = flags.intersection(Self.relevantFlags)
        guard held.contains(.command) else {
            self = NavigatorShortcutHintState()
            return
        }
        isCommandDown = true
        if held == .command {
            if !isCancelled, commandHeldSince == nil { commandHeldSince = time }
        } else {
            commandHeldSince = nil
            isCancelled = true
        }
    }

    mutating func keyDown(at time: TimeInterval) {
        commandHeldSince = nil
        if isCommandDown { isCancelled = true }
    }

    mutating func windowResignedKey() {
        self = NavigatorShortcutHintState()
    }

    func isVisible(at time: TimeInterval) -> Bool {
        guard let since = commandHeldSince else { return false }
        return time - since >= Self.revealDelay
    }
}

/// What may take an Escape key press while Zen mode is on. Escape leaves Zen
/// only when nothing else could want it: never in a text field, the editor,
/// a terminal, a sheet, the tab switcher, or an Ensemble board.
nonisolated enum ZenModeEscapePolicy {
    enum Responder: Equatable, Sendable {
        case textInput
        case terminal
        case other
    }

    static func shouldExit(
        isZenMode: Bool,
        responder: Responder,
        hasAttachedSheet: Bool,
        isEditorTabSwitcherOpen: Bool,
        isBoardSelected: Bool
    ) -> Bool {
        isZenMode && responder == .other && !hasAttachedSheet
            && !isEditorTabSwitcherOpen && !isBoardSelected
    }

    /// Escape with no modifier. Key code 53 is Escape on every layout.
    static func isPlainEscape(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53
            && flags.intersection([.command, .shift, .option, .control]).isEmpty
    }

    @MainActor
    static func classify(_ responder: NSResponder?) -> Responder {
        if responder is NSText || responder is NSTextField { return .textInput }
        if responder is TerminalView { return .terminal }
        return .other
    }
}

/// One local event monitor per workspace window. It reads modifier changes
/// and key presses to drive the badges, and it offers Escape to the Zen
/// handler. Every event it does not itself act on is returned unchanged.
///
/// Rules (see `docs/references/navigator-shortcut-hint-monitor.md`):
/// - It reacts only to events for its own window while that window is key.
/// - It returns every event unchanged, except an Escape the Zen handler took.
/// - It is installed when the window appears and removed when it goes away.
@MainActor
@Observable
final class NavigatorShortcutHintMonitor {
    /// True while the badges should be on screen.
    private(set) var isVisible = false

    @ObservationIgnored private var state = NavigatorShortcutHintState()
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var revealTask: Task<Void, Never>?

    /// Called for a plain Escape in this window while it is key. Returns true
    /// when it used the key; the key is then consumed.
    @ObservationIgnored var escapeHandler: ((NSWindow) -> Bool)?

    func install(in window: NSWindow) {
        guard hostWindow !== window || eventMonitor == nil else { return }
        remove()
        hostWindow = window
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowResignedKey() }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func remove() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        hostWindow = nil
        reset()
    }

    isolated deinit { remove() }

    private func windowResignedKey() {
        state.windowResignedKey()
        reset()
    }

    private func reset() {
        state = NavigatorShortcutHintState()
        revealTask?.cancel()
        revealTask = nil
        if isVisible { isVisible = false }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // A modifier change can arrive without a window; it still belongs to
        // the key window, which is this one only when `isKeyWindow` is true.
        guard let window = hostWindow, window.isKeyWindow,
            event.window == nil || event.window === window
        else { return event }
        let now = ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .flagsChanged:
            state.flagsChanged(event.modifierFlags, at: now)
            sync()
        case .keyDown:
            state.keyDown(at: now)
            sync()
            if ZenModeEscapePolicy.isPlainEscape(
                keyCode: event.keyCode, flags: event.modifierFlags),
                escapeHandler?(window) == true
            {
                return nil
            }
        default:
            break
        }
        return event
    }

    /// Hides at once on any cancelling change; arms one cancellable timer
    /// while ⌘ is held alone.
    private func sync() {
        revealTask?.cancel()
        revealTask = nil
        if isVisible { isVisible = false }
        guard state.isArmed else { return }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NavigatorShortcutHintState.revealDelay))
            guard !Task.isCancelled, let self, self.state.isArmed else { return }
            self.isVisible = true
        }
    }
}

/// Hands the hosting window to `onWindow` as soon as AppKit attaches the view,
/// and `nil` when it leaves. Zero-sized and never hit.
struct NavigatorHintWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: Host, context: Context) { view.onWindow = onWindow }

    static func dismantleNSView(_ view: Host, coordinator: ()) { view.onWindow?(nil) }

    final class Host: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// The small "⌘1" label drawn at the bottom right of a rail button. It is an
/// overlay, so it never changes the button's frame, and VoiceOver skips it:
/// the button's hint already says the shortcut.
struct NavigatorShortcutBadge: View {
    let label: String

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Text(label)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.palette.editorBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(theme.palette.borderStrong, lineWidth: 1)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
