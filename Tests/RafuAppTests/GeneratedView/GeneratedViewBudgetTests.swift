import Foundation
import Testing

@testable import RafuApp

@Suite("Generated view board budget")
@MainActor
struct GeneratedViewBudgetTests {
    let fixtures = GeneratedViewFixtures.self

    /// A spec-shaped string of about `bytes` stored bytes (the check does not
    /// validate; the host validates before it).
    private func card(bytes: Int, state: String? = nil) -> CanvasCard {
        let text = String(repeating: "a", count: bytes)
        var view = GeneratedViewActions.view(
            #"{"elements":{"r":{"props":{"text":"\#(text)"},"type":"Text"}},"root":"r"}"#,
            provenance: fixtures.provenance())
        view.state = state.map {
            CanvasGeneratedViewState(
                specVersion: String(repeating: "0", count: 64), catalogVersion: "x",
                savedAt: Date(), stateJSON: $0)
        }
        return CanvasCard(title: "View", content: .generatedView(view))
    }

    @Test("Stored bytes count JSON string escapes")
    func storedBytes() {
        #expect(GeneratedViewBudget.storedBytes("ab") == 4)
        #expect(GeneratedViewBudget.storedBytes(#"{"a":"/"}"#) == 2 + 9 + 4 + 1)
    }

    @Test("All views on one board share 1 MiB; one more spec past it is refused")
    func boardBudget() {
        let cards = (0..<4).map { _ in card(bytes: 250 * 1_024) }
        let spec =
            #"{"elements":{"r":{"props":{"text":"\#(String(repeating: "b", count: 40_000))"},"type":"Text"}},"root":"r"}"#
        guard case .tooLarge(let bytes)? = GeneratedViewBudget.refusal(specJSON: spec, cards: cards)
        else {
            Issue.record("Expected tooLarge")
            return
        }
        #expect(bytes > GeneratedViewBudget.boardBytes)
        #expect(
            GeneratedViewBudget.refusal(specJSON: fixtures.textSpec, cards: [card(bytes: 10)])
                == nil)
        // Replacing a card's spec does not count the old spec twice.
        let small = cards.prefix(3).map { $0 } + [card(bytes: 100)]
        #expect(
            GeneratedViewBudget.refusal(specJSON: spec, cards: small, replacing: small[3].id) == nil
        )
    }

    @Test("One spec over 256 KiB is refused on its own")
    func specCap() {
        let spec = String(repeating: " ", count: CanvasLimits.generatedViewSpecBytes + 1)
        #expect(
            GeneratedViewBudget.refusal(specJSON: spec, cards: [])
                == .tooLarge(bytes: CanvasLimits.generatedViewSpecBytes + 1))
    }

    @Test("A state's cap shrinks when the board's views are near the budget")
    func stateCap() {
        let target = card(bytes: 100, state: "{}")
        #expect(
            GeneratedViewBudget.stateCap(for: target.id, in: [target])
                == CanvasLimits.generatedViewStateBytes)
        let full = (0..<4).map { _ in card(bytes: 255 * 1_024) } + [target]
        let cap = GeneratedViewBudget.stateCap(for: target.id, in: full)
        #expect(cap < CanvasLimits.generatedViewStateBytes)
        #expect(cap >= 0)
    }

    @Test("The agent's reason names both limits")
    func reason() {
        let text = GeneratedViewBudget.reason(bytes: 2_000_000)
        #expect(text.contains("256 KiB") && text.contains("1024 KiB"))
    }
}
