import AppKit
import SwiftTerm
import Testing

@testable import RafuApp

/// Empirical probe: does a literal BEL byte fed through SwiftTerm's parser
/// actually reach `RafuTerminalView.onBell`? This exercises the REAL
/// dispatch chain (feed → EscapeSequenceParser → Terminal.tdel.bell →
/// TerminalView.bell override), not a hand-called override.
@Test("A BEL byte fed through the parser fires onBell")
@MainActor
func belByteFiresOnBell() {
    let view = RafuTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var rang = 0
    view.onBell = { rang += 1 }
    view.feed(byteArray: ArraySlice([0x07]))
    #expect(rang == 1)
    view.feed(text: "hello\u{07}world")
    #expect(rang == 2)
}

/// Agent CLIs signal turn-completion with OSC 9 / OSC 777 notifications,
/// not BEL — this pins that both escapes, fed through SwiftTerm's real
/// parser, reach `onNotification` once handlers are installed.
@Test("OSC 9 and OSC 777 notifications fed through the parser fire onNotification")
@MainActor
func oscNotificationsFireOnNotification() {
    let view = RafuTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    var messages: [String] = []
    view.onNotification = { messages.append($0) }
    view.installNotificationHandlers()

    // OSC 9 — Codex `tui.notifications`, iTerm2-style.
    view.feed(text: "\u{1b}]9;Agent turn complete\u{07}")
    #expect(messages == ["Agent turn complete"])

    // OSC 777 — rxvt notify convention.
    view.feed(text: "\u{1b}]777;notify;claude;needs your input\u{07}")
    #expect(messages == ["Agent turn complete", "claude: needs your input"])

    // A non-notify 777 payload is ignored.
    view.feed(text: "\u{1b}]777;something-else;x\u{07}")
    #expect(messages.count == 2)

    // BEL still works independently.
    var rang = 0
    view.onBell = { rang += 1 }
    view.feed(byteArray: ArraySlice([0x07]))
    #expect(rang == 1)
}
