# Multi-caret editing

- **Applies to:** `RafuTextView` caret ownership, TextKit selection bridging,
  secondary-caret rendering, and multi-caret edit batches
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-17

## Caret ownership and rendering rule

`RafuTextView` owns the authoritative normalized UTF-16 caret set and its
primary index. AppKit's `selectedRanges` is a presentation surface, not the
source of truth: Rafu supplies the logical primary by itself when every range
is empty, and supplies the full set when non-empty selections need native
highlighting. Any zero-length range AppKit drops is drawn by one non-interactive
`MultiCaretOverlayView` above the text view's glyphs.

Overlay rectangles come from the deterministic TextKit 1 layout manager's
`boundingRect(forGlyphRange:in:)` plus `textContainerOrigin`, with explicit
handling for the extra line fragment and an empty buffer. The overlay is one
view per text view, never one view per caret. It is excluded from hit testing
and the accessibility tree.

Current-line and matched-bracket decorations are suppressed while more than
one caret is active because both otherwise describe only AppKit's single
`selectedRange()` and would be misleading. They resume automatically when a
plain AppKit selection collapses the caret set.

Secondary carets blink from a timer installed explicitly on `RunLoop.main`.
The nonisolated timer callback enters `MainActor` before touching the view; an
`isolated deinit` invalidates the non-`Sendable` timer on the view's actor.
Reduce Motion disables the timer and leaves every overlay caret steadily
visible.

## Batch edit and undo rule

Typing, backward delete, forward delete, and paste enter the multi-caret path
only when more than one caret is authoritative and no marked-text composition
is active. One model operation produces sub-edits sorted from the highest
UTF-16 location to the lowest, so each `NSTextStorage` replacement leaves every
not-yet-applied lower offset valid. Empty-caret deletion expands with
`rangeOfComposedCharacterSequence` before sorting, so emoji and other grapheme
clusters are never split.

One user gesture opens one explicit undo group. Every accepted sub-edit follows
`shouldChangeText` → `replaceCharacters` → `didChangeText`. The action is named
`Multi-Cursor Edit` **before** `endUndoGrouping()`; naming the closed group is an
AppKit invalid-group exception. A future delegate rejection after earlier
sub-edits never installs the full batch's planned caret coordinates; Rafu
collapses to the remaining native selection instead.

Each sub-edit intentionally produces one
`textStorage(_:didProcessEditing:range:changeInLength:)` callback. Therefore an
N-caret gesture yields N ordered `EditorDocument.recordEditDelta` calls and N
ordered enqueues into the existing non-cancelling serial syntax reparse chain.
No syntax or language-intelligence consumer changes are needed.

The newline delegate's single-caret auto-indent path is bypassed during a
multi-caret batch. Newlines are inserted literally at every caret in v1; there
is no per-caret auto-indent.

## Gestures, commands, and restoration

Option-click without Command toggles the caret at AppKit's insertion index;
plain click and the existing Command-click navigation keep their original
paths. Escape consumes the key only while multiple carets are active and
collapses to the logical primary. Marked-text composition never enters either
multi-caret branch.

Occurrence commands operate on the primary selection. The first
select-next invocation expands an empty primary through
`IdentifierUnderCaret`; subsequent invocations add literal substring matches,
and select-all replaces the caret set with the bounded result. Adding a caret
above or below uses the primary caret's goal column but searches outward from
the current topmost or bottommost caret. Foundation line ranges provide UTF-16
line starts, while CR/LF terminators are removed before the pure model clamps
the goal column on ragged and empty lines.

`EditorDocument` stores only one restored selection by design. Before a live
multi-caret text view hibernates, `CodeEditorView.Coordinator` captures the
authoritative logical primary instead of AppKit's presentation selection.
Restoration therefore resumes with one primary caret and never serializes the
ephemeral secondary set.

## Runtime spike findings

### Spike A — multiple zero-length selections

On the verified SDK, an `NSTextView` given zero-length ranges at UTF-16 offsets
1, 6, and 10 retained only `[{1, 0}]`; `selectedRange()` was also `{1, 0}`.
When the request order placed a later logical primary first, AppKit sorted the
ranges and still retained the earliest caret. Therefore native selection state
cannot own or preserve Rafu's multi-caret set.

The same headless harness retained three non-empty selections exactly. A mixed
request retained the non-empty selections and dropped its empty range. Rafu
uses that behavior only for presentation and detects the retained empty ranges
after every synchronization, so the overlay remains correct if a future SDK
changes the retention policy.

The primary caret's native blinking was not visually confirmed headlessly.
Rafu supplies only the logical primary to AppKit for an all-empty caret set,
leaving the existing single-caret insertion-point path intact; the consolidated
MC6 GUI pass must confirm its blink.

### Spike B — insertion-point override versus overlay

An offscreen keyed-window harness overriding
`drawInsertionPoint(in:color:turnedOn:)` received zero calls during a 1.2-second
run-loop interval. That result is insufficient to reject the override in a
fully interactive window, so the spike remains visually unconfirmed. The lane
uses the plan's outcome-independent overlay design: it does not replace native
primary-caret drawing and remains correct whether AppKit invokes that override
or changes zero-range retention later.

## Evidence and reproduction

The spike commands used a stock `NSTextView`, called `setSelectedRanges`, and
printed `selectedRanges` plus `selectedRange()`. The checked-in tests cover:

- authoritative retention of three logical empty carets while AppKit presents
  only the requested logical primary;
- overlay geometry and an offscreen PDF render above glyphs;
- collapse to one native selection after an ordinary selection change; and
- steady overlay carets when Reduce Motion is active.

Verification commands:

```bash
swift build
swift test --filter MultiCaret
swift test
./script/format.sh --fix
./script/format.sh --lint
```

MC4 completed with 529 tests green. Per the lane coordinator's explicit run
direction, `./script/build_and_run.sh --verify` and the interactive blink,
gesture, IME, accessibility, hibernation, and second-window checks are deferred
to one consolidated MC6 pass.

## Related code and plans

- `Sources/RafuApp/Editor/MultiCaretModel.swift`
- `Sources/RafuApp/Editor/MultiCaretOverlayView.swift`
- `Sources/RafuApp/Editor/RafuTextView.swift`
- `Sources/RafuApp/Editor/CodeEditorView.swift`
- `Tests/RafuAppTests/MultiCaretModelTests.swift`
- `docs/plans/phases/multi-cursor-editing.md`
- `docs/references/swiftui-appkit-boundary.md`
- `docs/references/editor-working-set-and-hibernation.md`
