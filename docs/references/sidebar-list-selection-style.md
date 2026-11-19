# Sidebar list selection style

- Applies to: every sidebar `List(selection:)` (Terminals with its Saved
  section, Ensembles, Source Control Changes and History), and any new list
  that must look like Agent History. Code:
  `Sources/RafuApp/Support/RafuListSelection.swift`.
- Last verified: 2026-11-19, Swift 6.4.2, macOS 27.2.1 (26B8132). The AppKit
  facts below come from a scratch offscreen probe and from
  `SidebarListSelectionStyleTests`. No GUI check of the running app was done.

## Rule

A sidebar list shows one quiet selection: the Agent History look. The row
draws it, not AppKit.

1. On the `List`, call `.rafuQuietListSelection()`. It sets the backing table
   view's `selectionHighlightStyle` to `.none`.
2. On each selectable row, call
   `.rafuRowSelection(isSelected:isHovering:cornerRadius:horizontalBleed:)`.
   It fills the row with `theme.palette.selection` (hover: `hover`). Under
   Increase Contrast it adds a `borderStrong` hairline to the selected row.

Do not use `.tint(theme.palette.selection)` to color a List selection. It does
not reach the native highlight.

## Observed behavior

- On this SDK a SwiftUI `List` (`.plain` and `.inset`, flat rows, no
  `DisclosureGroup`) is backed by `SwiftUIOutlineListView`, a subclass of
  `NSOutlineView`. Its rows are `ListTableRowView`, which does not override
  `drawSelection(in:)`. The List's `NSScrollView.documentView` is that table.
- The native highlight is emphasized (the system accent, rendered
  `rgb(0.00, 0.44, 0.85)`) while the table is first responder in the key
  window, and unemphasized (neutral gray `0.35`) otherwise. `.tint(...)` does
  not change either.
- So the same row is gray at one moment and bright blue at the next: it turns
  blue as soon as the table is first responder (a click on the list, Tab, an
  arrow key). This is why Terminals, Ensembles and Changes showed blue and
  Agent History (a plain `List` with no selection, whose rows draw their own
  fill) did not.
- With `selectionHighlightStyle = .none`: nothing is drawn for the selected
  row, `isSelected` stays true, the selection binding is unchanged, ↓ still
  moves the selection, and a SwiftUI update does not reset the style. The row
  view picks up the new style on the next run-loop turn, not at once.
- The Accessibility selected state comes from the table, so it is unchanged.

## Why it matters

The saturated accent fill with white text was the loudest thing in the
sidebar, and it changed with focus. The user expects one calm selection in
every panel, in light and dark themes, with Increase Contrast still visible.

## Reproduction or evidence

- `SidebarListSelectionStyleTests` "The suppressor turns the List's native
  highlight off and keeps its selection" hosts a `List(selection:)` in an
  offscreen window and reads the table's style and selected rows.
- Pixel evidence used `NSView.dataWithPDF(inside:)` on the row view.
  `cacheDisplay` and `CALayer.render` do not show the selection, so they give
  false negatives.

## Verification

```bash
swift test --filter SidebarListSelectionStyleTests
swift test --filter TerminalsPanelListTests
```

Manual: open each panel, click a row, press Tab and ↑/↓. The fill must stay
neutral in Indigo and Khadi, and show a hairline under Increase Contrast.

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/RafuListSelection.swift`,
  `Sources/RafuApp/Support/ScrollViewConfigurator.swift`
  (`OverlayScrollerProbeView.listScrollView(around:)`, shared probe search).
- [ADR 0040](../decisions/0040-terminals-panel-native-list.md) amendment
  2026-11-19.
- [`sidebar-panel-anatomy-and-terminal-rows.md`](sidebar-panel-anatomy-and-terminal-rows.md),
  [`scrollview-legacy-scroller-always-setting.md`](scrollview-legacy-scroller-always-setting.md).
