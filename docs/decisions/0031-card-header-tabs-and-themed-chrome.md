# ADR 0031: Card-header tabs, a banded tab shelf, and themed window chrome

- **Status:** Accepted (2026-10-20) on the user's explicit direction, across
  three design rounds the user reviewed; amended by round 4 (§g), which
  changes deck depth, frame/card tones, and the sidebar scroller
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

### g. Round 4 amendment (2026-10-20): depth, gutter, corners, sidebar

The user reported that the card did not read as raised (compared with Codex),
that a collapsed sidebar still left extra space beside the card, and that the
bottom corners of the card showed square points in Khadi. The user also said
not to treat this ADR's values as fixed for UI work. Round 4 amends §b, §c, and
§e as follows; where this section and the text above disagree, this section
holds.

- **Deck depth.** Inset 10 → **12**; deck shadow radius 7 → **8**, y 3 → **4**
  (8 + 4 = 12 still fits the inset); opacity 0.30 → **0.55** dark and
  0.10 → **0.14** light. Increase Contrast still halves it. The dark deck adds
  a 1 pt **inner top highlight** (white at 6 %, fading out by 24 pt down the
  corners) inside the rim hairline. Light themes draw no highlight.
- **Indigo tones.** Frame (`appBackground`, `sidebarBackground`,
  `statusBarBackground`) `#0C0F15` → **`#090B10`**. Card (`editorBackground`,
  `tabBarBackground`, `editor.background`, `editor.gutterBackground`)
  `#151A24` → **`#181D29`**, so the text area, gutter, and shelf stay one tone.
  `hover` `#1D2431` → **`#202735`**, `editor.lineHighlight` `#1A2030` →
  **`#1D2335`**, and `elevatedBackground` `#1B212D` → **`#1E2432`**, to keep
  their former step above the lighter card. `tabActiveBackground`, `selection`,
  and `borderSubtle` are unchanged.
- **Khadi tones.** Frame `#F1EDE3` → **`#EBE5D8`**; shelf `tabBarBackground`
  `#F4F0E6` → **`#F3EEE3`**; `hover` `#EFE9DB` → **`#E4DCCB`**. `selection`
  `#E7E0CE` → **`#DDD3BE`**: on the deeper frame the old value was almost
  invisible and lighter than the new hover, so the sidebar's selected row lost
  its pill. The card stays `#FAF7F0`.
- **Corner wedges carry the shadow.** The deck's corner wedges repaint the
  frame **and** the deck's shadow (the same shape and shadow, drawn again and
  masked to the wedges), not a flat frame colour. A flat wedge cut the shadow
  off inside the card's bounding box. The mask shapes only that decoration
  layer; the card's content is still never clipped or masked. Editor groups,
  which cast no shadow, keep flat wedges. See
  [`workbench-deck-corner-wedges.md`](../references/workbench-deck-corner-wedges.md).
- **Equal gutter when collapsed.** With the sidebar collapsed, the split
  handle's 10 pt hit area counts toward the gutter
  (`WorkbenchDeckLane.padding`), so the card sits 12 pt from the rail, as from
  every other edge. The handle stays, so a drag still reopens the sidebar.
- **Window `minWidth`** stays **774 pt**: 40 + 220 + 10 + 472 + 24 = 766 plus
  margin.
- **Sidebar scroller (amends §e).** The Files `List` gets **overlay**
  scrollers on its own scroll view only (`OverlayScrollerConfigurator`): under
  "Show scroll bars: Always" its legacy scroller drew a neutral system track
  beside the rows and moved the selection pill off-centre. The vertical
  scroller stays enabled and shows while scrolling. The editor keeps
  `EditorThemedScroller` and still follows the user's preference; nothing
  writes the global preferred style. With the scroller out of the row width,
  the tree's trailing row inset is 12 → **8 pt**.
- **Tree alignment.** Each tree row has a fixed 16 pt icon slot, and
  `FileIconView`'s SF Symbol branch has a fixed `size × size` box, so names at
  one depth start at one x.
- **Shelf and header.** The trailing tab fade is 28 → **48 pt** (no sharp
  fragment of the next tab beside `+`). The Files header's top padding is
  10 → **19 pt**, so its title centre aligns with the tab labels'
  centre (12 pt inset + half the 38 pt shelf = 31 pt).

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

Round 4 (§g) narrows this: the one sidebar `List` is forced to overlay style
on the user's direction, per scroll view. The cost is that a user with
"Always" sees the sidebar's scroller only while scrolling there; every other
scroll view still follows the preference.

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
  visible increment. Round 3's visuals are **not** screenshot-verified yet;
  round 4 (§g) was implemented from a reviewer's pixel measurements and is
  not screenshot-verified by the implementing agent either.

## Revisit trigger

Revisit if the unfilled inactive tab proves unreadable at a small window width
or under Increase Contrast, if the Khadi band (`#F4F0E6` under `#FAF7F0`) is
indistinguishable on a low-contrast display (round 4: `#F3EEE3`), if the fixed 38 pt shelf clips
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
