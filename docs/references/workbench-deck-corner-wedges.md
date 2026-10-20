# Rounded deck corners over AppKit content: the wedges must repaint the shadow

- Applies to: `WorkbenchDeckSurface` in
  `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`, and any SwiftUI card
  that draws rounded corners over square AppKit content (TextKit, SwiftTerm)
  without clipping it, while also casting a shadow
- Last verified: Swift 6.4 (swiftlang-6.4.0.34.1),
  macOS 27.0.1 (26A434), 2026-10-20, by build and tests only (no screenshot in the
  implementing session)

## Rule or observed behavior

The deck card may not clip or mask its content (the TextKit/SwiftTerm no-clip
rule), so the content paints square corners. The card hides them with
**corner wedges**: an overlay that paints the four regions between the card's
bounding rectangle and its rounded outline.

A wedge painted in the flat frame colour (`appBackground`) is wrong as soon as
the card casts a shadow. The shadow falls outside the rounded outline — most of
all at the bottom corners, because of its y-offset — and part of that falls
inside the bounding rectangle, which is exactly where the flat wedge sits. The
wedge cuts the shadow off along the bounding rectangle's edges, so each bottom
corner shows a square, pointed notch in the shadow. It is most visible in a
light theme (Khadi), where the shadow is a soft tint on a light frame.

**Fix:** a wedge must show what lies behind the card at that pixel: the frame
plus the card's shadow. `WorkbenchDeckCornerWedges` draws a frame-coloured
rectangle and, above it, the same rounded shape with the same shadow
(`WorkbenchDeckShadowShape`, one definition used twice), then masks the pair
to the even-odd corner shape. Outside the rounded outline the pixels now match
the area just outside the card exactly; inside it the mask removes the layer,
so the content shows.

The mask applies only to this decoration layer. The card's content is still
never clipped or masked, and the wedges stay `allowsHitTesting(false)` and
`accessibilityHidden(true)`.

## Why it matters

- The defect is invisible in a dark theme with a faint shadow and obvious in a
  light theme, so a review in one theme misses it.
- Two separate shadow definitions would drift. Keep one shape view that both
  the background and the wedges draw.
- Surfaces without a shadow (editor groups, `EditorGroupSurface`) keep the flat
  `CornerCutoutOverlay`; adding a shadow to such a surface means switching it
  to the shadowed wedge pattern.

## Reproduction or evidence

1. Khadi theme, a document open so the editor fills the deck.
2. Before the fix: at each bottom corner of the card, the shadow below the
   rounded edge stops in a straight vertical and horizontal line, leaving a
   pointed square notch.
3. After the fix: the shadow follows the rounded corner without a notch.

## Verification

```bash
./script/build.sh
./script/test.sh
swift test --filter "RafuWorkbenchStyleContractTests"
```

`RafuWorkbenchStyleContractTests` pins the structure: one `.mask` in the
styles file, inside `WorkbenchDeckCornerWedges` only; the deck uses the
shadowed wedges and no flat `CornerCutoutOverlay`; the editor group keeps the
flat one; the shadow shape fills before it shadows. A visual check in both
themes stays a manual gate.

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift` —
  `WorkbenchDeckSurface`, `WorkbenchDeckShadowShape`,
  `WorkbenchDeckCornerWedges`, `WorkbenchDeckTopHighlight`,
  `CornerCutoutOverlay`, `CornerCutoutShape`
- [ADR 0031 §g](../decisions/0031-card-header-tabs-and-themed-chrome.md)
- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- [`ui-design-language.md`](ui-design-language.md)
