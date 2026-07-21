# Diff syntax highlighting + new-side-only hover

- Applies to: `Sources/RafuApp/Editor/Syntax/PlainTextSyntaxHighlighter.swift`,
  `Sources/RafuApp/Git/DiffSyntaxHighlighter.swift`,
  `Sources/RafuApp/Git/DiffHoverPositionMapper.swift`,
  `Sources/RafuApp/Views/EditorCanvasView.swift` (`GitSideBySideDiffView`,
  `GitDiffCell`), `Sources/RafuApp/Models/WorkspaceSession.swift`
  (`diffHoverInfo`)
- Last verified: Swift 6.2 / macOS 26, 2026-07-20

## Rule or observed behavior

1. **Highlight per SIDE, never per line.** A single diff row's text (one
   `oldLine`/`newLine`) is frequently a syntactically incomplete fragment
   (unclosed string/brace); parsing it alone mis-highlights. The working
   pattern: join a side's line contents in row order with `"\n"`, run one
   tree-sitter parse+query pass over the joined string, then slice the
   resulting UTF-16 spans back onto their originating line by clipping each
   span to `[lineStart, lineStart + lineLength)`. A span that crosses a `"\n"`
   join (e.g. a multi-line string literal) is intentionally split across
   every line it touches. Joining across a hunk gap is accepted as cosmetic
   — tokens rarely survive the gap — and this never reconstructs the full
   file. Two parses total per opened diff (old + new), gated by a per-side
   UTF-16 length cap (100,000) above which that side falls back to plain,
   unhighlighted rendering instead of parsing on a scroll-adjacent path.

2. **Query loading is main-actor-bound, so the shared parse core must accept
   a pre-resolved `Language`+`Query`, not a language ID.** `PlainTextSyntaxHighlighter.spans(text:language:highlightsQuery:)`
   is `nonisolated` and synchronous by design: it does one `Parser.parse` +
   `query.execute` pass and classifies captures via `CaptureTokenMap`, with
   no theming and no actor hop baked into its signature. This lets both a
   `@MainActor` caller (Markdown fence highlighting, which loads its query
   through `Bundle.module`, itself main-actor-isolated) and an off-main
   `@concurrent` caller (`DiffSyntaxHighlighter.highlights(for:)`, which
   resolves the grammar via the off-main `GrammarRegistry` actor) call it
   directly. A single `spans(for:languageID:)`-shaped API that resolved the
   grammar itself would be impossible without forcing every caller onto one
   actor or the other.

3. **`Range<AttributedString.Index>(nsRange, in:)` is the correct UTF-16 →
   `AttributedString` conversion for spans measured in UTF-16 (`NSRange`).**
   `GitDiffCell.attributedContent` uses this failable initializer to apply
   token foreground colors from `SyntaxSpan.range` (UTF-16, `NSRange`); it
   is UTF-16-symmetric and emoji/CJK-safe by construction, and a failed
   conversion (out-of-bounds or invalid boundary) is guarded and simply
   skips that one span — worst case a token renders in the default color,
   never a crash or corrupted range. This is deliberately different from the
   adjacent intraline changed-word highlighting in the same view, which
   uses `text.index(text.startIndex, offsetByCharacters:)` because
   `IntralineDiff.changedSpan` is measured in `Character` counts, not UTF-16
   — do not mix the two conversions for a span from a different coordinate
   space.

4. **Hover is LSP-only everywhere in Rafu; there is no tree-sitter hover
   fallback.** `NavigationLadder.resolve` declines `.hover` requests before
   consulting non-LSP providers (`NavigationLadder.swift:64`,
   `guard request.kind != .hover else { return nil }`), and
   `SyntacticNavigationProvider`'s request-kind switch never handles
   `.hover` at all. Only `LSPNavigationProvider` answers `.hover`. Any
   future hover surface (this diff-canvas hover included) therefore
   inherits two hard constraints: (a) it only ever produces an answer when
   an LSP server is running and trusted for that language (ADR 0005's
   opt-in model — no answer is a legitimate common case, not a bug), and
   (b) it requires an LSP document mirror — a file that has never been
   opened in the editor (so never `didOpen`-synced to the server) has no
   hover until it is opened once. `WorkspaceSession.diffHoverInfo` does not
   add a new `didOpen` path to work around this; it is documented,
   deliberate behavior, not a TODO.

5. **Monospace column hit-test pattern.** `GitDiffCell` estimates a hover's
   character column from pointer x-offset via
   `column ≈ (pointerX / advance).rounded()`, where `advance` is
   `("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width`
   computed once as a `static let`, not per hover event — valid only
   because the diff cell's content font is a fixed
   `.system(size: 12, design: .monospaced)`. The estimated column is
   clamped to the line's UTF-16 length, then resolved to a word via
   `IdentifierUnderCaret.word(in:at:)`; a miss (no identifier under the
   estimated column) suppresses the hover rather than showing wrong info.
   Debounce is 350 ms, matching the editor's own `RafuTextView.hoverDelay`,
   and is cancelled both on `.onContinuousHover`'s `.ended` phase and on
   `.onDisappear` (a `LazyVStack` row scrolling out of view does not
   naturally fire a hover-exit event, so both cancellation paths are
   required).

6. **`.task(id:)` stale-assignment guard for a superseded async cache
   compute.** `GitSideBySideDiffView` caches `DiffSyntaxHighlighter.highlights(for:)`
   in local `@State`, recomputed via `.task(id: openDiff.id)`. SwiftUI's
   `.task(id:)` cancels the prior task when the id changes but does not
   await its completion, so a slow parse for a since-replaced diff can
   finish and assign after a newer task has already started. The fix is a
   `Task.isCancelled` check immediately before the `@State` assignment
   (both `lineIndexMap` and `highlights` are written together, guarded by
   the same check, to keep them mutually consistent for one diff). Any
   `.task(id:)`-driven cache compute in this codebase should apply the same
   guard.

## Why it matters

The join-then-slice highlighting strategy and the pre-resolved-Language/Query
seam are the reusable shape for highlighting *any* partial-file text (not
just diffs) against the existing tree-sitter boundary without inventing a
second parse pipeline. The `Range(nsRange, in:)` vs `offsetByCharacters`
distinction is a recurring off-by-one trap whenever UTF-16-measured spans
(tree-sitter, LSP) meet `Character`-measured spans (Swift-native diff
algorithms) in the same `AttributedString`. The LSP-only hover constraint is
load-bearing for every future hover-adjacent feature: it means "no hover
appeared" is frequently correct behavior (no server, no trust, no sync), not
a defect to chase.

## Reproduction or evidence

- `Sources/RafuApp/Editor/Syntax/PlainTextSyntaxHighlighter.swift` (shared
  parse core, doc comments explain the actor-isolation rationale in detail).
- `Sources/RafuApp/Git/DiffSyntaxHighlighter.swift` (`sideHighlights`, the
  join/slice implementation and the 100,000-UTF-16-unit cap).
- `Sources/RafuApp/Views/EditorCanvasView.swift:1399-1427` (`attributedContent`
  — `Range<AttributedString.Index>(span.range, in: text)` for token color vs.
  `offsetByCharacters` for the intraline changed-word background).
- `Sources/RafuApp/Views/EditorCanvasView.swift:1054-1066` (`.task(id:)`
  `Task.isCancelled` guard before `highlights`/`lineIndexMap` assignment).
- `Sources/RafuApp/Navigation/NavigationLadder.swift:64` (`.hover` declined
  before non-LSP providers run); `Sources/RafuApp/Navigation/SyntacticNavigationProvider.swift`
  (no `.hover` case in its request-kind switch).
- `Sources/RafuApp/Models/WorkspaceSession.swift:905-946` (`diffHoverInfo`
  — path/scope/dirty gating, `DiffHoverPositionMapper.utf16Offset`, then the
  same `NavigationRequest`/`NavigationLadder` path as editor hover).

## Verification

- `swift test --filter PlainTextSyntaxHighlighterTests`
- `swift test --filter DiffSyntaxHighlighterTests`
- `swift test --filter DiffHoverPositionMapperTests`
- `swift test --filter WorkspaceDiffHoverTests`
- `swift test` and `swift test --no-parallel` — 876 tests, both green, as
  reported by the implementor handoff (2026-07-20).
- `./script/format.sh --lint` — clean.
- `./script/build_and_run.sh --verify` — clean stage + launch confirmed by
  the implementor; the interactive GUI checklist (hover card
  appearance/dismissal, old-side/history-scope suppression, large-diff
  scroll smoothness, theme-switch recolor without reparse) is still owed a
  manual pass per the phase doc status.

## Related code, ADRs, and phases

- Phase: [`docs/plans/phases/diff-syntax-highlighting-and-hover.md`](../plans/phases/diff-syntax-highlighting-and-hover.md)
- Phase: [`docs/plans/phases/pre-initial-push-workbench.md`](../plans/phases/pre-initial-push-workbench.md)
- ADR: [`0005-language-intelligence-and-lsp.md`](../decisions/0005-language-intelligence-and-lsp.md) —
  opt-in LSP client (this work stays inside that boundary; no new ADR)
- Reference: [`tree-sitter-highlighting.md`](tree-sitter-highlighting.md)
- Reference: [`navigation-and-lsp-contracts.md`](navigation-and-lsp-contracts.md)
- Reference: [`editor-dependencies.md`](editor-dependencies.md)
