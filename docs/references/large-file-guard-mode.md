# Large-file guard mode

- Applies to: editor document open, syntax highlighting suppression, symbol scanning
- Original guard verification: Swift 6.2, macOS 14+, Xcode 16, 2026-07-15.
- Bounded-read verification: Swift 6.4, macOS 27.0.1, 2026-10-17; focused
  regression tests and the canonical Rafu Lightning app check passed.
- Line-walk termination verification: Swift 6.4, macOS 27.0.1, 2026-10-20.

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

Guarded mode suppresses automatic parsing on large files. The 2 MiB threshold
guards the openable band above 2 MiB through 16 MiB. The 10,000 UTF-16-unit
limit catches dense single-line files below the byte threshold. These limits
reduce syntax work; they do not prove editor response time or total memory use.

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
- **History**: The original 2 MiB guard was below a 4 MiB open cap. The
  2026-10-17 user follow-up raises only the open cap to 16 MiB. The guard
  thresholds stay fixed. See the amendment to ADR 0019.
- **Known limitations**:
  1. Pasting a huge line into an already-open normal document does not retroactively guard it; guard mode engages at open only with an explicit session-only override.
  2. Files with lone-`\r` (classic Mac) line endings scan as one line, conservatively triggering the line-length guard.
  3. Markdown opened directly in preview-only mode has no `CodeEditorView`, so guard state stays `.normal` and no banner is shown.
- **Symbol index reuse**: Increment 10 (`WorkspaceSymbolIndex`) reads the same `document.suppressesSyntax` flag to skip guarded files from the index.
- **Deferred**: A dedicated menu/command-palette "Enable Highlighting for this file" override command; the banner Button is the sufficient keyboard-reachable path this increment (accessible via Full Keyboard Access, not hidden behind a gesture).
- **Lane**: Lane 1, Increment 2 — memory resilience + Tree-sitter Stages A/B

## Bounded text reads (2026-10-17)

Applies to: `WorkspaceFileService.readText`, for local workspace and external
text files. Verified on Swift 6.4 and macOS 27.0.1 on 2026-10-17. The focused
bounded-read tests passed. A synthetic file of exactly 6,722,977 bytes opened
with the guard banner in Rafu Lightning through one sidebar click. No release
performance or memory claim is made.

The open cap is 16 MiB (16,777,216 bytes). A regular UTF-8 file of exactly that
size is accepted. Larger files fail. Files above 2 MiB still use the syntax
guard. This supports the reported 6,722,977-byte text file within a fixed bound.

A path size check alone does not bound a read: the file can grow or the path
can change after that check. Use one `O_RDONLY | O_NONBLOCK | O_CLOEXEC`
descriptor, check its type and size with `fstat`, and read from that descriptor.
`O_NONBLOCK` lets the regular-file check reject named pipes without waiting for
a writer. Reads request at most 64 KiB and at most the remaining cap plus one
detection byte. Overflow throws; it never returns a truncated document.
Cancellation is checked between chunks and before strict UTF-8 decoding.
No user content or paths are logged. Atomic writes use the existing path.

Input bytes are bounded; total resident memory is not equal to this cap.
Decoded strings, TextKit storage, undo, and other open documents add memory.
The existing working-set policy still applies. Release memory evidence remains
a separate phase gate.

Synthetic regressions in `WorkspaceFileBoundedReadTests` cover the reported
byte count, exact cap, cap plus one, file growth after a small descriptor size
snapshot, UTF-8 across chunk boundaries, empty files, invalid UTF-8, directories,
named pipes, and cancellation. The growth test calls the bounded reader after
extending its open file; it does not depend on a timed race. It checks the
file offset to prove that only the cap plus one byte was consumed.

Coordinator verification commands, with one SwiftPM invocation at a time:

```bash
./script/test.sh --filter WorkspaceFileBoundedReadTests
./script/test.sh --filter guardPolicy
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

Related decision: [ADR 0019](../decisions/0019-external-file-opening-and-media-preview.md).
Related phase: [Editor performance and UI repair](../plans/phases/editor-performance-repair.md).

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

## A per-line draw walk must always advance and stop at the text end (2026-10-20)

Applies to: `RafuTextView.drawIndentGuides`, `drawFileBlameAnnotations`, and
any new walk over `viewport.characterRange`. Verified on Swift 6.4, macOS
27.0.1, 2026-10-20.

Observed: the release v0.1.9-beta hung forever (99% CPU, beachball) after
the user selected `us-west-2` at the end of a 31-line `.env` file and typed.
`sample` of the hung process showed 100% of main-thread samples in
`-[NSTextView drawRect:]` → `RafuTextView.drawBackground(in:)` →
`drawIndentGuides(in:)` → `boundedLineRange(around:in:)`. The same screen
drew gutter numbers 29 and 30 on top of each other, so the layout was stale.

Cause: both walks were `while location < NSMaxRange(charRange) { …
location = NSMaxRange(lineRange) }`. The layout manager's visible character
range can be longer than the text while an edit is in flight. At
`location == content.length`, `boundedLineRange` returns an empty range, so
`location` never moves and the loop never ends. The bounded scan from
2026-07-18 limits each step; it does not make the loop finish.

Rule: walk visible lines only through `RafuTextView.forEachBoundedLine(
intersecting:in:_:)`. It clamps the end to `content.length` and stops when a
step does not advance. Do not trust `viewport.characterRange` to be inside
the current text. The trailing empty line still draws through the extra
line fragment path, outside the walk.

Regression: `EditorLineWalkTerminationTests` (range past the end, range at
the end, CRLF and an unterminated last line, and a draw after an
end-of-file replacement with indent guides and blame on).

```bash
swift test --filter EditorLineWalkTermination
```

Root cause of the stale range (found later the same day): the regex syntax
path ran Neon layout work inside `didProcessEditing`, which threw a caught
`NSRangeException` and aborted `processEditing` before the layout manager
saw the edit. See [`text-storage-process-editing.md`](text-storage-process-editing.md).
Keep the walk guard anyway: it is the defense if any other path leaves the
layout behind the storage.

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

## AppKit text-selection and font-panel facts (verified 2026-07-21)

Applies to: `RafuTextView`, `CodeEditorView`. Verified on Swift 6.2 / macOS
26.5.2 with standalone compiled AppKit probes.

**AppKit clamps every public selection setter.** `setSelectedRange(_:)`,
`selectedRanges =`, and `setSelectedRanges(_:affinity:stillSelecting:)` all
clamp an out-of-range value to the current storage length — e.g. restoring a
captured `{12, 7}` after the buffer shrank to 2 characters yields `{2, 0}`,
not a crash. Two consequences:

- A defensive clamp inside a `setSelectedRanges` override would be dead code,
  and would mask a genuinely stale range instead of surfacing it. Rafu
  deliberately does NOT add one.
- Storage edits made through the normal cycle (`shouldChangeText` →
  `replaceCharacters` → `didChangeText`), inside `beginEditing`/`endEditing`,
  or from a storage delegate all keep the selection in bounds.

**`-[NSTextView setTextColor:]` is not cheap and is not local.** It routes
through `_addToTypingAttributes:` → `setTypingAttributes:` →
`updateFontPanel`, which enumerates attributes over
`rangeForUserCharacterAttributeChange`. For an editable plain-text view that
range is `{0, textStorage.length}` (NOT the selection); when the view is
non-editable or non-selectable it is `{NSNotFound, 0}`, whose `NSMaxRange`
overflows — the shape that makes `ensureAttributesAreFixedInRange:` raise
`NSRangeException`. Never assign editor colors unconditionally from
`updateNSView`: that puts the whole round trip on the typing path (AGENTS
budgets one display frame at p95) and turns any transient inconsistency in
AppKit's text state into a crash on the next display cycle.
`CodeEditorView.Coordinator.applyEditorColors` guards the assignment on
`EditorColorSet`, which compares the theme's resolved HEX (an
`NSColor(rafuHex:)` round trip is not guaranteed to compare equal across
colorspace representations, which would silently defeat the guard).

**`updateFontPanel` is unreachable headlessly.** It early-returns unless the
text view is first responder of a KEY window, and a `swift test` process
cannot make a window key. A test asserting "assigning `textColor` does not
throw" is therefore vacuously green — assert the guard and the
selection-in-bounds invariant instead (`EditorThemeColorApplicationTests`,
`EditorSelectionBoundsTests`).
