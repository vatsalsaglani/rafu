import Foundation
import Testing

@testable import RafuApp

/// The list-and-classify rules every Rafu model picker shares. Extracted from
/// Settings → Agents so the New Ensemble canvas's coordinator and per-CLI
/// pickers cannot drift from it.
@Suite("Conductor model catalog")
struct ConductorModelCatalogTests {
    private static let curated = [
        ConductorModelChoice(id: "gpt-5.6", displayName: "GPT-5.6", source: .curated),
        ConductorModelChoice(id: "gpt-5.6-mini", displayName: "GPT-5.6 mini", source: .curated),
    ]

    @Test("Curated comes first, discovery appends, and ids are deduplicated")
    func mergeOrderAndDedupe() {
        let discovered = [
            // Same id as a curated entry: the curated row wins, and the list
            // does not grow a duplicate the user would have to tell apart.
            ConductorModelChoice(id: "gpt-5.6", displayName: "gpt-5.6", source: .discovered),
            ConductorModelChoice(id: "local-model", displayName: "Local", source: .discovered),
        ]

        let merged = ConductorModelCatalog.merge(curated: Self.curated, discovered: discovered)

        #expect(merged.map(\.id) == ["gpt-5.6", "gpt-5.6-mini", "local-model"])
        #expect(merged[0].source == .curated)
        #expect(merged[0].displayName == "GPT-5.6")
    }

    @Test("A known id resolves to its catalog entry")
    func knownChoice() {
        let choice = ConductorModelCatalog.choice(for: "gpt-5.6-mini", in: Self.curated)
        #expect(choice?.displayName == "GPT-5.6 mini")
        #expect(choice?.source == .curated)
    }

    /// The property the whole feature rests on: a user must be able to run a
    /// model Rafu has never heard of. It is neither rejected nor silently
    /// promoted to "known" — it comes back as `.custom`, which is exactly the
    /// claim Rafu can honestly make about it.
    @Test("An unlisted id survives as .custom rather than being dropped")
    func unknownChoiceStaysCustom() {
        let choice = ConductorModelCatalog.choice(for: "some-private-model", in: Self.curated)
        #expect(choice?.id == "some-private-model")
        #expect(choice?.displayName == "some-private-model")
        #expect(choice?.source == .custom)
    }

    @Test("Not-set values resolve to nothing, and a real value is trimmed")
    func notSetValues() {
        #expect(ConductorModelCatalog.choice(for: nil, in: Self.curated) == nil)
        #expect(ConductorModelCatalog.choice(for: "", in: Self.curated) == nil)
        #expect(ConductorModelCatalog.choice(for: "  \n ", in: Self.curated) == nil)
        #expect(ConductorModelCatalog.choice(for: "  gpt-5.6  ", in: Self.curated)?.id == "gpt-5.6")
    }
}
