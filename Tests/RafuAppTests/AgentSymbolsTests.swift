import AppKit
import Testing

@testable import RafuApp

/// A missing SF Symbol fails silently: SwiftUI draws nothing and leaves an
/// empty well. `terminal.badge` shipped that way in four places, so every
/// shared agent symbol must resolve on the running system.
@Suite("Agent symbols")
struct AgentSymbolsTests {
    @Test("The agent-terminal symbol is a real SF Symbol")
    func agentTerminalSymbolResolves() {
        #expect(
            NSImage(systemSymbolName: AgentSymbols.agentTerminal, accessibilityDescription: nil)
                != nil)
    }

    @Test("Every agent CLI menu fallback symbol is a real SF Symbol")
    func menuFallbackSymbolsResolve() {
        for cli in ConductorCLIID.allCases {
            #expect(
                NSImage(systemSymbolName: cli.menuFallbackSymbolName, accessibilityDescription: nil)
                    != nil)
        }
    }
}
