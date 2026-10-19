# Editor gutter: macOS 26 ruler overlay tiling

- Applies to: the editor scroll view's vertical ruler (line-number gutter)
- Last verified: Swift 6.2, macOS 26 SDK, 2026-07-19 (classic re-tiling).
  Feedback-loop section: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS
  27.0.1 (26A434), 2026-10-19.

## Rule or observed behavior

On macOS 26, `NSScrollView` tiles a vertical `NSRulerView` (the line-number
gutter) as an **overlay**, not as a sibling that shrinks the clip view:

- After `super.tile()`, the clip view (`NSClipView`/`contentView`) keeps the
  scroll view's **full width** — the ruler visually covers the clip view's
  left edge instead of the clip view starting after it.
- `contentView.contentInsets.left == ruleThickness`.
- The resting/home scroll position is `bounds.origin.x == -ruleThickness`,
  not `0`.

Consequences that are easy to misdiagnose as unrelated bugs:

1. A wrapping `NSTextView` autoresized to the clip view's width is
   `ruleThickness` points **wider than the visible area** — a phantom
   horizontal overflow that doesn't show up until you scroll or inspect
   frames.
2. Any code path that legally scrolls to `x = 0` — restoring saved
   view/scroll state, `scrollRangeToVisible`, or `NSClipView` constraining a
   scroll — parks the first characters of every line **underneath the
   gutter**, because `x = 0` is not actually the ruler's trailing edge under
   overlay tiling.
3. An earlier fix that simply clamped horizontal scroll `x` to `0` was
   itself wrong for exactly this reason: `0` is not "beside the gutter," it
   is "under the gutter," on this OS version.

## Why it matters

This produced the user-visible bug "text starts underneath the line
numbers" and is a macOS-version-specific ruler-tiling change, not an
application logic bug — a naive gutter-width or scroll-clamp fix reproduces
the same symptom because it never corrects the clip view's frame/insets.

## Reproduction or evidence

Fix: `EditorDropForwardingScrollView.tile()`
(`Sources/RafuApp/Editor/EditorDragAndDrop.swift`) overrides `tile()` to
re-tile classically after calling `super.tile()`:

- Removes the overlay content inset (`insets.left -= thickness` when
  `contentInsets.left >= thickness - 0.5`).
- Moves the clip view's frame so it starts at the ruler's trailing edge
  (`clipFrame.origin.x` set to `ruler.frame.maxX`, width reduced by the
  same delta).

This makes `x = 0` the true horizontal home, sizes the wrapped text view to
the actual visible width, and removes the phantom overflow.

## Feedback loop: never resize the clip view twice in one tile

- Applies to: `EditorDropForwardingScrollView.tile()` and any code that
  changes the clip view's width while it hosts a wrapping, autoresizing
  `NSTextView`.

**Rule.** Resize the clip view at most once per `tile()`, and never in two
opposite directions. The classic re-tile above is only safe if the first
(widening) resize never reaches the text view.

**What went wrong (v0.1.7-beta, d95b793).** Since commit 4e994e1 (2026-07-19;
every tag since v0.1.2-beta), `tile()` resized the clip view twice per call:

1. `super.tile()` resets the clip view to the scroll view's full width (macOS
   26 overlay tiling). The text view has `autoresizingMask = [.width]`, so it
   widened by `ruleThickness`.
2. `retileRulerClassically()` set `contentView.frame` to start at the ruler's
   trailing edge. The text view narrowed by the same amount.

The text container has `widthTracksTextView`, and layout is contiguous
TextKit 1. Every text view width change therefore discards the layout of the
whole container. Background layout restarts at character 0. While it refills,
the document height changes, which reflects the clip view, which tiles the
scroll view again (`_tileWithoutRecursing` -> `tile()`), which changes the
width twice more. On a long file this never converges.

Two user symptoms had this one cause:

- The release app hung after the Ensemble board was opened and a terminal was
  added. Editors that are hidden but still mounted (the board is selected)
  still receive frame changes, so the board switch started the loop. No
  terminal code was involved.
- In a long file, placing the caret and then scrolling snapped the view back to
  the caret. The discarded layout collapsed the document height, `NSClipView`
  constrained the bounds, and the scroll position fell back.

**Fix.** `tile()` now:

- has an `isTiling` re-entrancy guard (the `contentView.frame` write can
  re-enter `tile()` through `reflectScrolledClipView:`);
- turns `clip.autoresizesSubviews` off around `super.tile()` and
  `retileRulerClassically()`, and restores it afterward;
- calls `clip.resizeSubviews(withOldSize:)` once, and only when the final clip
  size differs from the size before the tile.

A no-op tile now changes no width, so no layout is discarded.

**Evidence.** A `sample` of the hung release process (about 42% of samples
idle; the rest in the main thread) showed:

```text
_NSPostBackgroundLayout -> NSLayoutManager _fillLayoutHole...
  -> _resizeTextViewForTextContainer: -> RafuTextView.setFrameSize
  -> NSClipView _reflectDocumentViewFrameChange -> reflectScrolledClipView:
  -> _tileWithoutRecursing -> EditorDropForwardingScrollView.tile()
```

Two separate paths led from `tile()` back to `setFrameSize`: `tile+124` (via
`super.tile()`, the widening) and `tile+1520` (via `setFrame`, the narrowing).
There were no terminal frames. The process ran for more than 13 minutes at
about 50% CPU.

**Diagnosing a hung app (reusable).** Run `sample <pid> 5 -file <out.txt>` and
read the main-thread call graph. A process in state R at about 50% CPU, with
idle `mach_msg` slices between `_NSPostBackgroundLayout` bursts, is a
non-converging background-layout livelock, not a deadlock.

**Tests.** `Tests/RafuAppTests/EditorTileConvergenceTests.swift` (4 tests):

| Test | Before the fix | After |
|---|---|---|
| A no-op tile never changes the text view width | failed | passes |
| Tiling preserves already-laid-out text (`firstUnlaidCharacterIndex() == length`) | failed (1352 vs 1040000) | passes |
| Geometry still tracks a scroll view resize | passed | passes |
| A scrolled position survives repeated tiles | failed (160014 vs 160022) | passes |

**Fixture nuance.** A bare `NSTextView` keeps its 200 pt default width until
something sizes it. The older `<=` width checks in `EditorGutterTilingTests`
therefore pass trivially. The new fixture sizes the text view to the clip
width after the first `tile()`, so a width change is observable.

## Verification

```bash
swift test --filter EditorGutterTilingTests
swift test --filter EditorTileConvergenceTests
```

Full-suite results for the feedback-loop fix on main (2026-10-19): parallel
mode, 250 + 2522 tests passed; `--no-parallel` (CI mode), 250 + 2522 tests
passed. A manual check with a long file (place the caret, scroll, switch to the
Ensemble board and add a terminal) is the user-visible confirmation.

`Tests/RafuAppTests/EditorGutterTilingTests.swift` (3 tests) asserts, after
`tile()`:

- `clip.frame.minX == gutter.frame.maxX` (clip sits beside the gutter) and
  `clip.contentInsets.left == 0` (no leftover overlay inset).
- Scrolling the document view to `(0, 0)` leaves `clip.bounds.origin.x == 0`
  and the document view's width fits within the clip's width (no phantom
  overflow).
- The geometry holds after the gutter's `ruleThickness` changes (e.g. line
  count gains a digit).

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorDragAndDrop.swift` (`EditorDropForwardingScrollView.tile()`)
- `Sources/RafuApp/Editor/EditorGutterRulerView.swift`
- `Tests/RafuAppTests/EditorGutterTilingTests.swift`
- `Tests/RafuAppTests/EditorTileConvergenceTests.swift`
- [`macos26-writing-tools-textkit-layout.md`](macos26-writing-tools-textkit-layout.md)
  (the other full-container TextKit 1 layout hang)
- [`swiftui-appkit-boundary.md`](swiftui-appkit-boundary.md)
- `docs/plans/phases/pre-initial-push-workbench.md`
