import Foundation
import SwiftTreeSitter
import Testing

@testable import RafuApp

/// Data-level proof that the tree-sitter path actually produces highlight
/// spans (lane-1 increment 8a): a real grammar is loaded, real source is
/// parsed off the main actor, and the query yields the expected capture at the
/// expected UTF-16 range mapped to a `RafuTheme.syntax` key.

@Test("SyntaxParsingActor parses JSON and maps string captures to exact UTF-16 ranges")
func syntaxActorParsesJSONStrings() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .json)
    let actor = try #require(SyntaxParsingActor(configuration: configuration))

    // Offsets: {=0 "name"=1..<7 :=7 space=8 "Rafu"=9..<15 }=15
    let text = "{\"name\": \"Rafu\"}"
    await actor.updateSnapshot(text, version: 1)
    let spans = await actor.tokens(
        inUTF16: NSRange(location: 0, length: (text as NSString).length))

    // The key (`@string.special.key`) and value (`@string`) both collapse to
    // the theme `string` key at their exact quote-inclusive UTF-16 ranges.
    #expect(spans.contains(SyntaxSpan(themeKey: "string", range: NSRange(location: 1, length: 6))))
    #expect(spans.contains(SyntaxSpan(themeKey: "string", range: NSRange(location: 9, length: 6))))
}

@Test("SyntaxParsingActor parses Swift and maps the let keyword to its UTF-16 range")
func syntaxActorParsesSwiftKeyword() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)
    let actor = try #require(SyntaxParsingActor(configuration: configuration))

    let text = "let greeting = \"hi\""
    await actor.updateSnapshot(text, version: 1)
    let spans = await actor.tokens(
        inUTF16: NSRange(location: 0, length: (text as NSString).length))

    // `let` (@keyword) at offset 0..<3, and at least one string span.
    #expect(spans.contains(SyntaxSpan(themeKey: "keyword", range: NSRange(location: 0, length: 3))))
    #expect(spans.contains { $0.themeKey == "string" })
}

@Test("SyntaxParsingActor discards a stale lower-version snapshot")
func syntaxActorDiscardsStaleSnapshot() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .json)
    let actor = try #require(SyntaxParsingActor(configuration: configuration))

    await actor.updateSnapshot("{\"a\": 1}", version: 5)
    // An older version must not replace the newer parse tree.
    await actor.updateSnapshot("garbage {{{", version: 2)
    let spans = await actor.tokens(inUTF16: NSRange(location: 0, length: 8))

    #expect(spans.contains { $0.themeKey == "string" })
}

@Test("SyntaxParsingActor without a highlights query fails to initialize")
func syntaxActorRequiresHighlightsQuery() async throws {
    let registry = GrammarRegistry()
    // markdownInline has no vendored highlights.scm in 8a → empty queries.
    let configuration = try await registry.configuration(for: .markdownInline)
    #expect(configuration.queries[.highlights] == nil)
    #expect(SyntaxParsingActor(configuration: configuration) == nil)
}

@Test("SyntaxParsingActor returns no spans before the first snapshot")
func syntaxActorReturnsNoSpansBeforeParse() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .json)
    let actor = try #require(SyntaxParsingActor(configuration: configuration))

    let spans = await actor.tokens(inUTF16: NSRange(location: 0, length: 0))
    #expect(spans.isEmpty)
}

@Test("SyntaxParsingActor drops the tree for documents past the parse cap")
func syntaxActorHonorsParseCap() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .json)
    let actor = try #require(
        SyntaxParsingActor(configuration: configuration, maxParseUTF16Length: 4))

    await actor.updateSnapshot("{\"a\": 1}", version: 1)  // 8 UTF-16 units > cap
    let spans = await actor.tokens(inUTF16: NSRange(location: 0, length: 8))
    #expect(spans.isEmpty)
}

// MARK: - Incremental reparse (increment 8b)

/// Deterministic gate proof: an incremental single-character reparse reads far
/// fewer bytes than the whole document. Builds a large *nested* synthetic Swift
/// buffer (the shape of real source — tree-sitter reuses nested subtrees, so
/// the read stays local to the edit), takes a full-parse baseline, then applies
/// single-character edits and asserts each incremental reparse's instrumented
/// `bytesRead` is a small fraction of the document's byte length (`utf16 * 2`).
@Test("SyntaxParsingActor incremental reparse reads far fewer bytes than the whole document")
func syntaxActorIncrementalReadsNearEditOnly() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)
    let actor = try #require(SyntaxParsingActor(configuration: configuration))

    // ~400 KB (UTF-16) of nested Swift so subtree reuse is representative.
    let bigText = String(
        repeating: "func f() {\n    let a = compute(1, 2)\n    return a\n}\n",
        count: 4_000)
    await actor.updateSnapshot(bigText, version: 1)

    let baseline = try #require(await actor.lastReparseMetric)
    #expect(baseline.wasIncremental == false)
    // A full parse reads essentially the whole document.
    #expect(baseline.bytesRead >= baseline.docBytes / 2)

    var current = bigText
    var version = 1
    // Edit at several positions; each single-char insert must read ≪ docBytes.
    for fraction in [4, 2] {
        let insertAt = (current as NSString).length / fraction
        let mutable = NSMutableString(string: current)
        mutable.insert("x", at: insertAt)
        let newText = mutable as String
        version += 1

        await actor.applyEdit(
            startUTF16: insertAt,
            oldEndUTF16: insertAt,
            newEndUTF16: insertAt + 1,
            newText: newText,
            version: version
        )

        let metric = try #require(await actor.lastReparseMetric)
        #expect(metric.wasIncremental == true)
        #expect(metric.docBytes == (newText as NSString).length * 2)
        // The crux: reads near the edit only — an order of magnitude under the
        // whole document (in practice a single 2 KB chunk vs ~400 KB).
        #expect(metric.bytesRead * 20 < metric.docBytes)
        current = newText
    }
}

/// Correctness proof: a sequence of incremental edits yields exactly the spans a
/// full parse of the same final text produces. Tree-sitter guarantees the
/// edited tree equals a from-scratch parse, so highlight spans must match.
@Test("SyntaxParsingActor incremental result equals a full parse of the final text")
func syntaxActorIncrementalEqualsFullParse() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .swift)

    let initialText = "let name = 1"
    // Insert "s" after "name" (index 8): "let name = 1" -> "let names = 1".
    let finalText = "let names = 1"

    let incremental = try #require(SyntaxParsingActor(configuration: configuration))
    await incremental.updateSnapshot(initialText, version: 1)
    await incremental.applyEdit(
        startUTF16: 8,
        oldEndUTF16: 8,
        newEndUTF16: 9,
        newText: finalText,
        version: 2
    )
    let incrementalSpans = await incremental.tokens(
        inUTF16: NSRange(location: 0, length: (finalText as NSString).length))

    let full = try #require(SyntaxParsingActor(configuration: configuration))
    await full.updateSnapshot(finalText, version: 1)
    let fullSpans = await full.tokens(
        inUTF16: NSRange(location: 0, length: (finalText as NSString).length))

    #expect(sortedSpans(incrementalSpans) == sortedSpans(fullSpans))
    // Sanity: the parse actually produced the keyword and identifier spans.
    #expect(incrementalSpans.contains { $0.themeKey == "keyword" })
}

/// Growing past the cap via an incremental edit drops the tree; shrinking back
/// under it falls back to a full parse and highlights again.
@Test("SyntaxParsingActor incremental edits cross the parse cap in both directions")
func syntaxActorIncrementalHonorsCapBothWays() async throws {
    let registry = GrammarRegistry()
    let configuration = try await registry.configuration(for: .json)

    // Grow over the cap: a valid small doc parses, then an edit past the cap
    // drops the tree.
    let growing = try #require(
        SyntaxParsingActor(configuration: configuration, maxParseUTF16Length: 12))
    await growing.updateSnapshot("{\"a\":1}", version: 1)  // 7 units, under cap
    #expect(await growing.tokens(inUTF16: NSRange(location: 0, length: 7)).isEmpty == false)
    let overCap = "{\"aaaaaaaaaa\":1}"  // 16 units > cap
    await growing.applyEdit(
        startUTF16: 2, oldEndUTF16: 2, newEndUTF16: 11, newText: overCap, version: 2)
    #expect(await growing.tokens(inUTF16: NSRange(location: 0, length: 16)).isEmpty)

    // Shrink under the cap: an over-cap snapshot has no tree, then an edit that
    // brings it under the cap full-parses via the tree==nil fallback.
    let shrinking = try #require(
        SyntaxParsingActor(configuration: configuration, maxParseUTF16Length: 8))
    await shrinking.updateSnapshot("{\"aaaaaaaaaa\":1}", version: 1)  // 16 > cap
    #expect(await shrinking.tokens(inUTF16: NSRange(location: 0, length: 16)).isEmpty)
    let underCap = "{\"a\":1}"  // 7 units < cap
    await shrinking.applyEdit(
        startUTF16: 2, oldEndUTF16: 11, newEndUTF16: 2, newText: underCap, version: 2)
    let spans = await shrinking.tokens(inUTF16: NSRange(location: 0, length: 7))
    #expect(spans.contains { $0.themeKey == "string" })
}

/// Stable ordering for comparing two span sets independent of query iteration
/// order.
private func sortedSpans(_ spans: [SyntaxSpan]) -> [SyntaxSpan] {
    spans.sorted {
        if $0.range.location != $1.range.location {
            return $0.range.location < $1.range.location
        }
        if $0.range.length != $1.range.length {
            return $0.range.length < $1.range.length
        }
        return $0.themeKey < $1.themeKey
    }
}
