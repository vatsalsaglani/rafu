# ADR 0031: Card-header tabs, a banded tab shelf, and themed window chrome

- **Status:** Accepted (2026-10-20) on the user's explicit direction, across
  three design rounds the user reviewed
- **Date:** 2026-10-20
- **Supersedes** (clause by clause, from
  [ADR 0030](0030-framed-workbench-left-rail-and-detached-tabs.md)):
  - §a deck geometry and shadow values — `radiusWorkbenchDeck` 10 → 12 pt,
    `workbenchInset` 8 → 10 pt, deck shadow opacity 0.18 dark / 0.10 light
    radius 6 y 2 → **0.30 dark / 0.10 light, radius 7, y 3**
  - §c window minimum width 770 → **774 pt**
  - §d selected-tab fill, outline, inactive-tab fill, font, shelf height, and
    tab shadow (see below); the ADR 0030 `chipBackground` inactive fill and
    `borderStrong` selected outline no longer hold
  - §e the `+` menu's presentation — it is now one `+` plus a separate `⌄`
    overflow control at the shelf's trailing edge, behind a trailing fade
- **Retains:** ADR 0030's framed-workbench premise, the left Activity Rail, the
  custom split handle, detached (non-attached-cap) tabs, the two-shadow budget,
  the activity-dot vocabulary, and the focus-safe text-only hover preview;
  ADR 0012's theme authority, opaque tonal surfaces, and no-Liquid-Glass rule;
  ADR 0022's rule that geometry is Rafu's, not the theme's

## Context

ADR 0030 landed the framed workbench, but the first person to look at the window
found the result unresolved: the selected tab's `borderStrong` outline plus a
`chipBackground` inactive fill made every tab read as an equally weighted
control, the 40 pt shelf grew when tabs overflowed, the deck shadow was too weak
to separate the card from the frame, and the Indigo frame used the same tone as
the sidebar so the "frame" had no edge.

The user directed three further rounds (WP-A, round 2, round 3) from supplied
references. Because these rounds change values ADR 0030 states explicitly, they
are recorded here rather than left to drift inside a phase brief.

## Decision

### a. Tabs are card headers, not chips

- The selected tab uses `tabActiveBackground` (Indigo `#222A38`, Khadi
  `#FFFFFF`) with a `borderSubtle` hairline — promoted to `borderStrong` only
  under Increase Contrast. Inactive tabs are **unfilled**: no `chipBackground`,
  no outline.
- Labels are 12.5 pt, **semibold** when selected and **medium** when inactive.
  Weight, fill, and hairline carry selection together; colour is never alone.
- `StitchedAccentEdge` is removed. The selected tab no longer carries an accent
  edge of any kind.
- Tab shadow opacity 0.40 dark / 0.18 light, radius 4; halved under Increase
  Contrast, like the deck shadow. The two-shadow budget from ADR 0030 §d is
  unchanged.
- Tab labels are **plain content**, not a `Button`. A drag may start anywhere on
  the tab; see
  [`swiftui-macos-click-latency.md`](../references/swiftui-macos-click-latency.md).

### b. The tab shelf is a fixed band

- `tabShelfHeight` is a **fixed 38 pt** (not a floor), with 5 pt of internal
  breathing. It no longer grows on overflow.
- The shelf is painted with `tabBarBackground`: in Indigo this equals the card
  tone `#151A24`; in Khadi it is `#F4F0E6`, one step below the card `#FAF7F0`,
  so the band reads as a surface the tabs sit on. An unset `tabBarBackground` in
  an imported theme now falls back to `editorBackground`.
- Exactly **one** header hairline. When a breadcrumb follows the shelf, the
  shelf's own hairline is hidden.
- The breadcrumb row is card-toned, 26 pt tall, 12 pt horizontal padding, with
  the row typography of the design language.
- Overflow affordances: a leading fade only while scrolled, a 28 pt trailing
  fade with an 8 pt gap before `+` / `⌄`. Both fades are grey — never accent.
  A `ScrollViewReader` reveals the selected tab.

### c. Frame, deck, and rail

- Indigo's frame is `#0C0F15` for `appBackground`, `sidebarBackground`, and
  `statusBarBackground`, one step darker than the card so the frame has an edge.
  `borderStrong` is `#6A748D`, chosen to clear a 3:1 contrast gate.
- Deck: radius 12, inset 10, shadow 0.30 dark / 0.10 light, radius 7, y 3.
- Window `minWidth` is **774 pt**: 40 + 220 + 10 + 472 + 20 = 762 plus margin.
  Recompute this whenever the rail width, sidebar minimum, handle width, or
  deck inset changes.
- The idle sidebar seam is removed. The grab bar appears on hover only; see
  [`workbench-split-handle.md`](../references/workbench-split-handle.md).
- The Activity Rail uses a selection fill plus a `borderSubtle` hairline, a
  15 pt glyph, 6 pt spacing, and 10 pt top inset. `RafuRailAppTile` draws
  `RafuSeamGlyph` natively on a `tabActiveBackground` tile; the tile is
  non-interactive and `accessibilityHidden`, so it adds no VoiceOver stop.

### d. Files tree rows are flat List rows

The Files tree uses a custom `RafuFileTreeDisclosureStyle` with
`FileTreeMetrics` (row 26 pt, indent 14 pt, selection radius 6 pt) and indent
guides whose segment beside the selected child is drawn strong. Depth is passed
through the recursion rather than inferred.

A custom `DisclosureGroupStyle` makes `List` stop treating the group as an
outline, so the style owns its own keyboard (Return/Space/←/→) and its own
VoiceOver expanded/collapsed state. That trade is deliberate and is documented
in
[`list-custom-disclosure-group-style.md`](../references/list-custom-disclosure-group-style.md).

The sidebar header carries a `magnifyingglass` filter and one `plus` menu
(New File…, New Folder…, Add Folder to Workspace…).

### e. Scrollers are themed, never forced

`EditorThemedScroller` is an `NSScroller` subclass that overrides
`isCompatibleWithOverlayScrollers` and paints a theme track and knob. It never
writes `scrollerStyle`, because forcing a style overrides the user's
"Show scroll bars" setting. A horizontal `ScrollView` still reserves ~15 pt even
with overlay scrollers, which is why the shelf is a fixed height plus a
scroller-hiding configurator rather than a growing container.

### f. One Ensemble icon

The Ensemble symbol is `circle.hexagongrid` everywhere, including
`CanvasBoardState.ensembleSymbol`.

## Alternatives considered

### Keep ADR 0030's outlined selected tab and filled inactive tabs

Rejected on review. Equal fills plus a strong outline made the strip read as a
row of buttons rather than one active surface. Removing the inactive fill and
moving selection onto fill + weight + hairline gives one obvious active tab at
a glance.

### Let the shelf grow when tabs overflow

Rejected. That is what the 40 pt floor produced, and it moves the whole editor
down as the user opens files. A fixed band plus horizontal scrolling keeps the
chrome still; the reserved-scroller space it exposes is handled by the
configurator.

### Force `scrollerStyle = .overlay` to remove the legacy scroller

Rejected. It overrides a system accessibility preference for every scroll view
in the window. Overriding `isCompatibleWithOverlayScrollers` on a themed
subclass solves the appearance without touching the user's setting.

### Wrap each tab label in a `Button`

Rejected after a real failure: a `Button(.plain)` label inside a view carrying
`.onDrag` owns the mouse-down, so drags never start. Tab and row labels are
plain content with explicit click handling.

## Consequences

- Imported themes that omit `tabBarBackground` now resolve to
  `editorBackground`, so a theme written before this change renders a band
  rather than a hole.
- Minimum-window arithmetic changed again (774 pt). Any later change to rail,
  sidebar minimum, handle, or deck inset must redo the sum.
- Increase Contrast now has three jobs in the workbench: promote the tab
  hairline to `borderStrong`, halve the deck shadow, and halve the tab shadow.
- Light/dark × Indigo/Khadi × an imported theme remains a gate for every
  visible increment. Round 3's visuals are **not** screenshot-verified yet.

## Revisit trigger

Revisit if the unfilled inactive tab proves unreadable at a small window width
or under Increase Contrast, if the Khadi band (`#F4F0E6` under `#FAF7F0`) is
indistinguishable on a low-contrast display, if the fixed 38 pt shelf clips
under Larger Text, or if `isCompatibleWithOverlayScrollers` stops being honoured
by a future macOS release.

## Related

- [`0012-flat-workbench-chrome.md`](0012-flat-workbench-chrome.md),
  [`0022-recessed-workbench-deck.md`](0022-recessed-workbench-deck.md),
  [`0030-framed-workbench-left-rail-and-detached-tabs.md`](0030-framed-workbench-left-rail-and-detached-tabs.md)
- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- [`ui-design-language.md`](../references/ui-design-language.md),
  [`workbench-split-handle.md`](../references/workbench-split-handle.md),
  [`swiftui-macos-click-latency.md`](../references/swiftui-macos-click-latency.md),
  [`scrollview-legacy-scroller-always-setting.md`](../references/scrollview-legacy-scroller-always-setting.md),
  [`list-custom-disclosure-group-style.md`](../references/list-custom-disclosure-group-style.md)
- Commits on `main`: bfb1710 (WP-A), 349d66f + f094e46 (round 2),
  3fcc1aa (round 3)
