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
        let count = slice.count
        MainActor.assumeIsolated {
            onOutputActivity?(count)
        }
        super.dataReceived(slice: slice)
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
}
