import Foundation
import Testing

@testable import RafuApp

@Suite("RafuDropdownFilter")
struct RafuSearchableDropdownTests {
    @Test("An empty query matches everything")
    func emptyQueryMatchesAll() {
        #expect(RafuDropdownFilter.matches(query: "", fields: ["origin/main"]))
        #expect(RafuDropdownFilter.matches(query: "", fields: []))
    }

    @Test("A whitespace-only query matches everything")
    func whitespaceQueryMatchesAll() {
        #expect(RafuDropdownFilter.matches(query: "   ", fields: ["origin/main"]))
        #expect(RafuDropdownFilter.matches(query: "\t \n", fields: ["feature/x"]))
    }

    @Test("Matching is case-insensitive")
    func caseInsensitiveSubstring() {
        #expect(RafuDropdownFilter.matches(query: "MAIN", fields: ["origin/main"]))
        #expect(RafuDropdownFilter.matches(query: "main", fields: ["ORIGIN/MAIN"]))
    }

    @Test("A multi-token query requires every token to match (AND)")
    func multiTokenAndBothPresent() {
        #expect(RafuDropdownFilter.matches(query: "origin main", fields: ["origin/main"]))
    }

    @Test("A multi-token query fails when one token is missing")
    func multiTokenAndOneMissing() {
        #expect(!RafuDropdownFilter.matches(query: "origin develop", fields: ["origin/main"]))
    }

    @Test("A non-matching query returns false")
    func noMatch() {
        #expect(!RafuDropdownFilter.matches(query: "release", fields: ["origin/main"]))
    }

    @Test("filter preserves order and returns only matching items")
    func filterPreservesOrderAndFiltersMatches() {
        struct Fixture { let name: String }
        let items = [
            Fixture(name: "main"),
            Fixture(name: "origin/main"),
            Fixture(name: "feature/login"),
            Fixture(name: "origin/develop"),
        ]
        let result = RafuDropdownFilter.filter(items, query: "main") { [$0.name] }
        #expect(result.map(\.name) == ["main", "origin/main"])
    }
}
