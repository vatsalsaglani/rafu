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

@Test("Palette query parser maps the colon prefix to go-to-line mode")
func paletteQueryParserGotoLineMode() {
    #expect(PaletteQueryParser.parse(":20") == .init(mode: .gotoLine, term: "20"))
    #expect(PaletteQueryParser.parse(":") == .init(mode: .gotoLine, term: ""))
    #expect(PaletteQueryParser.parse(": 20 ") == .init(mode: .gotoLine, term: "20"))
}

@Test("Go-to-line query parses a positive integer and rejects everything else")
func gotoLineQueryParsing() {
    #expect(GotoLineQuery.parse("20") == 20)
    #expect(GotoLineQuery.parse("1") == 1)
    #expect(GotoLineQuery.parse("") == nil)
    #expect(GotoLineQuery.parse("0") == nil)
    #expect(GotoLineQuery.parse("-5") == nil)
    #expect(GotoLineQuery.parse("12abc") == nil)
    #expect(GotoLineQuery.parse("abc") == nil)
}

@Test("File ranking prefers a filename match over a deeper path-only match")
func rankFilesPrefersFilenameMatches() async throws {
    let paths = [
        "src/view/legacy/OldRenderer.swift",
        "src/View.swift",
        "src/components/nested/deep/tree/ViewHelper.swift",
    ]

    let ranked = try await CommandPaletteMatcher.rankFiles(query: "view", paths: paths, limit: 10)

    #expect(ranked.first == "src/View.swift")
}

@Test("File ranking keeps a filename match ahead of a path match at any depth")
func rankFilesFilenameBeatsPathAtDepth() async throws {
    let paths = [
        String(repeating: "nested/", count: 12) + "Widget.swift",
        "viewport/Ignored.swift",
    ]

    let ranked = try await CommandPaletteMatcher.rankFiles(query: "widget", paths: paths, limit: 10)

    #expect(ranked.first == paths[0])
}

@Test("File ranking ties break on shorter path, then lexicographic order")
func rankFilesTieBreaksOnShorterThenLexicographicPath() async throws {
    let paths = ["b/Main.swift", "a/Main.swift", "Main.swift"]

    let ranked = try await CommandPaletteMatcher.rankFiles(query: "main", paths: paths, limit: 10)

    #expect(ranked == ["Main.swift", "a/Main.swift", "b/Main.swift"])
}

@Test("File ranking with an empty query returns the first entries up to the limit")
func rankFilesEmptyQueryReturnsPrefix() async throws {
    let paths = ["a.swift", "b.swift", "c.swift"]

    let ranked = try await CommandPaletteMatcher.rankFiles(query: "", paths: paths, limit: 2)

    #expect(ranked == ["a.swift", "b.swift"])
}

@Test("File ranking is cancellable")
func rankFilesRespectsCancellation() async {
    let paths = (0..<50_000).map { "src/module\($0 % 200)/File\($0).swift" }
    let task = Task {
        try await CommandPaletteMatcher.rankFiles(query: "file", paths: paths, limit: 10)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}
