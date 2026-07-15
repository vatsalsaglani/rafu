import Foundation
import SwiftTreeSitter

/// First-party tree-sitter parsing/query actor for one open grammar buffer
/// (lane-1 increments 8a/8b). Chosen over Neon's `TreeSitterClient` (a
/// non-`Sendable` GCD class) so the parser and tree stay actor-confined and
/// only `Sendable` value types (`SyntaxSpan`, `ReparseMetric`) cross back to
/// the main actor — no `@unchecked Sendable`.
///
/// 8b makes reparsing incremental: each buffer mutation applies a tree-sitter
/// `InputEdit` to the retained `MutableTree` and reparses with the edited tree
/// as a hint, so tree-sitter's chunked read callback requests only chunks near
/// the edit instead of the whole document. `updateSnapshot` remains the
/// full-parse baseline used at grammar activation and full refresh; `applyEdit`
/// is the per-keystroke incremental path. The highlight query stays bounded by
/// Neon's visible-range look-ahead/behind (see `NeonSyntaxHighlightingPipeline`),
/// so no additional query narrowing lives here.
///
/// Concurrency invariants (mandated `swift-concurrency-pro` review, increment
/// 8):
///   - `Parser` and `MutableTree` are not `Sendable`; they never leave the
///     actor. Only `SyntaxSpan`/`ReparseMetric` values and the retained `String`
///     snapshot cross the boundary.
///   - `applyEdit` is atomic: it runs `tree.edit(_:)` and `parser.parse` with no
///     `await` in between, so no other actor call can observe a tree that was
///     edited but not yet reparsed. The pipeline delivers edits through a
///     non-cancelling serial chain, so `applyEdit` sees mutations in order and
///     never drops one (dropping an edit would desync the tree from `text`).
///   - `version` is a span-staleness *tag* on the incremental path, never a
///     gate: every edit is applied so the tree stays consistent with `text`.
///
/// The UTF-16 encoding path is used throughout: `Parser` defaults to UTF-16, a
/// tree-sitter byte offset is `utf16 * 2`, and query ranges come back as
/// UTF-16 `NSRange`s directly — no UTF-8 conversion.
actor SyntaxParsingActor {
    /// Last-reparse instrumentation exposed for the deterministic gate proof:
    /// the incremental read block counts only the bytes tree-sitter actually
    /// requested, which a benchmark test asserts is far below `docBytes`.
    /// Only counts/lengths are recorded — never document text.
    struct ReparseMetric: Sendable, Equatable {
        /// Bytes tree-sitter's read callback requested for the last reparse.
        let bytesRead: Int
        /// Total UTF-16 byte length of the document parsed (`utf16 * 2`).
        let docBytes: Int
        /// `true` for the incremental `InputEdit` path, `false` for a full parse
        /// (activation, full refresh, cap re-entry, or first edit).
        let wasIncremental: Bool
    }

    private let parser: Parser
    private let query: Query
    /// Most recent parse tree. `nil` before the first parse or when the
    /// document exceeds `maxParseUTF16Length`.
    private var tree: MutableTree?
    /// The text the current `tree` was parsed from. Retained because an
    /// incremental `InputEdit`'s `oldEndPoint` (row/column of the *replaced*
    /// text) must be computed from the pre-edit newline structure, which the
    /// post-edit string no longer carries. Byte offsets are authoritative
    /// regardless; the points are supplied for correctness. Cost: one document
    /// copy per live grammar buffer, bounded by `maxParseUTF16Length` and tab
    /// hibernation (`tearDown`).
    private var text = ""
    /// Highest snapshot version seen. On the full-parse baseline it gates stale
    /// snapshots; on the incremental path it is only a tag (see type doc).
    private var latestVersion = 0
    /// Upper bound (UTF-16 units) on documents parsed off-main, guarding
    /// typing latency and memory on very large buffers. Above it the actor
    /// drops its tree and `tokens(inUTF16:)` returns nothing, so the pipeline
    /// shows base style only.
    private let maxParseUTF16Length: Int
    /// Instrumentation for the last reparse; `nil` before the first parse.
    private(set) var lastReparseMetric: ReparseMetric?

    /// Fails when the configuration has no `highlights` query (the router then
    /// keeps the regex highlighter) or the parser rejects the language.
    init?(configuration: LanguageConfiguration, maxParseUTF16Length: Int = 2_000_000) {
        guard let query = configuration.queries[.highlights] else { return nil }
        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return nil
        }
        self.parser = parser
        self.query = query
        self.maxParseUTF16Length = maxParseUTF16Length
    }

    /// Full reparse of `text` at `version` — the baseline used at grammar
    /// activation and full refresh. Discards the call if a newer snapshot was
    /// already parsed (`version` staleness), and drops the tree for documents
    /// past the guard cap. Retains `text` so a subsequent `applyEdit` can build
    /// a correct `InputEdit`.
    func updateSnapshot(_ text: String, version: Int) {
        guard version >= latestVersion else { return }
        latestVersion = version
        self.text = text

        let length = (text as NSString).length
        guard length <= maxParseUTF16Length else {
            tree = nil
            lastReparseMetric = nil
            return
        }
        performFullParse(text, byteLength: length * SyntaxByteOffset.bytesPerUTF16Unit)
    }

    /// Incremental reparse: apply one `InputEdit` to the retained tree and
    /// reparse with the edited tree as a hint. `newText` is the full post-edit
    /// document; tree-sitter reads it in chunks near the edit via an
    /// instrumented read block. UTF-16 offsets describe the edit *after* it was
    /// applied to storage (`oldEndUTF16` reconstructs the pre-edit end from the
    /// storage delegate's `changeInLength`).
    ///
    /// Atomic and never dropped: `version` only tags staleness; every edit is
    /// applied so `tree` stays consistent with `text`. Falls back to a full
    /// parse when there is no prior tree (first edit, or the document was over
    /// the cap and shrank back under it), and drops the tree when `newText`
    /// exceeds the cap.
    func applyEdit(
        startUTF16: Int,
        oldEndUTF16: Int,
        newEndUTF16: Int,
        newText: String,
        version: Int
    ) {
        latestVersion = version

        let newLength = (newText as NSString).length
        guard newLength <= maxParseUTF16Length else {
            tree = nil
            text = newText
            lastReparseMetric = nil
            return
        }

        let byteLength = newLength * SyntaxByteOffset.bytesPerUTF16Unit
        guard let editedTree = tree else {
            performFullParse(newText, byteLength: byteLength)
            return
        }

        let oldText = text
        let inputEdit = InputEdit(
            startByte: SyntaxByteOffset.byteOffset(forUTF16Offset: startUTF16),
            oldEndByte: SyntaxByteOffset.byteOffset(forUTF16Offset: oldEndUTF16),
            newEndByte: SyntaxByteOffset.byteOffset(forUTF16Offset: newEndUTF16),
            startPoint: SyntaxByteOffset.point(forUTF16Offset: startUTF16, in: oldText),
            oldEndPoint: SyntaxByteOffset.point(forUTF16Offset: oldEndUTF16, in: oldText),
            newEndPoint: SyntaxByteOffset.point(forUTF16Offset: newEndUTF16, in: newText)
        )
        editedTree.edit(inputEdit)

        var bytesRead = 0
        let base = Parser.readFunction(for: newText)
        let signposter = SyntaxSignpost.signposter
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(
            "parse", id: id,
            "mode=incremental editByte=\(SyntaxByteOffset.byteOffset(forUTF16Offset: startUTF16)) docBytes=\(byteLength)"
        )
        tree = parser.parse(tree: editedTree) { offset, point in
            let chunk = base(offset, point)
            bytesRead += chunk?.count ?? 0
            return chunk
        }
        signposter.endInterval("parse", state, "bytesRead=\(bytesRead)")

        text = newText
        lastReparseMetric = ReparseMetric(
            bytesRead: bytesRead, docBytes: byteLength, wasIncremental: true)
    }

    /// Highlight spans intersecting the UTF-16 `range`, mapped to
    /// `RafuTheme.syntax` keys. Returns `[]` before the first successful
    /// parse. The query is bounded to `range` via `cursor.setRange`; the
    /// pipeline only ever asks for the visible range plus Neon's look-ahead/
    /// behind, so no extra narrowing is needed here.
    func tokens(inUTF16 range: NSRange) -> [SyntaxSpan] {
        guard let tree else { return [] }

        let signposter = SyntaxSignpost.signposter
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("query", id: id, "range=\(range.length)")

        let cursor = query.execute(in: tree)
        cursor.setRange(range)

        var spans: [SyntaxSpan] = []
        for namedRange in cursor.highlights() {
            guard let key = CaptureTokenMap.themeKey(forCapture: namedRange.name) else { continue }
            spans.append(SyntaxSpan(themeKey: key, range: namedRange.range))
        }

        signposter.endInterval("query", state, "spans=\(spans.count)")
        return spans
    }

    /// Full parse via an instrumented chunked read block so the baseline path
    /// records the same `ReparseMetric` shape as the incremental path (its
    /// `bytesRead` spans the whole document). Sets `tree` and `text` together
    /// so they never diverge.
    private func performFullParse(_ text: String, byteLength: Int) {
        var bytesRead = 0
        let base = Parser.readFunction(for: text)
        let signposter = SyntaxSignpost.signposter
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(
            "parse", id: id, "mode=full docBytes=\(byteLength)")
        tree = parser.parse(tree: nil as MutableTree?) { offset, point in
            let chunk = base(offset, point)
            bytesRead += chunk?.count ?? 0
            return chunk
        }
        signposter.endInterval("parse", state, "bytesRead=\(bytesRead)")

        self.text = text
        lastReparseMetric = ReparseMetric(
            bytesRead: bytesRead, docBytes: byteLength, wasIncremental: false)
    }
}
