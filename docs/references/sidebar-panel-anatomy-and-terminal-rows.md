# Sidebar panel anatomy, segmented picker, and Terminals row naming

- Applies to: the five navigator panels (Files, Search, Source Control,
  Terminals, History) and their shared components in
  `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`
  (`RafuUtilityPanelHeader`, `RafuPanelHeaderCount`,
  `RafuPanelHeaderOverflowMenu`, `RafuSidebarSectionHeader`,
  `RafuPanelEmptyState`), `RafuControlStyles.swift` (`RafuSegmentedPicker`),
  `RafuMetrics.swift`, `AgentIdentity.swift` (`AgentSymbols`),
  `Terminal/TerminalNaming.swift`, `TerminalsPanelModel.hierarchyRows`,
  `Views/WorkspaceTerminalsPanelView.swift`, and
  `Views/TerminalGroupSavedLayoutsSection.swift`.
- Last verified: Xcode with macOS 27.2 SDK (26B118), Swift 6 language mode,
  Darwin 27.2.0, Mac17,13, 2026-11-15, Swift 6.4.2. Build and tests ran on the
  branch (parallel green); the main gate is run by the coordinator. The GUI
  checks below are not done. The Terminals native `List` section (below) is
  [ADR 0040](../decisions/0040-terminals-panel-native-list.md): merged as a8c614b
  (branch commit a6d5bf8); branch parallel 495 tests in 36 suites and 3871 tests
  in 315 suites; main gate run by coordinator.

## Rule or observed behavior

The user approved this redesign from a mock-up. It is recorded as amendments to
[ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md) (header
component) and [ADR 0002](../decisions/0002-native-workbench-navigation.md)
(no panel close button).

### Sidebar rules

- Fills only for state: hover, selection, field. No dividers under control
  blocks. The only hairline is above a pinned footer (Saved Terminal Groups).
  One text edge: `RafuMetrics.sidebarTextInset` (10 pt).
- One header, `RafuUtilityPanelHeader`, for all five panels: no fill, no
  hairline, no leading icon, no close button. 13 pt semibold title, tail
  truncation, `.isHeader`, tooltip (the title, or the workspace name for
  Files). A 24 pt row (`navigatorHeaderRowHeight`), 19 pt above (puts the title
  on the tab-label line), 10 pt edge, 8 pt below (`navigatorHeaderBottomSpacing`).
  The trailing inset is 10 pt so Files does not move. The empty run drags the
  window. (The "only hairline is above a pinned footer" rule now applies to the
  Saved footer list shown only when there are no terminals; see "Terminals as a
  native List".) `RafuPanelHeaderCount` is a plain muted count (spoken as "N
  terminals"). `RafuPanelHeaderOverflowMenu` is the `⋯` menu.
- The panel `×` was a second sidebar toggle and is removed. The active rail icon
  now hides the sidebar: tooltip "Hide <Panel>", VoiceOver value "Selected,
  sidebar shown" (plus the attention count). ⌘B and the titlebar button are
  unchanged.
- `RafuSidebarSectionHeader`: 11 pt semibold, Title Case, plain count.
- Frosted-window readiness: no new slabs; fields and chips are opaque. The Source
  Control `List(.inset)` section headers stay the system sticky headers. The
  nested `sidebarBackground` paints in `WorkspaceSidebarView.swift` and
  `WorkspaceSidebarPanelView` were to be handled by the frosted-window work; it
  landed 2026-11-15 as [ADR 0038](../decisions/0038-optional-frosted-window-base.md)
  (`rafuFrameSurface` paints nothing in Frosted). The 19 pt header top inset and
  the 31 pt title centre above became 13 pt and 25 pt with the 6 pt deck top
  inset (ADR 0031 section j), then 9 pt and 21 pt with the 2 pt deck top inset
  (second round, same day; `NavigatorPanelHeaderPlacementTests`).

### Segmented control

One component, `RafuSegmentedPicker`: no outer border, `chipBackground` track,
selection fill with semibold and `.isSelected`, and a `borderStrong` hairline
under Increase Contrast. An optional per-item symbol. Words come first; icons
appear only when words do not fit, through `ViewThatFits`. A fixed width
threshold had put the picker on icons at every normal sidebar width, so do not
use one. `GitSectionPicker` and `GitSectionPickerLayout` were deleted; the label
is "Changes 3". The restyle also reaches Settings, the Ensemble agent control,
the export, handoff and publish sheets, and Resources. That is intended.

### Source Control and Search

Source Control: an unfilled branch row; Stash Changes… and View are in the
header `⋯`; the sync control has no circular-arrows glyph; the "N changed
files" row is gone. Search: a full-width field with a leading magnifier, Return
searches, no Search button, Recent Searches and Replace
(`arrow.left.arrow.right`) in the header, no divider. History: no divider, a
leading glyph.

The Source Control commit composer (2026-11-15) follows the same sidebar rule:
no card, a hairline, one opaque field. See
[`git-commit-composer.md`](git-commit-composer.md).

### Terminals row naming

Naming is pure, in `TerminalNaming` and `TerminalsPanelModel.hierarchyRows`.

- Title precedence: user group name, pane user name, agent session title, agent
  or shell name. Never the folder.
- Ordinals mark look-alike rows (same title and context, creation order).
  User-typed names never change.
- Context: "agent · folder" or "N panes · folder". Placement word: "Ensemble" or
  "Hidden", never "Canvas".
- A status word shows only for abnormal states. Normal is a running or idle
  shell, or a working, done or inactive agent. A shell has a per-state symbol; a
  bell marks attention.
- Rows are two lines, 40 pt, with no card fill or border. A 16 pt status slot
  (`AgentActivityGlyph`) replaces the pill. The `⋯` menu and the drag grip are
  hover overlays (the `⋯` menu also shows on selection, not on focus). `.onDrag`
  and inline rename are kept. The tooltip
  holds the full title and the `~` path. Pane rows are indented 22 pt: ordinal,
  dot, name, folder if different, abnormal word, glyph.
- Start Agent is a header icon button and an empty-state button. Both open the
  same popover, with the "N ready" line at its top. The empty state is compact
  (`RafuPanelEmptyState(compact:)`).
- Saved Terminal Groups is a collapsible one-line header with a count. It is
  collapsed when empty, open on error, and the choice is kept per window in
  `@SceneStorage("terminals.savedGroups.expanded")` (now owned by the panel, same
  key; see the List section below).
- Row border resolver (`TerminalSurfaceBorderStyle.managerRow`): amber means
  attention only; the session colour is the dot only.
  `Emphasis.managerCurrent` was removed. Since ADR 0040, rows pass
  `isCurrent: false`, so the resolver draws only the attention border; the
  selection fill is the system List highlight (see below).

### Terminals as a native List (ADR 0040, 2026-11-15)

The panel is one `List(selection:)` (`.listStyle(.plain)`,
`.scrollContentBackground(.hidden)`, overlay scrollers,
`.tint(theme.palette.selection)`). This replaced the stacked custom rows, and
arrow-key movement is no longer deferred. Decision, rejected alternatives and
VoiceOver contract: [ADR 0040](../decisions/0040-terminals-panel-native-list.md).

Key map (one Tab stop; no key handling while an inline rename field is open):

| Key | Row | Action |
|---|---|---|
| ↑ / ↓ | any | List's own movement |
| Return or Space | group or session | reveal it (Space did nothing here before) |
| Return or Space | pane | reveal and focus the pane |
| Return or Space | saved row | open the saved layout |
| Return, Space, ← , → | Saved header | toggle the section |
| ← / → | group or pane | collapse and expand, and move between a group and its panes (Finder-like) |

Structure and state:

- A group with more than one pane is a disclosure row with a hand-drawn
  `chevron.right` in the 8 pt before the icon. Pane rows are separate List rows
  indented 22 pt. Expanded by default. Collapsed groups are stored per window in
  `@SceneStorage("terminals.groups.collapsed")` as sorted UUIDs, and closed groups
  are removed. Collapsing moves a selected pane's selection to its group. Group
  menus have "Expand Panes" and "Collapse Panes".
- One `String?` selection follows the current terminal; a selected pane of the
  current group stays selected. The current row is semibold with `.isSelected` and
  "Current" in its value. A hairline marks the selected row under Increase
  Contrast.
- Saved Terminal Groups is a `Section` of the same List. The header row is
  selectable; state lines are `.selectionDisabled()`; saved rows are selectable
  (click selects, double-click or Return opens). With no terminals, Saved shows
  under the empty state as a footer list sized to its rows (`footerHeight`, 26 pt
  rows, `maximumFooterRecordRows`), with the one hairline above it. The delete
  confirmation is on the header row.
- Clicks use one tap handler per row; see
  [`swiftui-macos-click-latency.md`](swiftui-macos-click-latency.md).
- Not done: "sections by place" (Tabs, Ensemble, Hidden).

### SF Symbol nuance

`terminal.badge` does not exist on macOS 27.2. A missing symbol fails silently:
SwiftUI draws nothing, and the empty well looks like a layout bug. It had
shipped in four places. Shared names live in
`AgentSymbols.agentTerminal = "sparkles"`, and `AgentSymbolsTests` resolves them
with `NSImage(systemSymbolName:)` on the running OS. Add any new symbol name to
that test.

## Why it matters

Each rule removes a place where the sidebar had drifted: three header
treatments, a second sidebar toggle, a picker that fell to icons at normal
widths, a status pill beside every terminal title that said nothing new, and a
folder name used as a title.

## Reproduction or evidence

Evidence is the merged tests plus a build on the branch. No GUI pass was done.
GUI checks owed: Indigo and Khadi at sidebar widths 250, 310 and 460; the Source
Control words fit; header titles on the tab-label line; the header's empty run
drags the window; hover `⋯`; the grip position; Increase Contrast,
Reduce Transparency, grayscale, and Larger Text; VoiceOver traits and the rail
value.

Terminals native List (ADR 0040): evidence is tests only: `TerminalsPanelListTests`
(9) plus updated `EnsembleBarRedesignTests`, `SidebarPanelRedesignTests`,
`TerminalGroupManagerHierarchyTests` and `TerminalManagerPresentationTests`. No GUI
check was done. GUI checks owed:

- whether `.tint(theme.palette.selection)` changes the plain List selection
  highlight (if not, it is the system accent; check Khadi contrast);
- `.onKeyPress` on the List gets Return and Space before the List does;
- a row click gives the List key focus;
- inline rename focus, and Escape, inside List rows;
- the 8 pt chevron hit area;
- footer list height: no clipping and no extra gap;
- the delete confirmation sheet when the Saved header has scrolled away;
- no sticky slab in Frosted;
- Full Keyboard Access and VoiceOver (group, pane and Saved header contracts);
- a second window keeps its own expansion and selection;
- Increase Contrast (selected-row hairline).

## Verification

```bash
swift test --filter AgentSymbolsTests
swift test --filter NavigatorPanelHeaderPlacementTests
swift test --filter TerminalsPanelListTests
rg -n "RafuUtilityPanelHeader|RafuSegmentedPicker" Sources/RafuApp
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- [ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md) (§i),
  [ADR 0002](../decisions/0002-native-workbench-navigation.md) (2026-11-15 note),
  [ADR 0023](../decisions/0023-terminal-groups-and-saved-layouts.md),
  [ADR 0040](../decisions/0040-terminals-panel-native-list.md)
- [`list-custom-disclosure-group-style.md`](list-custom-disclosure-group-style.md),
  [`swiftui-macos-click-latency.md`](swiftui-macos-click-latency.md)
- [`ui-design-language.md`](ui-design-language.md),
  [`terminal-agent-identity.md`](terminal-agent-identity.md)
- Phase: [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
  (work log 2026-11-15)
