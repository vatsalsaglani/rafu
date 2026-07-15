import Foundation
import Testing

@testable import RafuApp

@Test("Buffer symbol scanner finds Swift types and functions with UTF-16 name ranges")
func bufferSymbolScannerSwift() {
    let text = """
        // π marks the spot — non-ASCII before every declaration.
        struct Palette {
            func rank(query: String) -> [Int] { [] }
        }
        enum Mode {}
        """
    let symbols = BufferSymbolScanner.scan(text: text, fileExtension: "swift")

    #expect(symbols.map(\.name) == ["Palette", "rank", "Mode"])
    #expect(symbols[0].kind == .type)
    #expect(symbols[1].kind == .function)
    #expect(symbols[1].detail == "func")

    let nsText = text as NSString
    for symbol in symbols {
        #expect(nsText.substring(with: symbol.range) == symbol.name)
    }
}

@Test("Buffer symbol scanner uses per-language keyword tables")
func bufferSymbolScannerLanguages() {
    let python = BufferSymbolScanner.scan(
        text: "class Report:\n    def compute_totals(self):\n        pass\n",
        fileExtension: "py"
    )
    #expect(python.map(\.name) == ["Report", "compute_totals"])
    #expect(python[1].kind == .function)

    let typescript = BufferSymbolScanner.scan(
        text: "interface Props {}\nexport function renderList(items: Props[]) {}\n",
        fileExtension: "ts"
    )
    #expect(typescript.map(\.name) == ["Props", "renderList"])
    #expect(typescript[0].kind == .type)

    // "def" is not a TypeScript keyword, so it must not match there.
    let noPythonInTS = BufferSymbolScanner.scan(text: "def foo():", fileExtension: "ts")
    #expect(noPythonInTS.isEmpty)
}

@Test("Buffer symbol scanner extracts Markdown headings with levels")
func bufferSymbolScannerMarkdownHeadings() {
    let text = """
        # Title
        Body text with a # inline hash.
        ### Deep Section
        ####### Seven hashes is not a heading
        #NoSpace is not a heading
        """
    let symbols = BufferSymbolScanner.scan(text: text, fileExtension: "md")

    #expect(symbols.map(\.name) == ["Title", "Deep Section"])
    #expect(symbols[0].kind == .heading(level: 1))
    #expect(symbols[1].kind == .heading(level: 3))
    #expect(symbols[1].detail == "H3")

    let nsText = text as NSString
    #expect(nsText.substring(with: symbols[1].range) == "Deep Section")
}

@Test("Buffer symbol scanner caps the number of extracted symbols")
func bufferSymbolScannerCap() {
    let text = (0..<10).map { "func symbol\($0)() {}" }.joined(separator: "\n")
    let symbols = BufferSymbolScanner.scan(text: text, fileExtension: "swift", limit: 3)

    #expect(symbols.count == 3)
    #expect(BufferSymbolScanner.symbolLimit == 2_000)
}

// MARK: - Grammar-backed extraction (increment 9)

@Test("Grammar-backed scan finds Swift types, protocols, and methods; skips properties")
func bufferSymbolScannerSwiftGrammar() async throws {
    let text = """
        struct Palette {
            func rank(query: String) -> Int { 0 }
        }

        protocol Drawable {
            func draw()
        }

        class Report {
            var count = 0
        }

        func topLevel() {}
        """
    let symbols = try #require(
        await BufferSymbolScanner.scanUsingGrammar(text: text, grammarID: .swift))

    #expect(symbols.contains { $0.name == "Palette" && $0.kind == .type })
    #expect(symbols.contains { $0.name == "Drawable" && $0.kind == .type })
    #expect(symbols.contains { $0.name == "Report" && $0.kind == .type })
    #expect(symbols.contains { $0.name == "draw" && $0.kind == .function })
    #expect(symbols.contains { $0.name == "topLevel" && $0.kind == .function })
    // The vendored `tags.scm` matches a class-body method against BOTH the
    // nested `definition.method` pattern and the generic top-level
    // `definition.function` pattern; both entries survive as separate
    // symbols — this increment does not deduplicate.
    #expect(symbols.filter { $0.name == "rank" }.count == 2)
    // `var count` is `@definition.property`, intentionally skipped
    // (`BufferSymbol.Kind` stays function/type/heading this increment).
    #expect(!symbols.contains { $0.name == "count" })

    let nsText = text as NSString
    for symbol in symbols {
        #expect(nsText.substring(with: symbol.range) == symbol.name)
    }
}

@Test("Grammar-backed scan finds Python classes and functions, skipping module constants")
func bufferSymbolScannerPythonGrammar() async throws {
    let text = """
        class Report:
            def compute_totals(self):
                pass

        def top_level():
            pass

        CONST = 1
        """
    let symbols = try #require(
        await BufferSymbolScanner.scanUsingGrammar(text: text, grammarID: .python))

    #expect(symbols.map(\.name) == ["Report", "compute_totals", "top_level"])
    #expect(symbols[0].kind == .type)
    #expect(symbols[1].kind == .function)
    #expect(symbols[2].kind == .function)
    // `CONST = 1` is `@definition.constant`, intentionally skipped.
    #expect(!symbols.contains { $0.name == "CONST" })
}

@Test("Grammar-backed scan excludes JavaScript constructors and require() references")
func bufferSymbolScannerJavaScriptGrammar() async throws {
    let text = """
        class Report {
            constructor() {}
            compute() {}
        }

        function topLevel() {}

        const arrow = () => {};

        const value = require('fs');
        """
    let symbols = try #require(
        await BufferSymbolScanner.scanUsingGrammar(text: text, grammarID: .javascript))

    #expect(symbols.map(\.name) == ["Report", "compute", "topLevel", "arrow"])
    #expect(symbols[0].kind == .type)
    #expect(symbols.dropFirst().allSatisfy { $0.kind == .function })
    // The `#not-eq? @name "constructor"` predicate must be honored via
    // `ResolvingQueryCursor`/`Predicate.Context` — an unresolved
    // `QueryCursor` would include it.
    #expect(!symbols.contains { $0.name == "constructor" })
    // `require('fs')` is a `@reference.call` (also predicate-gated), never a
    // definition, and `value` isn't a definition either (its initializer is
    // a call, not an arrow/function expression).
    #expect(!symbols.contains { $0.name == "require" })
    #expect(!symbols.contains { $0.name == "value" })
}

@Test("Grammar-backed scan finds TypeScript interfaces and excludes constructors")
func bufferSymbolScannerTypeScriptGrammar() async throws {
    let text = """
        interface Props {
            name: string;
        }

        class Report {
            constructor() {}
            compute(): void {}
        }

        function topLevel(): void {}
        """
    let symbols = try #require(
        await BufferSymbolScanner.scanUsingGrammar(text: text, grammarID: .typescript))

    #expect(symbols.map(\.name) == ["Props", "Report", "compute", "topLevel"])
    #expect(symbols[0].kind == .type)
    #expect(symbols[1].kind == .type)
    #expect(!symbols.contains { $0.name == "constructor" })
}

@Test("Grammar-backed scan compiles the combined tags query against the TSX grammar")
func bufferSymbolScannerTSXGrammar() async throws {
    let text = """
        interface Props {
            name: string;
        }

        function Component(props: Props) {
            return null;
        }
        """
    let symbols = try #require(
        await BufferSymbolScanner.scanUsingGrammar(text: text, grammarID: .tsx))

    #expect(symbols.map(\.name) == ["Props", "Component"])
    #expect(symbols[0].kind == .type)
    #expect(symbols[1].kind == .function)
}

@Test("Grammar-backed scan returns nil (not empty) for a grammar without a vendored tags.scm")
func bufferSymbolScannerGrammarNilForUnsupported() async throws {
    let symbols = await BufferSymbolScanner.scanUsingGrammar(
        text: "key: value\n", grammarID: .yaml)
    #expect(symbols == nil)
}

@Test("Grammar-backed scan caps the number of extracted symbols")
func bufferSymbolScannerGrammarCap() async throws {
    let text = (0..<10).map { "func symbol\($0)() {}" }.joined(separator: "\n")
    let symbols = try #require(
        await BufferSymbolScanner.scanUsingGrammar(text: text, grammarID: .swift, limit: 3))
    #expect(symbols.count == 3)
}
