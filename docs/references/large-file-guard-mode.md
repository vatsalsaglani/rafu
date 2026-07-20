# Large-file guard mode

- Applies to: editor document open, syntax highlighting suppression, symbol scanning
- Last verified: Swift 6.2, macOS 14+, Xcode 16, 2026-07-15

## Rule or observed behavior

When a document is opened, `DocumentGuardPolicy.decide(for:)` evaluates two thresholds:

- **Maximum unguarded file size**: 2 MB (2,097,152 bytes)
- **Maximum unguarded line length**: 10,000 UTF-16 code units

If either threshold is exceeded, the document enters guarded mode. In guarded mode:

- No syntax highlighting is applied (base text style only)
- The `@`-symbol scan (`CommandPaletteView.prepareSymbolsIfNeeded`) is skipped
- No per-keystroke tokenization work runs (`NeonSyntaxHighlightingPipeline.isSuppressed`)
- An in-editor banner prompts the user to enable highlighting (session-only override button)

The policy computation runs **once at document open** off the main actor (inside the existing cancellation-checked load Task), never recomputed per keystroke or paste event.

## Why it matters

Guarded mode prevents parsing workload from blocking the editor's main-actor typing path on large files. The 2 MB threshold is carefully chosen to guard the 2–4 MB band of files that are still openable (the `WorkspaceFileService.readText` hard-rejects files > 4 MB), ensuring guard mode actually engages for files that would otherwise incur syntax overhead without violating the hard-close cap. The 10,000 UTF-16 limit catches minified or procedurally generated single-line files that would otherwise tokenize wastefully.

## Reproduction or evidence

- `Sources/RafuApp/Editor/DocumentGuardPolicy.swift` — pure `nonisolated` type with `decide(for:)` async concurrent function
- Single chokepoint for suppression: `NeonSyntaxHighlightingPipeline.isSuppressed` (bool flag; when true, base style is applied then tokenization is skipped in both initial `invalidate(.all)` and per-edit `didProcessEditing`)
- `CodeEditorView.Coordinator.syncGuardSuppression(forceRepaint:)` — must force a repaint on load (bare on-change-only sync would skip the always-needed load-time highlight when the guard flag equals its default, silently breaking highlighting-on-open for normal files); `updateNSView` calls it without forcing so a banner override is picked up on the next update pass
- Banner with one-click "Enable Highlighting" override in `EditorCanvasView` area; override is session-only and does not persist to disk

## Verification

Tested via `DocumentGuardPolicyTests` (10 tests, all passing):
- Thresholds correctly classify small, medium, large, and edge-case files
- One-line minified case (single 10,001-character line) correctly triggers guard
- Classic Mac line-ending case (lone `\r` scanned as one line) conservatively guards
- Guard state computed once at open, not recomputed on keystroke

App-level verification: `./script/build_and_run.sh --verify` confirmed UI banner displays and override button functions; highlighting toggles correctly on small files and remains suppressed on guarded files.

## Related code, ADRs, and phases

- **Code**: `Sources/RafuApp/Editor/DocumentGuardPolicy.swift`, `Sources/RafuApp/Editor/CodeEditorView.swift` (Coordinator), `Sources/RafuApp/Views/CommandPaletteView.swift` (prepareSymbolsIfNeeded gate), `Sources/RafuApp/Views/EditorCanvasView.swift` (banner host)
- **Deviation**: The lane-1 phase plan proposed an 8 MB threshold, but `WorkspaceFileService.readText` already hard-rejects files > 4 MB (`maximumEditorBytes`), so an 8 MB guard would be dead code. Threshold finalized at 2 MB to engage in the openable band.
- **Known limitations**:
  1. Pasting a huge line into an already-open normal document does not retroactively guard it; guard mode engages at open only with an explicit session-only override.
  2. Files with lone-`\r` (classic Mac) line endings scan as one line, conservatively triggering the line-length guard.
  3. Markdown opened directly in preview-only mode has no `CodeEditorView`, so guard state stays `.normal` and no banner is shown.
- **Symbol index reuse**: Increment 10 (`WorkspaceSymbolIndex`) reads the same `document.suppressesSyntax` flag to skip guarded files from the index.
- **Deferred**: A dedicated menu/command-palette "Enable Highlighting for this file" override command; the banner Button is the sufficient keyboard-reachable path this increment (accessible via Full Keyboard Access, not hidden behind a gesture).
- **Lane**: Lane 1, Increment 2 — memory resilience + Tree-sitter Stages A/B

## Bounded indent-guide line scan (post-fan-out fix, 2026-07-18)

A production stackshot (v0.1.1-beta, 31 s unresponsive, 13/13 samples in
`RafuTextView.drawIndentGuides` → `NSString.lineRangeForRange`) showed
that indent-guide drawing was visible-rect-bounded in glyph space but not
in string space: `lineRange(for:)` walks to a line's TRUE start/end, which
is O(document) per visible line fragment on single-giant-line content
(e.g. minified JSON) — and `glyphRange(forCharacterRange:)` then forces
layout of the whole mega-line, every draw. The guard mode's line-length
check protects at open time but not against every path (e.g. thresholds
tuned to bytes, or content arriving via paste).

Rule: drawing-path code must never call `NSString.lineRange(for:)` (or
similar whole-line walks) unbounded. `drawIndentGuides` now uses
`boundedLineRange(around:in:)` — newline searches capped at
`maxIndentGuideLineScan = 4096` UTF-16 units in each direction; a line
whose boundary exceeds the cap draws no guides and ends the pass (its
indentation is off-screen and meaningless anyway). Regression:
`indentGuideLineScanBounded` (same test file as above).

## Two more draw sites bounded; the scan is linear, not quadratic (2026-07-20)

Two remaining unbounded `NSString.lineRange(for:)` draw-path call sites
were found and fixed alongside the macOS 26 Writing Tools hang (see
[`macos26-writing-tools-textkit-layout.md`](macos26-writing-tools-textkit-layout.md)
for that unrelated but co-discovered issue): `RafuTextView.drawCurrentLineHighlight`
and `RafuTextView.drawInlineBlameAnnotation` both now call the existing
`boundedLineRange(around:in:)` (same 4096-unit cap), matching
`drawIndentGuides`/`drawFileBlameAnnotations`. In
`drawInlineBlameAnnotation`, `inlineBlameRect` is reset to `.zero` when the
bounded lookup declines (returns `nil`), so a stale rect from a previous
draw can never leave the GX2 inline-blame hover hit-test (`hitTest`/mouse
handling reads `inlineBlameRect`) pointing at geometry that was never
actually drawn this pass.

**Measured, not assumed: `NSString.lineRange(for:)` is linear, not
quadratic.** Implementor measurement put it at roughly 500–570M UTF-16
units/second on `NSTextStorage`-backed content — a single unbounded call
on a 2 MB line costs about 3.5 ms. The original 31–32 s hang recorded in
`error-report.txt` (v0.1.1-beta) was `drawIndentGuides` calling this
**repeatedly, once per visible line fragment, every draw** (already fixed
in commit `2495241`), not an inherent quadratic cost in the API itself.

This has a direct consequence for regression tests: a timing-ceiling test
(`elapsed < .seconds(N)`) cannot reliably catch a *reintroduced* single
unbounded `lineRange(for:)` call at practical document sizes, because that
single call is cheap. The reliable regression guard is a **deterministic
behavior assertion** that only holds if the bounded substitution actually
ran — e.g. `inlineBlameDrawClearsRectBeyondScanCap` asserts
`inlineBlameRect == .zero` after drawing a caret with no newline within
4096 units in either direction, which is only true if
`boundedLineRange(around:in:)` (not `lineRange(for:)`) was used. Prefer
this pattern over a timing bound when guarding a single bounded call site;
timing bounds remain appropriate for guarding *repeated-per-visible-line*
scans (as in `indentGuideLineScanBounded`/`manyLineDocumentDrawIsBounded`).

## `NSView.display()` is a silent no-op in headless `swift test` runs

There is no WindowServer session under `swift test`, so `NSView.display()`
returns without ever invoking `draw(_:)` — any draw-path test written
against `.display()` passes vacuously, exercising nothing. The reliable
headless alternative, used throughout `MultiCaretUndoDiagnosticTests.swift`
(`forceOffscreenDraw`) and `EditorGutterRenderTests.swift`, is:

```swift
guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
view.cacheDisplay(in: rect, to: rep)
```

This forces a real `draw(_:)` call into an offscreen bitmap and works
without a window or WindowServer session.

The pre-existing `indentGuideLineScanBounded` test was vacuous for **two**
independent reasons before this pass fixed it: (1) it used `.display()`
instead of the `cacheDisplay` pattern, and (2) even after switching to
`cacheDisplay`, it never set `indentGuideColor`/`currentLineHighlightColor`/
`font` on the text view — every bounded decoration path early-returns when
its color/font is unset, so the scan it claimed to guard never ran. Any
new draw-path test on `RafuTextView` must set every decoration
property the code path under test depends on, and must use
`bitmapImageRepForCachingDisplay`/`cacheDisplay`, never `.display()`.
