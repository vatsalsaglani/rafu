# macOS 26 Writing Tools forces full TextKit 1 layout on selection change

- Applies to: `RafuTextView` (`Sources/RafuApp/Editor/RafuTextView.swift`), and any
  future `NSTextView`-based surface Rafu adds
- Last verified: Swift 6.2, macOS 26.5.2, 2026-07-20

## Rule or observed behavior

On macOS 26, **every** `NSTextView` selection change runs Apple's Writing
Tools selection-rect computation
(`updateWritingToolsSelection` → `_writingToolsRectForRange:` →
`boundingRectForGlyphRange`). On a contiguous-layout TextKit 1 document,
`boundingRectForGlyphRange` forces synchronous **full-document** layout on
the main thread — regardless of how small the visible viewport is or how
large the document is.

Rafu disables this at construction: `RafuTextView.makeTextKit1()` sets

```swift
textView.writingToolsBehavior = .none
```

`writingToolsBehavior` requires macOS 15.0+, which matches this package's
deployment target (`.v15`), so no availability guard is needed.

## Why it matters

This was the root cause of a 75-second main-thread hang, evidenced by a
macOS stackshot report. The reported repro was pressing ⌘F and using
find-next (`DocumentFindState.findNext` → `setSelectedRange`), but because
the trigger is any `NSTextView` selection change, it also explains the
independently reported symptom "place caret, then scrolling stalls."

Rafu edits code, not prose — Writing Tools has no product value on code
buffers, so disabling it has no functional downside for this app.

Any future NSTextView-based surface (a second editor variant, an inline
diff/rename text field, etc.) must set `writingToolsBehavior = .none`
during construction, or explicitly accept this layout cost with a
documented reason.

## Reproduction or evidence

Stack chain from the macOS stackshot report (main thread):

```
… → NSTextView.setSelectedRange(...)
  → updateWritingToolsSelection
  → _writingToolsRectForRange:
  → NSLayoutManager.boundingRectForGlyphRange(...)   (forces full-document layout)
```

Manual repro: open a large file, press ⌘F, use find-next repeatedly — main
thread stalls for tens of seconds without the fix.

## Verification

- `swift test --filter editorDisablesWritingTools` — asserts
  `textView.writingToolsBehavior == .none` on a freshly constructed
  `RafuTextView` (`Tests/RafuAppTests/MultiCaretUndoDiagnosticTests.swift`).
- Manual GUI pass: `./script/build_and_run.sh --verify`, ⌘F find-next on a
  large file — no stall.
- Full suite: 856 tests passing (parallel and `--no-parallel`), 0 build
  warnings, lint clean.

## Deferred: `allowsNonContiguousLayout`

`allowsNonContiguousLayout` was evaluated as an additional/alternative
mitigation and explicitly **deferred**, not adopted, in this change. It
interacts with several other subsystems that were not exercised or
measured here: scroll-fraction restore, the gutter's fragment-based line
math, and the Neon TextKit 1 syntax-highlighting integration. Per
AGENTS.md, a performance-affecting change of that shape needs
Instruments/signpost evidence before adoption, not intuition; that
evidence was not gathered in this change, so the setting was left
untouched.

## Related code, ADRs, and phases

- **Code**: `Sources/RafuApp/Editor/RafuTextView.swift`
  (`makeTextKit1()`), `Sources/RafuApp/Editor/RafuTextView.swift`
  (`drawCurrentLineHighlight`, `drawInlineBlameAnnotation` — the co-fixed
  bounded-scan follow-up, see
  [`large-file-guard-mode.md`](large-file-guard-mode.md))
- **Tests**: `Tests/RafuAppTests/MultiCaretUndoDiagnosticTests.swift`
  (`editorDisablesWritingTools`, `inlineBlameDrawClearsRectBeyondScanCap`)
- **Phase**: [`pre-initial-push-workbench.md`](../plans/phases/pre-initial-push-workbench.md)
