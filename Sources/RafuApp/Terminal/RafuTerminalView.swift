import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` subclass that forwards BEL (terminal-manager.md
/// T-E) and exposes a bounded, privacy-safe read of recent output for
/// attention notifications.
///
/// SwiftTerm 1.14.0's own `LocalProcessTerminalViewDelegate` has no bell
/// member (verified: `Mac/MacLocalTerminalView.swift`'s protocol is
/// `sizeChanged`/`setTerminalTitle`/`hostCurrentDirectoryUpdate`/
/// `processTerminated` only). BEL instead reaches `TerminalView.bell(source:
/// Terminal)` (`Mac/MacTerminalView.swift`), an `open` method whose default
/// implementation only forwards to `TerminalViewDelegate.bell` (which
/// defaults to `NSSound.beep()`) — there is no delegate seam to hook, so
/// this subclass overrides `bell(source:)` directly, calling `super` first
/// to preserve the system beep.
final class RafuTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TerminalNewlineMonitor.updateRegistration(for: self)
    }

    isolated deinit {
        TerminalNewlineMonitor.removeRegistration(for: self)
    }

    // MARK: Frosted margin

    /// Frosted deck only (ADR 0038). SwiftTerm paints whole rows, so the
    /// strip below the last row (less than one cell high) is never painted.
    /// With an opaque layer colour that strip was hidden; with the layer
    /// cleared for a translucent background it would show the frame. This
    /// view paints the strip in the same translucent colour as the cells.
    private var marginFill: TerminalMarginFillView?

    /// `nil` removes the strip (an opaque terminal).
    func setMarginFill(_ color: NSColor?) {
        guard let color else {
            marginFill?.removeFromSuperview()
            marginFill = nil
            return
        }
        let fill: TerminalMarginFillView
        if let marginFill {
            fill = marginFill
        } else {
            fill = TerminalMarginFillView()
            // Lowest subview: never above the scroller or the find bar.
            addSubview(fill, positioned: .below, relativeTo: nil)
            marginFill = fill
        }
        fill.color = color
        layoutMarginFill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMarginFill()
    }

    /// Only runs once a fill exists, which `applyTheme` installs after
    /// SwiftTerm has measured its cells, so the grid size is valid.
    private func layoutMarginFill() {
        guard let marginFill else { return }
        let gridHeight = getOptimalFrameSize().height
        let frame = TerminalMarginFillView.frame(
            bounds: bounds, gridHeight: gridHeight)
        if marginFill.frame != frame { marginFill.frame = frame }
    }

    /// SwiftTerm's keyDown is public but not open. The local monitor calls
    /// this only for the event window's visible terminal first responder.
    func handleLegacyNewline(_ event: NSEvent) -> Bool {
        guard
            TerminalNewlinePolicy.usesLegacyLineFeed(
                event: event,
                hasMarkedText: hasMarkedText(),
                hasKeyboardProtocol: !getTerminal().keyboardEnhancementFlags.isEmpty
            )
        else { return false }
        // LF is Ctrl-J: distinct from Return's CR in raw-mode CLI input.
        send([0x0A])
        return true
    }

    /// A narrow responder-chain seam for Terminal Groups. The callback is
    /// installed with a weak coordinator capture and cleared when its host is
    /// dismantled, so the AppKit view never becomes a focus-state owner.
    var onDidBecomeFirstResponder: (() -> Void)?
    private weak var firstResponderCallbackOwner: AnyObject?

    func setFirstResponderCallback(owner: AnyObject, callback: @escaping () -> Void) {
        firstResponderCallbackOwner = owner
        onDidBecomeFirstResponder = callback
    }

    /// Clears the focus callback only when this host still owns it. A reused
    /// terminal view can be mounted by a newer host before the stale one
    /// dismantles.
    func clearFirstResponderCallback(owner: AnyObject) {
        guard firstResponderCallbackOwner === owner else { return }
        firstResponderCallbackOwner = nil
        onDidBecomeFirstResponder = nil
    }

    /// Fired for terminal NOTIFICATION escapes — the signals agent CLIs
    /// actually emit when a turn finishes or input is needed, which plain
    /// BEL detection missed entirely:
    ///
    /// - OSC 9  (`ESC ] 9 ; message BEL`) — the iTerm2-style notification
    ///   Codex emits with `tui.notifications = true`, and Claude Code's
    ///   "iterm2" notification channel.
    /// - OSC 777 (`ESC ] 777 ; notify ; title ; body BEL`) — the
    ///   rxvt/urgency convention some CLIs use.
    ///
    /// Neither reaches a `LocalProcessTerminalView` subclass through
    /// delegate overrides: `TerminalView` never implements
    /// `TerminalDelegate.notify`, so OSC 777 dies in the protocol-extension
    /// no-op (the same statically-bound-witness trap as `bell`), and OSC 9
    /// has no delegate at all. `Terminal.parser.oscHandlers` is the public
    /// seam — handlers registered there win before SwiftTerm's built-ins.
    /// Registered in `installNotificationHandlers()`, called once from
    /// `WorkspaceTerminalController.makeOrReuseView`.
    var onNotification: ((String) -> Void)?

    /// Byte-level output activity, for the zero-config quiescence detector
    /// (`TerminalQuiescencePolicy`): called with each pty read's byte count.
    /// Content is never passed — timing and volume only.
    var onOutputActivity: ((Int) -> Void)?

    /// `LocalProcess` delivers pty reads here (the view is its delegate and
    /// `dataReceived` is `open` — unlike `feed`, which is only `public`).
    /// Tap the byte count for activity tracking, then let SwiftTerm parse
    /// as normal.
    nonisolated override func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            onOutputActivity?(slice.count)
            guard !slice.isEmpty else { return }
            super.dataReceived(slice: slice)
        }
    }

    /// Parser handlers run synchronously inside `feed` on the main thread —
    /// the same delivery the `bell` override documents below.
    func installNotificationHandlers() {
        let terminal = getTerminal()
        terminal.parser.oscHandlers[9] = { [weak self] data in
            let message = String(decoding: data, as: UTF8.self)
            self?.onNotification?(message)
        }
        terminal.parser.oscHandlers[777] = { [weak self] data in
            // "notify;title;body" — surface "title: body" (or whatever
            // subset exists) as the message.
            let parts = String(decoding: data, as: UTF8.self)
                .split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.first == "notify" else { return }
            let message = parts.dropFirst().filter { !$0.isEmpty }.joined(separator: ": ")
            self?.onNotification?(message)
        }
    }

    // `nonisolated`: the modern AppKit SDK overlay marks `NSView` (and so
    // `TerminalView`/`bell(source:)`, which SwiftTerm never annotates
    // itself) `@MainActor` — mirroring `WorkspaceTerminalController.swift`'s
    // `DelegateProxy`, which hops the same way for SwiftTerm's other
    // delegate callbacks, all of which it documents as arriving on the
    // main thread despite carrying no actor annotation of their own.
    // `super.bell(source:)` (which preserves the default `NSSound.beep()`)
    // is itself `@MainActor`, so it — and `onBell?()` — must run INSIDE the
    // same `assumeIsolated` block. The incoming `source` parameter is
    // NOT forwarded directly: it arrives task-isolated to this nonisolated
    // override, and the compiler correctly refuses to "send" a non-`
    // Sendable` `Terminal` across that boundary even though this call site
    // is synchronous and safe in practice (SwiftTerm always calls `bell`
    // on the main thread). Re-fetching the SAME instance via `getTerminal
    // ()` from inside the already-isolated closure — there is exactly one
    // `Terminal` per `TerminalView`, so `source` and `getTerminal()` are
    // the same object here — satisfies the checker without an `@unchecked
    // Sendable`/`@preconcurrency` escape hatch.
    nonisolated override func bell(source: Terminal) {
        MainActor.assumeIsolated {
            super.bell(source: getTerminal())
            onBell?()
        }
    }

    /// SwiftTerm does not leave `becomeFirstResponder()` open for a client
    /// subclass, and its pointer implementation does not request window
    /// focus. Preserve that handling, then synchronize host selection whenever
    /// the clicked terminal is first responder. AppKit can assign the responder
    /// before mouseDown, while SwiftUI still has another card selected.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let window else { return }
        if window.firstResponder !== self {
            guard window.makeFirstResponder(self) else { return }
        }
        onDidBecomeFirstResponder?()
    }

    /// Bounded, privacy-conscious read of the last non-empty lines on
    /// screen at/above the cursor — for the attention-notification snippet
    /// only (terminal-manager.md T-E). Deliberately narrow: iterates the
    /// VIEWPORT only (`Terminal.getLine(row:)`/`rows`, never
    /// `getBufferAsData`, which walks the entire scrollback and is
    /// forbidden here), then hands the raw candidate lines to
    /// `TerminalAttentionPolicy.snippet` for bounding/sanitizing. Callers
    /// must only invoke this at bell time, when a notification will
    /// actually post — never from a view body — and the result must never
    /// be logged, persisted, or transmitted anywhere but the one
    /// notification post that requested it (AGENTS).
    func recentOutputSnippet(maxLines: Int = 6, maxBytes: Int = 512) -> String {
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        let topRow = max(0, min(cursor.y, terminal.rows - 1))
        guard topRow >= 0 else { return "" }
        var lines: [String] = []
        for row in 0...topRow {
            guard let line = terminal.getLine(row: row) else { continue }
            lines.append(
                line.translateToString(
                    trimRight: true, characterProvider: terminal.getCharacter(for:)))
        }
        return TerminalAttentionPolicy.snippet(from: lines, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// The same VIEWPORT-only read as `recentOutputSnippet`, as raw lines,
    /// for Rafu Voice's `ensemble_describe` in Allow mode only. The caller
    /// scrubs and bounds them (`VoiceOutputScrubber`) before they leave the
    /// app; never log or persist them.
    ///
    /// `fullViewport: true` reads every viewport row, also rows below the
    /// cursor. The channel-prompt confirmer uses it so its "Enter to confirm
    /// is the last non-empty row" rule does not depend on where the program
    /// leaves the cursor.
    func recentOutputLines(maxLines: Int = 40, fullViewport: Bool = false) -> [String] {
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        let topRow =
            fullViewport
            ? max(0, terminal.rows - 1) : max(0, min(cursor.y, terminal.rows - 1))
        var lines: [String] = []
        for row in 0...topRow {
            guard let line = terminal.getLine(row: row) else { continue }
            // A cell that was never written reads as NUL. Programs that move the
            // cursor between words (Claude Code's dialogs) leave only NUL gaps.
            let text = line.translateToString(
                trimRight: true, characterProvider: terminal.getCharacter(for:))
            lines.append(String(text.map { $0 == "\u{0}" ? " " : $0 }))
        }
        return Array(lines.suffix(max(0, maxLines)))
    }
}

/// The strip below a frosted terminal's last row: SwiftTerm draws rows from
/// the top of its (unflipped) view, so the strip is at the bottom. It takes no
/// clicks and is hidden from accessibility.
final class TerminalMarginFillView: NSView {
    var color: NSColor = .clear {
        didSet {
            guard color != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The strip's frame: the full width, from the bottom up to the grid.
    static func frame(bounds: NSRect, gridHeight: CGFloat) -> NSRect {
        NSRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: max(0, bounds.height - gridHeight))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // `dirtyRect` can be larger than the bounds (an unclipped view on
        // this SDK). Filling it would paint the translucent background over
        // the whole terminal, above the text, and fade it.
        let rect = bounds.intersection(dirtyRect)
        guard !rect.isEmpty else { return }
        color.setFill()
        rect.fill()
    }
}
