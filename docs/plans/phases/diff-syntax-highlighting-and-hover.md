# Diff syntax highlighting + new-side hover

Status: Implemented (2026-07-20). Diff canvas syntax highlighting (both
columns, parsed per side, cached per opened diff, theme-independent spans
resolved to colors at render time) and new-side-only hover (working-tree-
scoped diffs, non-dirty file, LSP-only via the existing `NavigationLadder` —
no tree-sitter hover fallback exists) shipped with 20 new tests (876 total,
`swift test` and `swift test --no-parallel` both green, 0 build warnings,
`./script/format.sh --lint` clean). LSP document-sync caveat carried
forward from `hoverInfo(at:utf16Offset:)`: a closed file has no synced
mirror, so its hover doesn't appear until opened once — documented, not
worked around. Interactive GUI checklist (hover card appearance/dismissal,
old-side and history-scope hover suppression, 1,000+ line diff scroll
smoothness, theme-switch recolor without reparse) still owed a manual pass;
`./script/build_and_run.sh --verify` confirmed a clean stage + launch.
Prepared 2026-07-20 against `main` (853 tests, 0 warnings baseline; the
runtime-measured baseline immediately before this work was 856 tests).
Advisor read-only review approved the implementation; one hardening item
from that review landed before handoff: the `.task(id:)` diff-highlight
cache assignment in `GitSideBySideDiffView` is now guarded by
`Task.isCancelled` so a superseded parse can't briefly overwrite a newer
diff's spans (see the `diff-syntax-highlighting-and-hover.md` reference
note).

## Goal

The editor-hosted diff canvas renders every line as monochrome text. This
phase adds:

1. **Syntax highlighting** of diff content in both columns, using the
   existing tree-sitter grammar boundary — token colors from the active
   theme, layered UNDER the existing intraline changed-word backgrounds.
2. **Hover (declarations/types) on the NEW side only.** The old side never
   gets hover — that text may not exist on disk, so any LSP answer about it
   would be a guess. This is a deliberate product decision, not a deferral.

## Non-goals

- Hover on the old/left column, in any form.
- Hover on history/commit-scoped diffs (`GitDiffScope != .workingTree`) —
  the on-disk file may not match the diff's new side there either.
- Go-to-definition / find-references from the diff (hover only).
- Any new dependency, extension host, or always-on language server
  (AGENTS.md invariants; ADR 0005 opt-in LSP unchanged).

## Existing machinery to reuse (verified symbols)

| What | Where |
|---|---|
| Diff models: `GitFileDiff`, `GitDiffHunk` (`newStart`/`oldStart`), `GitDiffRow`, `GitDiffLine` | `Sources/RafuApp/Models/GitModels.swift:173-220` |
| Diff canvas: `diffTable`, `GitSideBySideDiffRow`, `GitDiffCell` (builds one plain `AttributedString` per line + intraline `IntralineDiff.changedSpans` backgrounds) | `Sources/RafuApp/Views/EditorCanvasView.swift:~1045-1290` |
| Open-diff state: `GitOpenDiff` (`diff`, `scope`), `WorkspaceSession.gitOpenDiff` | `Sources/RafuApp/Git/GitWorkbenchModels.swift:17`, `WorkspaceSession.swift:106` |
| String-level tree-sitter highlighter (not tied to NSTextStorage): `MarkdownCodeSyntaxHighlighter.highlightedAttributedString(...)` — grammar query pass over a plain string, themed output | `Sources/RafuApp/Markdown/MarkdownCodeSyntaxHighlighter.swift:53-110` |
| Grammar/language plumbing: `GrammarRegistry`, `LanguageCatalog`, `SyntaxSpan`, `CaptureTokenMap`, `SyntaxParsingActor` | `Sources/RafuApp/Editor/Syntax/` |
| Hover model + card content: `EditorHoverInfo`, `HoverMarkdownParser` | `Sources/RafuApp/Editor/EditorHoverInfo.swift`, `LanguageIntelligence/HoverMarkdownParser.swift` |
| Hover resolution ladder: `WorkspaceSession.hoverInfo(at:utf16Offset:)` → `NavigationRequest` → LSP `LanguageServerSession.hover(uri:utf16Offset:)` with tree-sitter fallbacks | `WorkspaceSession.swift:839`, `LanguageIntelligence/LSP/LanguageServerSession.swift:381` |
| Editor hover wiring today (for reference only): `CodeEditorView` `textView.hoverAction` → `session.hoverInfo` | `CodeEditorView.swift:130`, `EditorCanvasView.swift:161-165` |

## Part A — syntax highlighting in the diff canvas

### A1. Extract a shared plain-string highlighter

Factor the grammar-query core of
`MarkdownCodeSyntaxHighlighter.highlightedAttributedString` into a shared
`nonisolated` helper (suggested: `Sources/RafuApp/Editor/Syntax/PlainTextSyntaxHighlighter.swift`)
with an API shaped like:

```swift
nonisolated struct PlainTextSyntaxHighlighter {
    /// Token spans for `text` in `language`, resolved through
    /// GrammarRegistry; nil when no grammar exists. Pure given a grammar;
    /// heavy — never call on the main actor for diff-sized input.
    static func spans(for text: String, languageID: String) -> [SyntaxSpan]?
}
```

`MarkdownCodeSyntaxHighlighter` becomes a consumer of the shared core
(behavior-preserving refactor; its 5 existing tests must stay green
unmodified). Keep theming OUT of this layer — it returns capture-classified
spans; color resolution stays with the caller so diff and Markdown can style
independently.

### A2. `DiffSyntaxHighlighter` (new, `Sources/RafuApp/Git/DiffSyntaxHighlighter.swift`)

- Input: `GitFileDiff` + language ID resolved from `diff.path`'s extension
  via `LanguageCatalog` (same resolution the editor uses).
- **Parse per SIDE, not per line**: single lines mis-parse (unclosed
  strings/braces). For each side, join that side's line contents
  (`rows.compactMap(\.oldLine)` / `\.newLine` in order, newline-separated)
  into one string per file diff, run one grammar pass per side, then slice
  the resulting spans back into per-line span arrays. Two parses per diff
  total.
- Hunk boundaries: joining across hunk gaps is acceptable — tokens rarely
  survive the gap, and a wrong color on a truncated construct is cosmetic.
  Do NOT try to reconstruct the full file text.
- Output: `struct DiffSideHighlights: Sendable { let linesToSpans: [[SyntaxSpan]] }`
  per side, index-aligned with the joined line order (document the mapping:
  the Nth non-nil oldLine/newLine in `diff.rows` order).
- Concurrency: run off the main actor (reuse `SyntaxParsingActor` if its API
  fits, otherwise a `@concurrent` static). Cancellable. AGENTS: syntax
  parsing never blocks typing or scrolling.
- Caching: compute once per opened diff, keyed by `GitOpenDiff.id`; store
  the result in the diff canvas's local `@State` (NOT in `WorkspaceSession`
  — it is ephemeral view data). Recompute on theme change only if you bake
  colors in; preferred: cache spans (theme-independent) and resolve colors
  at render time so theme switches are free.
- Fallback: `nil` spans (no grammar / cancelled) → today's plain rendering,
  unchanged.

### A3. Wire into `GitDiffCell`

- `GitSideBySideDiffRow`/`GitDiffCell` gain an optional per-line
  `[SyntaxSpan]` parameter.
- In `attributedContent`, apply token foreground colors first (map capture
  names → theme colors via the same token-color mapping the editor theme
  uses — see `EditorThemeColors.swift` / `CaptureTokenMap`), THEN the
  existing intraline changed-word `backgroundColor` spans on top. Foreground
  and background never conflict; deletions/additions keep their row tint.
- Span offsets are in the highlighter's coordinate space (UTF-8 or UTF-16 —
  match whatever `SyntaxSpan` already uses; convert carefully to
  `AttributedString` character indices; multi-byte characters are the
  off-by-one trap, see tests).
- No layout/parse work in `body`: the view only indexes into the precomputed
  cache.

## Part B — hover on the NEW side only

### B1. Gating (all conditions required)

Hover requests fire only when:
1. The hovered cell is the **new column** (`GitDiffCell` `side == .new`) and
   the row actually has a `newLine`.
2. `session.gitOpenDiff?.scope == .workingTree` — the new side then
   corresponds to the file on disk / in the open buffer.
3. The file's open `EditorDocument` (if any) is **not dirty** — unsaved
   edits shift line numbers; suppressing beats lying (same rule inline
   blame follows).
4. Language intelligence is available for the language (the existing ladder
   handles LSP-vs-tree-sitter fallback internally; no new capability checks
   in the view).

### B2. Position mapping (pure, unit-tested)

New type (suggested: `Sources/RafuApp/Git/DiffHoverPositionMapper.swift`):

```swift
nonisolated enum DiffHoverPositionMapper {
    /// The 1-based file line for a hovered new-side row: the hunk's
    /// `newStart` advanced by the count of preceding rows IN THAT HUNK that
    /// carry a newLine (context/addition/modification rows; deletion-only
    /// rows do not advance the new side). GitDiffLine.number should already
    /// equal this — assert equivalence in tests, but derive from the hunk
    /// so the mapper never trusts render-side state.
    static func newSideLocation(row: GitDiffRow, in hunk: GitDiffHunk) -> Int?

    /// UTF-16 offset of (line, utf16Column) in a full-file text snapshot;
    /// nil when the snapshot's line count/width disagrees with the diff
    /// (file changed since the diff was captured → suppress hover).
    static func utf16Offset(line: Int, utf16Column: Int, in text: String) -> Int?
}
```

The column comes from the hovered character index within the cell's `Text`
(SwiftUI can't give a per-character hover index cheaply — see B3 for the
pragmatic approach).

### B3. Hover capture in the cell

Pragmatic v1: per-word, not per-character. In `GitDiffCell` (new side only),
render the content as today but attach a hover recognizer to the cell; on
hover, hit-test the pointer's x-offset into the monospaced string
(`column ≈ (pointerX - contentLeadingInset) / monospacedAdvance` — the font
is fixed `.system(size: 12, design: .monospaced)`, so the advance is
constant and computable once via `NSFont` metrics; this is why v1 does NOT
need TextKit here). Clamp to the line length; resolve the word under that
column with `IdentifierUnderCaret.word(in:at:)` against the line content.
Debounce ~350 ms of stable pointer rest before requesting; cancel the
in-flight task on exit/move (hover must never block scroll — AGENTS).

### B4. Session entry point

`WorkspaceSession.hoverInfo(at:utf16Offset:)` currently guards
`document == selectedDocument` — the diff canvas is NOT the selected
document, so add a sibling (do not loosen the existing one):

```swift
/// Hover for the NEW side of the open working-tree diff. Reads the
/// file's CURRENT text (open document snapshot if the file is open and
/// clean, else fileService.readText), maps (line, column) → utf16 offset
/// via DiffHoverPositionMapper, and resolves through the SAME
/// NavigationRequest ladder as editor hover.
func diffHoverInfo(path: String, line: Int, utf16Column: Int) async -> EditorHoverInfo?
```

Guards inside: workspace root present, gitOpenDiff matches `path`, scope ==
workingTree, open-document-dirty suppression (B1.3), mapper returned an
offset. LSP document-sync caveat: if the file is NOT open in the editor,
the server may have no synced document — pass through whatever the existing
`NavigationRequest` ladder does for closed files (it already handles
navigation for non-open files via the workspace index / transient open; do
NOT invent a new didOpen path in this phase — if the ladder returns nil for
closed files, hover simply doesn't appear until the file is opened once, and
that limitation is documented in the exit notes).

### B5. Hover presentation

New small SwiftUI view (suggested: `DiffHoverCard` in the diff area of
`EditorCanvasView.swift` or its own file) presenting `EditorHoverInfo` via
`HoverMarkdownParser` — visually consistent with the editor's hover card
(reuse fonts/`RafuMetrics`/palette; check the editor's existing hover
presentation in `RafuTextView`/`EditorHoverInfo.swift` and mirror it).
Present as a `.popover`/overlay anchored to the hovered cell. Dismiss on
scroll, pointer exit, or Escape. Reduce Motion: no animated entrance.
Accessibility: the card content is real text; the hovered cell keeps its
existing `accessibilityText`.

## New tests (Swift Testing, `Tests/RafuAppTests/`)

**`PlainTextSyntaxHighlighterTests.swift`** (new)
1. Swift snippet → non-nil spans classifying a keyword, string, and comment.
2. Unknown language ID → nil.
3. Refactor guard: existing `MarkdownCodeSyntaxHighlighterTests` (5 tests)
   pass unchanged.

**`DiffSyntaxHighlighterTests.swift`** (new)
4. Side-joining: a two-hunk diff yields per-line span arrays index-aligned
   with the rows that carry a line on that side (deletion-only rows absent
   from new side, addition-only rows absent from old side).
5. A string literal spanning two visible lines colors both lines' slices.
6. Multi-byte content (emoji/CJK) — span slicing produces valid
   `AttributedString` ranges (no crash, correct boundaries).
7. Binary diff (`isBinary`) and empty diff → empty result, no parse.
8. Unknown extension → nil/plain fallback.

**`DiffHoverPositionMapperTests.swift`** (new)
9. `newSideLocation`: context, addition, and modification rows advance the
   new-side line; deletion rows do not; result equals `newLine.number`
   across a crafted multi-hunk diff.
10. Old-side/deletion-only row → nil.
11. `utf16Offset`: maps (line, column) correctly across multi-byte lines;
    column past end-of-line clamps/declines per the chosen contract.
12. Snapshot/diff disagreement (line beyond snapshot's line count) → nil.

**`WorkspaceDiffHoverTests.swift`** (new)
13. `diffHoverInfo` returns nil when: no open diff, path mismatch, scope ==
    history, or the open document is dirty (each its own test).
14. Gating never fires the navigation ladder in those cases (inject/spy via
    whatever seam `navigationLadder` already offers; if none exists cheaply,
    assert the nil result only and note it).

Also update `EditorCanvasView`-level expectations only if any existing test
touches `GitDiffCell` (none known today).

## Verification gates (all must pass before handoff)

1. `swift build` — 0 warnings.
2. `swift test` AND `swift test --no-parallel` — baseline 853 + new tests,
   all green (serial mode is what CI runs; see
   `docs/references/cli-app-ipc.md` for why).
3. `./script/format.sh --fix` then `--lint` clean; re-run build+test after.
4. `./script/build_and_run.sh` launch pass: open a Swift file's working-tree
   diff → tokens colored in both columns, intraline word highlights still
   visible on modifications; hover a symbol on the new side → card appears
   after the debounce; old side never shows hover; History-scoped diff never
   shows hover; scrolling stays smooth on a 1,000+ line diff (no hitching —
   if in doubt, Instruments/signpost per AGENTS performance rules).
5. Theme switch while a diff is open recolors without re-parsing (if spans
   are cached theme-independent) — verify no visible stall.

## Risks / traps

- **Span coordinate space vs `AttributedString` indices** — the classic
  multi-byte off-by-one. Convert deliberately; tests 6 and 11 exist for this.
- **Parse cost on huge diffs** — bound the highlighted content (e.g. skip
  highlighting when a side exceeds ~200 KB, falling back to plain); log
  nothing about content.
- **Hover column estimation** drift with non-monospace glyph clusters
  (emoji) — acceptable v1: identifier resolution via
  `IdentifierUnderCaret` snaps to the word, and a miss shows nothing rather
  than wrong info.
- **LSP answers for files the server hasn't synced** — see B4; suppressed,
  not worked around, in this phase.
- Do not touch `GitInspectorView` sections owned by other features; diff
  rendering lives in `EditorCanvasView.swift`.
- AGENTS: never store diff text in observable session state beyond what
  `GitOpenDiff` already holds; no `@unchecked Sendable`; state never
  color-only (hover availability is discoverable by pointing, and the card
  is text — no color-coded-only signals).

## Documentation on completion (standing learning rule)

- Reference note if the span-slicing or hover-mapping work surfaces a
  reusable nuance (likely: the side-join slicing strategy and the
  monospace-column hover hit-test).
- Update this phase doc's status + the phase README row.
- No ADR expected (stays inside ADR 0005's opt-in LSP and the approved
  tree-sitter boundary); add one only if the implementation forces a durable
  deviation.
