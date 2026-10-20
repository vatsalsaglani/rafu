# No layout work inside `didProcessEditing`

- Applies to: every `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)`
  callback and every `NSTextStorage.didProcessEditingNotification` observer
  on an editor storage. Today that is `CodeEditorView.Coordinator`,
  `NeonSyntaxHighlightingPipeline.didProcessEditing`, `EditorGutterRulerView`,
  and `DocumentFindController`.
- Last verified: Swift 6.4, macOS 27.0.1, 2026-10-20 (TextKit 1 editor from
  `RafuTextView.makeTextKit1()`).

## Rule

Inside `didProcessEditing`, only record the edit (offsets, line index,
generation counters, snapshot requests). Do not call anything that asks a
layout manager for geometry or sets display state: `glyphRange(forBoundingRect:in:)`,
`characterRange(forGlyphRange:)`, `boundingRect`, `setTemporaryAttributes`,
`invalidateDisplay`, `visibleTextRange`, or Neon `Highlighter.invalidate`,
which does all of these synchronously on the regex path. Defer such work to
a real next-runloop dispatch (`DispatchQueue.main.async`). An immediate
MainActor hop can still run inside `processEditing`.

## Observed behavior

`-[NSTextStorage processEditing]` calls the delegate and posts the
notification **before** it sends `processEditing(for:edited:range:changeInLength:invalidatedRange:)`
to its layout managers. During the callback the layout manager still holds
the glyph map for the old text, while the storage already holds the new text.

Neon's regex path ran `highlighter.invalidate(.range(editedRange))` from the
callback. That computed the visible range from the old glyph map and applied
temporary attributes, which calls `invalidateDisplayForCharacterRange` and
reads paragraph bounds. When the edit made the text shorter near the visible
end, AppKit read past the new end:

```
NSRangeException: -[NSBigMutableString characterAtIndex:]: Index 479 out of bounds; string length 478
  -[NSLayoutManager _rectArrayForRange:…]
  -[NSLayoutManager invalidateDisplayForCharacterRange:]
  Neon LayoutManagerSystemInterface.setAttributes → Highlighter.invalidate
  NeonSyntaxHighlightingPipeline.didProcessEditing
  -[NSTextStorage processEditing] ← -[NSTextStorage endEditing] ← -[NSTextView _insertText:replacementRange:]
```

In the app, `NSApplication` catches and logs the exception
(`[com.apple.AppKit:General] NSRangeException <redacted reason>`), so the
app keeps running. But the exception unwinds out of `processEditing` before
the layout managers hear about the edit. The storage has the new text and
the layout keeps the old text. Symptoms: the old text and selection stay on
screen, gutter numbers draw on top of each other, colors land on wrong
lines, and the visible character range is longer than the text. Save writes
the new storage text. The longer range also made the old per-line draw walk
spin forever (see `large-file-guard-mode.md`, 2026-10-20 section).

It is not specific to `.env`. Any buffer on the regex path hits it: a file
with no tree-sitter grammar (`.env`, `.txt`, `.ini`, `Makefile`, Go, Rust,
and others), and a grammar file before its parser actor is live. Small files
are the most exposed because the text end is always in the visible range.
The tree-sitter path was not affected: it only enqueues a snapshot in the
callback and invalidates later.

## Why it matters

The failure does not crash and does not show an error. The user sees stale
text and can save content different from what the screen shows. Release
v0.1.9-beta logged the exception at 23:01:20 on 2026-10-20 right before its
hang. The 3514091 build logged 80 of them during the coordinator's live
repro.

## Fix in Rafu

`NeonSyntaxHighlightingPipeline.didProcessEditing` still calls
`highlighter.didChangeContent` synchronously (pure index bookkeeping), but
the regex-path invalidation goes to `scheduleEditInvalidation`, which folds
edits into one pending range (`coalescedEditInvalidation`) and runs one
`DispatchQueue.main.async` flush. The flush clamps the range to the current
length and skips when torn down, suppressed, or a grammar actor became live.

## Reproduction and verification

`Tests/RafuAppTests/EditorRegexHighlightLayoutSyncTests.swift` builds a real
`RafuTextView.makeTextKit1()` in a scroll view, wires the pipeline through a
storage delegate the same way as the coordinator, and replays the reported
edit sequence. It asserts the layout manager maps exactly
`0..<storage.length` and that the visible range ends at or before the text
end. Before the fix the test process aborts with the `NSRangeException`
above (for `.env` and `.txt`); after the fix all cases pass. A second test
awaits one main-queue turn and checks that the edited key is colored.

```bash
swift test --filter EditorRegexHighlightLayoutSync
# Live evidence of the caught exception in a running build:
log show --last 1h --style compact \
  --predicate 'process == "RafuLightning" AND eventMessage CONTAINS "NSRangeException"'
```

## Related

- `Sources/RafuApp/Editor/SyntaxHighlighter.swift` (`NeonSyntaxHighlightingPipeline`)
- `Sources/RafuApp/Editor/EditorGutterRulerView.swift` (same deferral rule for width)
- [`large-file-guard-mode.md`](large-file-guard-mode.md) (walk guard, 2026-10-20)
- [`editor-gutter-incremental-index.md`](editor-gutter-incremental-index.md)
