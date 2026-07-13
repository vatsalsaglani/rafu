import Testing

@testable import RafuApp

@Test("Command palette fuzzy matching accepts subsequences and ranks stronger matches first")
func commandPaletteFuzzyRanking() {
    let candidates = ["Show Files", "Move Navigator Right", "Search Workspace"]

    #expect(CommandPaletteMatcher.rank(query: "mnr", candidates: candidates) == [1])
    #expect(CommandPaletteMatcher.rank(query: "search", candidates: candidates).first == 2)
    #expect(CommandPaletteMatcher.score(query: "zz", candidate: "Show Files") == nil)
}

@Test("Command palette fuzzy ranking preserves source order for equal scores")
func commandPaletteFuzzyRankingIsStable() {
    let candidates = ["Alpha One", "Alpha Two", "Alpha Three"]
    let ranked = CommandPaletteMatcher.rank(query: "alpha", candidates: candidates)

    #expect(ranked == [0, 1, 2])
}

@Test("Palette query parser maps prefixes to modes and trims the term")
func paletteQueryParserModes() {
    #expect(PaletteQueryParser.parse("") == .init(mode: .files, term: ""))
    #expect(PaletteQueryParser.parse("main.swift") == .init(mode: .files, term: "main.swift"))
    #expect(PaletteQueryParser.parse("> new file ") == .init(mode: .commands, term: "new file"))
    #expect(PaletteQueryParser.parse(">") == .init(mode: .commands, term: ""))
    #expect(PaletteQueryParser.parse("@render") == .init(mode: .symbols, term: "render"))
    #expect(PaletteQueryParser.parse("@") == .init(mode: .symbols, term: ""))
}

@Test("Palette query parser only honours prefixes in the leading position")
func paletteQueryParserPrefixPosition() {
    #expect(PaletteQueryParser.parse("readme > docs") == .init(mode: .files, term: "readme > docs"))
    #expect(PaletteQueryParser.parse("user@host") == .init(mode: .files, term: "user@host"))
}
