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
