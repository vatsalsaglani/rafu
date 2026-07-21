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
