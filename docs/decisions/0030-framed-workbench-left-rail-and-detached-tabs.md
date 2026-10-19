# ADR 0030: Framed workbench — one left Activity Rail, a raised editor deck, and detached tabs

- **Status:** Accepted (2026-10-19) on the user's explicit direction, from
  reference images and videos the user supplied
- **Date:** 2026-10-19
- **Supersedes:**
  - ADR 0003's placement of navigator modes in a right rail and its right
    utility panel
  - ADR 0012's no-shadow rule, and its 2026-10-19 amendment "the left rail is
    removed" (which rejected a left icon rail on the grounds that ADR 0003 owned
    mode placement — that premise is now gone)
  - ADR 0022's 4 pt deck inset, 6 pt deck radius, top-rounded attached-cap tab
    clause, and the "no shadow, material, blur, bevel, or gradient" consequence
- **Retains:** ADR 0002's single sidebar toggle, editor-hosted diffs and
  details, and one visually quiet icon-only activity strip; ADR 0012's theme
  authority, opaque tonal surfaces, native controls/accessibility, and
  no-Liquid-Glass rule; ADR 0022's theme-token ownership (no new JSON keys) and
  its rule that geometry is Rafu's, not the theme's

## Context

The window had accumulated three competing navigation surfaces: a Files-only
left sidebar (ADR 0003), a right icon rail plus a right utility panel for Search
and Source Control (ADR 0003), and a `navigatorMode` whose `.files` case meant
"the right panel is closed". ADR 0022's 4 pt inset and 6 pt radius made the
editor deck read as a seam rather than as a surface, and its no-shadow
consequence left nothing to separate the deck from the chrome behind it.
ADR 0012's 2026-10-19 amendment had just deleted the left rail, which left the
window with no left-edge structure at all.

The user supplied reference images and videos and gave direct direction for a
framed workbench: the window frame is quiet chrome, the editor is one raised
card inside it, and every navigator mode lives on a single always-visible left
rail. That direction overrides the earlier ADRs under the AGENTS.md
sources-of-truth order, so this ADR records it rather than letting a phase brief
contradict ADR 0003, 0012, and 0022 silently.

Note: `docs/plans/phases/macos-redesign.md` carries an instruction not to edit
ADRs. That instruction was scoped to that phase's workstreams, which had no
macOS toolchain and could not verify anything. It does not apply to this work.

## Decision

### a. Frame and card (phase 1)

- The window frame is `appBackground`. `FlatWindowChrome.titleBarColor` and the
  `WindowTitlebarRow` background both use `appBackground`, not
  `sidebarBackground`. The status bar already used `statusBarBackground`, which
  equals `appBackground` in Indigo and Khadi.
- The editor deck is the one raised rounded card: `workbenchInset` 4 → 8 pt,
  `radiusWorkbenchDeck` 6 → 10 pt.
- Depth comes from a soft theme-aware shadow (`WorkbenchDeckShadowStyle`):
  opacity 0.18 dark / 0.10 light, halved under Increase Contrast, radius 6 with
  y-offset 2 so the 8 pt reach fits the 8 pt inset. There is still no material,
  blur, bevel, or gradient, and Reduce Transparency stays a no-op.
- The shadow is applied only to the card's background shape. It is never applied
  to a TextKit or SwiftTerm viewport, and it introduces no `clipShape` or `mask`
  over one.

### b. One left Activity Rail (phase 2)

- `WorkspaceActivityRail` is a 40 pt always-visible rail on the window's left
  edge, below the titlebar row, carrying all five modes: Files, Search, Source
  Control, Terminals, History. It is never gated on sidebar collapse.
- The right rail and the right utility panel are removed.
  `WorkspaceSidebarPanelView` switches sections inside the one left sidebar.
- `WorkspaceSession.navigatorMode` is reinterpreted again: it now means "which
  section the left sidebar shows" and can never mean "closed". Visibility is one
  separate state.
- `showNavigator(_:)` and `selectNavigatorRailIcon(_:)` split the two concerns:
  clicking the selected icon toggles collapse; clicking another selects that
  mode and expands. ⌘B and the titlebar toggle only toggle collapse. The panel
  header ✕ collapses and keeps the mode.
- The palette command "Hide Utility Panel" becomes "Toggle Sidebar (⌘B)". One
  visibility state and one explicit toggle control are kept, which satisfies
  ADR 0002's single-toggle rule and the phase's acceptance item 25.
- Sidebar bounds are 220 / 300 / 560 pt. Search and Source Control carry an
  inner `minWidth` of 300 pt, which can push the sidebar wider than 220.

### c. Drag-to-resize sidebar boundary (phase 3)

- The outer `HSplitView` is replaced by
  `HStack { rail ; sidebar at session.sidebarWidth ; WorkbenchSplitHandle ; deck }`,
  with a 10 pt handle layout width.
- `WorkbenchSidebarResize` holds the pure rules: clamp to bounds, collapse on
  release below 180 pt (minimum − 40), and reopen live past a +32 pt drag.
- `RestorableWorkspace` gains `sidebarWidth` and `isSidebarCollapsed`, both
  decoded with defaults (300 / false) so existing records load unchanged.
  Persistence is debounced 200 ms.
- The window minimum width goes 720 → 760 → 770 pt
  (40 + 220 + 10 + 472 + 16 = 758).

### d. Detached tab cards (phase 4a)

- Tabs are `RoundedRectangle` cards of radius 10 with `space1` spacing. The
  selected tab uses `tabActiveBackground`, a `borderStrong` hairline on all four
  edges, and a tab shadow (radius 3, y 1) through the same shadow helper.
  Inactive tabs use `chipBackground`.
- The attached-cap grammar is gone: open-bottom shapes, `masksBottomSeam`, the
  seam overlay, and `radiusAttachedTab` are removed.
- `tabShelfHeight` is a 40 pt floor that grows with Larger Text.
- Exactly two shadows exist in the workbench — the deck and the selected tab —
  and both go through `WorkbenchDeckShadowStyle`. A source test pins that count.

### e. The `+` is a menu (phase 4a)

The tab strip's `+` is a menu whose primary action is New File, with items New
File, New Terminal, New Terminal Group, and New Ensemble.

### f. Activity dots and a text-only hover preview (phase 4b)

- `EditorTabActivityKind` derives from `AgentCardStatus` through the shared
  `CanvasCardCommands.agentCardStatus(pane:in:)`, so ADR 0029's vocabulary stays
  the single source: working → accent, needsYou → warning, failed → error,
  doneUnread → success; done, inactive, and stopped show nothing.
- Accessory precedence is hover → close, then activity dot, then dirty dot;
  a selected tab shows close. An Ensemble tab shows only a needsYou dot.
- Colour is never alone: every dot is paired with text through `help` and
  `accessibilityValue`.
- The hover preview is an `overlayPreferenceValue` overlay placed on the tab bar
  **outside** the `ScrollView` — deliberately not a `.popover`, so it cannot
  take focus. It appears after a 500 ms delay via `.task(id:)`, is
  `allowsHitTesting(false)` and `accessibilityHidden`, and has no transition
  under Reduce Motion. Its content is text only, built by the pure
  `TabHoverPreviewContentBuilder`.
- Behaviour change: the Ensemble tab's close button is now hover/selected-gated
  like every other tab's.

## Alternatives considered

### Put the sidebar inside the raised card

Rejected. The references show the navigator as part of the quiet rear frame with
one working surface in front of it. Enclosing the sidebar would give the window
two nested cards and would make the rail read as floating chrome.

### Keep a right detail panel alongside the left rail

Rejected. Two mode surfaces are what produced the `.files`-means-closed
confusion in ADR 0003. One rail with one visibility state removes a whole class
of state questions, and ADR 0002 already routes diffs and details into the
editor.

### Use `NSSplitView` with `canCollapseSubview` for the sidebar

Rejected. Additional AppKit hosting panes re-derive the window safe area on
their own schedule and cause titlebar safe-area drift, which is exactly the
failure recorded as rule 2 in
[`flat-window-chrome-titlebar-merge.md`](../references/flat-window-chrome-titlebar-merge.md).
A custom 10 pt handle over pure clamp/collapse rules is testable and cannot move
the safe area.

### Thumbnail tab previews

Rejected. A thumbnail of a document is either a live view (memory and focus
risk) or a stale raster, and neither is readable at tab-preview size. The
preview is text only.

### Keep ADR 0022's no-shadow rule

Rejected on the user's direction. With no shadow, a wider inset and larger
radius still read as a seam. The shadow is bounded (two instances, theme-aware
opacity, halved under Increase Contrast) and is applied to background shapes
only, so it does not reintroduce materials or Liquid Glass.

## Consequences

- `navigatorMode` semantics are reinterpreted a second time. Any code or test
  that read `.files` as "panel closed" is wrong; visibility is
  `isSidebarCollapsed`.
- The restoration schema grows two optional fields (`sidebarWidth`,
  `isSidebarCollapsed`) with decode defaults, so old records keep loading.
- Minimum-window arithmetic is now explicit and must be recomputed whenever the
  rail width, sidebar minimum, or handle width changes:
  40 + 220 + 10 + 472 + 16 = 758, with the window minimum at 770 pt.
- Drag-surface inventory, because `isMovable` stays false: the titlebar row
  (`TitlebarDragSurface`), the left Activity Rail (`WindowDragHandle`), and the
  sidebar header (`WindowDragHandle`). The split handle is **not** a drag
  surface — it resizes.
- Light and imported-theme parity remain gates for every visible increment, and
  the two shadow opacities must be checked in both appearances.
- `ui-design-language.md` and
  `flat-window-chrome-titlebar-merge.md` are updated by this change; the new
  splitter has its own note,
  [`workbench-split-handle.md`](../references/workbench-split-handle.md).

## Revisit trigger

Revisit if a manual pass shows that the shadow reads as a material or fails
under Increase Contrast, that the 40 pt rail plus 220 pt sidebar makes the 770 pt
minimum window unusable, that the hover preview occludes split groups or
terminal panes (open at the time of writing), or that losing the right panel
blocks a real two-pane workflow. Prefer adjusting the compact metric tier and
the shadow opacities before reintroducing a second rail or panel.

## Related

- [`0002-native-workbench-navigation.md`](0002-native-workbench-navigation.md),
  [`0003-files-left-utility-right.md`](0003-files-left-utility-right.md),
  [`0012-flat-workbench-chrome.md`](0012-flat-workbench-chrome.md),
  [`0022-recessed-workbench-deck.md`](0022-recessed-workbench-deck.md),
  [`0029-agent-status-vocabulary.md`](0029-agent-status-vocabulary.md)
- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- [`flat-window-chrome-titlebar-merge.md`](../references/flat-window-chrome-titlebar-merge.md),
  [`workbench-split-handle.md`](../references/workbench-split-handle.md),
  [`swiftui-macos-click-latency.md`](../references/swiftui-macos-click-latency.md),
  [`ui-design-language.md`](../references/ui-design-language.md)
- Commits on `main`: 703e827 (phase 1), 4c72f8c (phase 2), 450c453 (phase 3),
  a28c154 (phase 4a), 96e54b3 (phase 4b)
