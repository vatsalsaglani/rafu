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
  Darwin 27.2.0, Mac17,13, 2026-11-15. Build and tests ran on the branch
  (parallel green); the main gate is run by the coordinator. The GUI checks
  below are not done.

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
  window. `RafuPanelHeaderCount` is a plain muted count (spoken as "N
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
  inset (ADR 0031 section j).

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
  hover and focus overlays. `.onDrag` and inline rename are kept. The tooltip
  holds the full title and the `~` path. Pane rows are indented 22 pt: ordinal,
  dot, name, folder if different, abnormal word, glyph.
- Start Agent is a header icon button and an empty-state button. Both open the
  same popover, with the "N ready" line at its top. The empty state is compact
  (`RafuPanelEmptyState(compact:)`).
- Saved Terminal Groups is a collapsible one-line header with a count. It is
  collapsed when empty, open on error, and the choice is kept per window in
  `@SceneStorage("terminals.savedGroups.expanded")`.
- Row border resolver (`TerminalSurfaceBorderStyle.managerRow`): the current row
  is selection fill only (plus `borderStrong` under Increase Contrast); amber
  means attention only; the session colour is the dot only.
  `Emphasis.managerCurrent` was removed.

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
drags the window; hover and focus `⋯`; the grip position; Increase Contrast,
Reduce Transparency, grayscale, and Larger Text; VoiceOver traits and the rail
value. Arrow-key movement in Terminals is deferred (a native `List`; optional;
it would need an ADR).

## Verification

```bash
swift test --filter AgentSymbolsTests
swift test --filter NavigatorPanelHeaderPlacementTests
rg -n "RafuUtilityPanelHeader|RafuSegmentedPicker" Sources/RafuApp
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- [ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md) (§i),
  [ADR 0002](../decisions/0002-native-workbench-navigation.md) (2026-11-15 note),
  [ADR 0023](../decisions/0023-terminal-groups-and-saved-layouts.md)
- [`ui-design-language.md`](ui-design-language.md),
  [`terminal-agent-identity.md`](terminal-agent-identity.md)
- Phase: [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
  (work log 2026-11-15)
