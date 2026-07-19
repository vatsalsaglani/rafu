# Editor gutter: macOS 26 ruler overlay tiling

- Applies to: the editor scroll view's vertical ruler (line-number gutter)
- Last verified: Swift 6.2, macOS 26 SDK, 2026-07-19

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

## Verification

```bash
swift test --filter EditorGutterTilingTests
```

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
- [`swiftui-appkit-boundary.md`](swiftui-appkit-boundary.md)
- `docs/plans/phases/pre-initial-push-workbench.md`
