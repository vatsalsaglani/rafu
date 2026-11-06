import RafuCore
import Testing

@testable import RafuApp

@Suite("Agent control pill presentation")
struct CanvasAgentControlPresentationTests {
    @Test("Each mode has its own glyph")
    func symbols() {
        #expect(AgentControlPresentation.symbol(.off) == "hand.raised")
        #expect(AgentControlPresentation.symbol(.ask) == "questionmark.circle")
        #expect(AgentControlPresentation.symbol(.allow) == "checkmark.circle")
    }

    @Test("The label is the word, plus the waiting count")
    func labels() {
        #expect(AgentControlPresentation.label(.allow, waiting: 0) == "Allow")
        #expect(AgentControlPresentation.label(.ask, waiting: 2) == "Ask · 2 waiting")
        #expect(AgentControlPresentation.label(.off, waiting: 0) == "Off")
    }

    @Test("VoiceOver hears the mode and the waiting count")
    func accessibility() {
        #expect(AgentControlPresentation.accessibilityValue(.ask, waiting: 0) == "Ask")
        #expect(
            AgentControlPresentation.accessibilityValue(.ask, waiting: 1)
                == "Ask, 1 waiting for approval")
    }
}
