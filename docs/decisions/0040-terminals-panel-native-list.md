# ADR 0040: The Terminals panel is a native List with arrow keys

- **Status:** Accepted (2026-11-15) on the user's direction ("CONTINUE THE
  OPTIONALS", which included "Terminals as a native macOS list with arrow keys
  (needs an ADR)"). GUI checks pending (listed below).
- **Date:** 2026-11-15
- **Amends:** [ADR 0031](0031-card-header-tabs-and-themed-chrome.md) §i (the
  Terminals row structure: stacked custom rows with no keyboard movement, and its
  "no accordion" note). All other §i rules stay (one header, one picker, fills
  only for state, the Terminals naming rules).

## Context

The Terminals panel drew stacked custom rows (a `ScrollView` of row views).
Arrow-key movement was deferred in the sidebar panel redesign because it needs a
native `List`. The user asked for it. Files already uses a `List` with
`.listStyle(.plain)` and a custom `DisclosureGroupStyle`, and that style gave up
the system outline and its keyboard (see
[`list-custom-disclosure-group-style.md`](../references/list-custom-disclosure-group-style.md)).

## Decision

The Terminals sidebar panel is one SwiftUI `List(selection:)`.

- **List style.** `.listStyle(.plain)` (same as Files),
  `.scrollContentBackground(.hidden)`, overlay scrollers, and
  `.tint(theme.palette.selection)`.
- **Selection.** One `String?` selection that follows the current terminal. A
  selected pane of the current group stays selected.
- **Keyboard.** One Tab stop. ↑ and ↓ are the List's own. Return or Space opens
  the row: reveal the group or session, reveal and focus a pane, or open a saved
  layout. ← and → collapse and expand and move between a group and its panes
  (Finder-like). On the Saved header, Return, Space, ← and → toggle the section.
  The panel handles no key while an inline rename field is open. Space now opens
  group and session rows (before, it did nothing there).
- **Disclosure.** A group with more than one pane is a disclosure row again, with
  a hand-drawn `chevron.right` in the 8 pt before the icon. Its pane rows are
  separate flat List rows indented 22 pt. Groups are expanded by default.
  Collapsed groups are stored per window in
  `@SceneStorage("terminals.groups.collapsed")` as sorted UUIDs; closed groups
  are removed. Collapsing moves a selected pane's selection to its group. Group
  menus gain "Expand Panes" and "Collapse Panes".
- **Selection fill.** The system List highlight, tinted with the theme selection.
  Rows pass `isCurrent: false` to the shared `.managerRow` border resolver, so it
  draws only the attention border. The current row shows semibold, `.isSelected`
  and "Current" in its accessibility value. A hairline marks the selected row
  under Increase Contrast.
- **Clicks.** One tap handler per row (`TabClickIntent`). A click selects and
  reveals at once; a double-click renames; ⌘-click is a plain click. Rows are
  plain content, not Buttons, so a click is not held back and `.onDrag` keeps the
  press.
- **VoiceOver.** Group rows: value starts "Expanded" or "Collapsed", an
  Expand/Collapse action, a default Reveal action, `.isButton`. Pane rows are
  elements with label, value and actions. The Saved header has a label with the
  count, an Expanded/Collapsed value, and header and button traits.
- **Saved Terminal Groups.** A `Section` of the same List. The header row is
  selectable. State lines use `.selectionDisabled()`. Saved rows are selectable:
  a click selects; a double-click or Return opens. With no terminals, Saved shows
  under the empty state as a footer list sized to its rows (`footerHeight`, 26 pt
  rows, `maximumFooterRecordRows`), with the one hairline above it. The delete
  confirmation is on the header row. The Saved section's `@SceneStorage` moved
  to the panel (same key `terminals.savedGroups.expanded`).
- **Kept.** Context menus, the hover `⋯` menu (now shown on hover or selection,
  not on focus), inline rename on all four row types (the group rename field now
  takes focus when it opens), `.onDrag` with
  `CanvasBoardDragPayload(terminalGroupID:)`, two-line 40 pt rows, status glyphs,
  ordinals, the Ensemble and Hidden words, and the attention-only amber border.

## Alternatives considered

- **Keep the stacked custom rows.** Rejected: no arrow keys, which is the request.
- **System `DisclosureGroup` or `OutlineGroup`.** Rejected: one system-style group
  makes SwiftUI back the whole List with an `NSOutlineView`. That path crashed on
  collapse in Files, and a selected row under a collapsed group draws a phantom
  highlight. See
  [`list-custom-disclosure-group-style.md`](../references/list-custom-disclosure-group-style.md).
- **A custom `DisclosureGroupStyle`, as Files does.** Not chosen: the style owns
  its own keyboard and VoiceOver state, and a flat row List with a hand-drawn
  chevron gives the same layout with one selection model.

## Consequences

- The Terminals panel has keyboard row movement and one selection model, and uses
  the system List highlight.
- The selection colour depends on `.tint` reaching the plain List highlight. This
  is unverified (see the GUI checks). If it does not, the highlight is the system
  accent.
- Terminals is a second List that avoids the outline without a
  `DisclosureGroupStyle`; do not add a system `DisclosureGroup` to it.
- Not done: "sections by place" (Tabs, Ensemble, Hidden).

## Revisit trigger

Revisit if `.tint` does not reach the highlight and Khadi contrast fails, if
`.onKeyPress` on the List does not receive Return and Space before the List, or
if a row click does not give the List key focus.

GUI checks owed: whether `.tint` changes the plain List selection highlight (else
the system accent, and Khadi contrast); `.onKeyPress` on the List gets Return and
Space before the List; a row click gives the List key focus; inline rename focus
and Escape inside List rows; the 8 pt chevron hit area; footer list height (no
clipping, no extra gap); the delete confirmation when the header scrolls away; no
sticky slab in Frosted; Full Keyboard Access; VoiceOver; a second window keeps
its own expansion and selection; Increase Contrast.

## Related

- [`sidebar-panel-anatomy-and-terminal-rows.md`](../references/sidebar-panel-anatomy-and-terminal-rows.md)
- [`list-custom-disclosure-group-style.md`](../references/list-custom-disclosure-group-style.md)
- [`swiftui-macos-click-latency.md`](../references/swiftui-macos-click-latency.md)
- [ADR 0031](0031-card-header-tabs-and-themed-chrome.md) §i,
  [ADR 0023](0023-terminal-groups-and-saved-layouts.md)
- Phase: [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
  (work log 2026-11-15)
- Code: `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`,
  `Sources/RafuApp/Views/TerminalGroupSavedLayoutsSection.swift`. Tests:
  `TerminalsPanelListTests` (9), plus updated `EnsembleBarRedesignTests`,
  `SidebarPanelRedesignTests`, `TerminalGroupManagerHierarchyTests`,
  `TerminalManagerPresentationTests`.
