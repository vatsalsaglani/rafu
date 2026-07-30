# WP-40 — Rails, Search, Source Control, Runs, and branch popover

## Status and execution slot

- **Status:** Planned.
- **Wave:** 1; parallel.
- **Suggested branch:** `codex/presentation-utility-panels`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact `<FOUNDATION_SHA>`.
- **Merge round:** after WP-30.

## Goal

Give the right utility area one compact anatomy: clear selected rails, a single
concrete header per mode, consistent empty states, dense Search and Source
Control, a quieter Ensemble Runs panel, and a correctly bounded native branch
popover. Preserve every Search, Git, Runs, command, and explicit-user-action
boundary.

This lane owns all of `WorkspaceNavigatorView.swift`, including the sidebar
toggle and utility rail. WP-10 must not edit those call sites. WP-30 supplies
the final terminal panel header; merge WP-30 first even though the branches are
file-disjoint.

## Required reading and skills

Read:

- `AGENTS.md`
- [`README.md`](README.md)
- [`WP-00-foundation.md`](WP-00-foundation.md)
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
- parent plan sections A/rail and utility fill, D, E, P3, verification, risks
- ADR 0002, ADR 0012, ADR 0018, and ADR 0022
- `docs/references/searchable-dropdown-component.md`
- `docs/references/settings-surface.md` only for shared hierarchy vocabulary
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with latest APIs, layout, lists, focus,
accessibility, scroll, and macOS views. Use Build macOS Apps
`swiftui-patterns`, especially split/inspector and command/menu guidance. This
is UI composition; do not change async Search/Git/Ensemble services.

## Exclusive ownership

Source:

- `Sources/RafuApp/Views/WorkspaceNavigatorView.swift`
- `Sources/RafuApp/Views/GitInspectorView.swift`
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift`
- `Sources/RafuApp/Support/RafuSearchableDropdown.swift`
- `Sources/RafuApp/Views/WorkspaceStatusBar.swift`

Tests:

- `Tests/RafuAppTests/RafuSearchableDropdownTests.swift`
- `Tests/RafuAppTests/StatusBarBranchFormatterTests.swift`
- `Tests/RafuAppTests/Conductor/ConductorRunsPanelPresentationTests.swift`,
  created by WP-00's ownership split
- new `Tests/RafuAppTests/UtilityPanelPresentationTests.swift`

Documentation:

- this plan's implementation record
- one uniquely named reference note only for a newly verified reusable popover,
  panel-alignment, or accessibility nuance

Do not edit `WorkspaceTerminalsPanelView.swift`, `WorkspaceSession.swift`,
Ensemble composer/graph/detail files, any Search/Git/Conductor service or model,
WP-00 support files, `Package.*`, shared indexes, or another lane's files.

## Implementation

### U1. Adopt the compact rail vocabulary

In `WindowTopLeftControlCluster` and `WorkspaceUtilityRail`, replace the local
icon-button treatment with WP-00's `RafuRailButtonStyle`:

- retain 30 pt targets, tooltips, labels, badges, keyboard/menu routes, and
  selected traits;
- retain the existing sidebar-collapse motion and Reduce Motion behavior;
- add no decorative selection animation;
- keep `WorkspaceSidebarRail` itself as a drag-handle column with no button
  style.

Selected state must remain recognizable by close-fit shape, boundary, stronger
foreground, and deck-facing inset bar without hue.

### U2. Consolidate the host and concrete headers

In `WorkspaceUtilityPanelView`:

- use solid `elevatedBackground` inside the deck; right rail remains
  `sidebarBackground`;
- remove the old generic uppercase `panelHeader`;
- preserve top-pinned body alignment and width behavior;
- route `.sourceControl` unconditionally through a new
  `SourceControlPanelView`, not an outer `gitSnapshot` branch.

Each concrete surface owns exactly one WP-00 `RafuUtilityPanelHeader` with a
close action that sets the session mode back to Files:

- Search;
- Source Control, in repository and no-repository states;
- Ensemble;
- Terminals, supplied by WP-30.

When this isolated branch is tested against the foundation without WP-30, the
old terminal count header remains sufficient for compilation and utility-rail
closure. Do not edit the terminal file to complete it. The coordinator merges
WP-30 first and performs the terminal-header visual gate on the combined tree.

### U3. Search hierarchy

Keep query dominant in the first row and recent/run actions trailing. Put
include/exclude inside `DisclosureGroup("File filters")`:

- collapsed by default only when both values are empty;
- forced open whenever either value is non-empty;
- case, whole-word, and regex stay on one compact labelled row;
- preserve history, cancellation, results, replacement safety, focus, and
  keyboard actions;
- use `RafuPanelEmptyState` with no misleading primary action.

### U4. Source Control wrapper and density

`SourceControlPanelView` owns the one header/close action and branch/upstream
context for both states:

- no repository: shared empty state plus existing explicit
  **Initialize Repository** action;
- clean repository: quiet **No Changes** empty state, no creation CTA;
- changed repository: existing Changes/Worktrees/History, staging, history,
  worktree, stash, branch, and commit behavior.

Within `GitInspectorView`:

- left-align the three-way switcher at the 8 pt body inset;
- use 40 pt minimum change rows;
- reduce redundant full-width separators;
- keep the composer bottom-pinned with 8 pt outer inset and
  `radiusDenseCard`;
- retain AI streaming, scope disclosure, hygiene warning, explicit commit,
  progress/error, and all Git confirmation boundaries.

No automatic Git action and no service/process edit is permitted.

### U5. Ensemble Runs and New Run canvas

In `ConductorRunsPanelView`:

- one primary title, **Ensemble**;
- retain Runs/Workflows/Activity as the real second row;
- use shared empty states;
- make **New Run…** use the shared prominent creation treatment;
- keep header actions, routes, graph, library, events, gates, and launch
  behavior;
- apply the shared attached canvas tab to `ConductorNewRunCanvas` in this file;
- keep the New Run common measure and behavior unless the parent plan explicitly
  says otherwise.

No new visible string may say “Conductor.”

### U6. Native branch popover

In `RafuSearchableDropdown` and its Git/status-bar call sites:

- use `radiusTransientPopover`;
- target 340 pt width, 160 pt minimum, 420 pt maximum height;
- search field 28–30 pt; rows 30 pt; selected row radius 4 pt;
- distinguish current checkmark from keyboard highlight;
- full branch name in `help`, middle truncation only in narrow triggers;
- retain native AppKit popover placement and keyboard navigation.

Verify the status-bar trigger stays on-screen near each screen edge. Do not
replace the popover with a custom overlay.

### U7. Tests

Pin:

- one primary header per concrete mode and top-pinned empty content;
- no-repository/clean/changed Source Control CTA rules;
- Search disclosure state from include/exclude values;
- shared empty-state action rules and remaining-body centering;
- solid utility surface and rail-style adoption;
- Ensemble one-title/three-mode grammar and New Run attached tab;
- branch popover geometry, current/highlight distinction, full-name help, and
  existing keyboard filtering.

Run, but do not edit, Search/Git/Conductor behavior suites.

## Acceptance and manual evidence

Focused checks:

```bash
./script/test.sh --filter \
  'RafuSearchableDropdown|StatusBarBranchFormatter|SearchGlob|SearchHistory|SearchService|GitChangeTree|GitTreeBadge|WorkflowPresentation|ConductorRunsPanelPresentation|UtilityPanelPresentation'
```

At minimum/ideal utility widths capture Search empty/results/filter-open,
Source Control no-repository/clean/changes, and Ensemble empty/list. Headers
remain top-pinned; primary nouns appear once; empty-state center is within 12 pt
of the remaining body's midpoint; composer remains bottom-pinned.

Verify branch popover from window/screen edges, keyboard-only Search/filter/Git/
composer/branch/Runs flows, and VoiceOver order from header/context to body.
Exercise every rail button in rest/hover/pressed/selected/disabled states and
confirm VoiceOver selected state, badge, tooltip, and deck-facing marker remain
coherent without hue. Capture Indigo, Khadi, converged surfaces, Increase
Contrast, and default plus largest supported accessibility text sizes. The
combined merge-round pass also verifies WP-30's terminal header.

## Verification and handoff

Complete all edits before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Use the single Rafu Lightning GUI lease or hand off exact deferred states.
Commit only owned paths, do not push, and remove `.build` after the green
commit.

## Implementation record

- **Status:** Implemented on `codex/presentation-utility-panels`.
- The utility host is now headerless and solid, while Search, Source Control,
  and Ensemble each own one concrete, top-pinned
  `RafuUtilityPanelHeader`. The sidebar toggle and utility activity rail use
  the shared rail style without decorative selection animation.
- Search keeps the query dominant, exposes labelled case/word/regex controls,
  and places include/exclude fields in a disclosure that cannot collapse while
  either filter is active. Search, Source Control, and Ensemble use the shared
  empty-state grammar without inventing actions.
- `SourceControlPanelView` owns both repository states. Repository context,
  explicit Git operations, changes/worktrees/history, commit drafting, and
  repository initialization retain their existing user-action boundaries.
- Ensemble keeps its Runs/Workflows/Activity modes and actions under one
  header; New Run uses the attached workbench-tab seam.
- The branch selector remains a native `.popover`, with bounded geometry,
  independent current/highlight presentation, middle truncation, and full
  branch names in help/accessibility text.
- Focused Search/Git/Runs/dropdown/presentation verification passed: 68 tests,
  0 failures.
- The shared Rafu Lightning identity was already running without this lane
  holding the coordinator GUI lease. The complete utility-width, panel-state,
  branch-edge, keyboard-only, VoiceOver, rail-state, Indigo/Khadi, contrast,
  accessibility-text-size, and WP-30 terminal-header matrix is therefore
  deferred explicitly to the post-WP-30 merge-round lease.
- No ADR changed, no reusable platform nuance was discovered, and no reference
  note or reference-index row is intended.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-40's unified Rafu utility-panel presentation across rails,
Search, Source Control, Ensemble Runs, New Run, and the native branch popover,
preserving all feature behavior; verify and commit it locally."

You are in the dedicated worktree on branch
codex/presentation-utility-panels. Use gpt-5.6-sol with high reasoning.

Read AGENTS.md; the execution README; WP-00; WP-40;
pre-initial-push-workbench.md; the named parent-plan sections; ADRs 0002, 0012,
0018, 0022;
searchable-dropdown-component.md; the relevant hierarchy rules in
settings-surface.md; and skill-routing.md. Use swiftui-expert-skill and macOS
swiftui-patterns.

Run `git status --short --branch`. Stop unless this is
codex/presentation-utility-panels, clean, the initial `git rev-parse HEAD`
equals the coordinator-supplied exact `<FOUNDATION_SHA>`, and the
ConductorRunsPanelPresentationTests split exists. Touch only WP-40-owned paths.
Do not edit the terminal panel/session, Ensemble composer/graph/detail, service
or process code, shared styles, Package.swift, or shared indexes.

Adopt the shared rail style; remove the generic outer utility header; make each
owned concrete panel use one shared header and empty-state grammar; add
SourceControlPanelView for both repository states; compact Search/Git/Runs
without changing behavior; apply the attached tab to New Run; and keep the
branch picker a native bounded popover. Never add automatic Git/Search/Run
behavior or a user-visible “Conductor” string. Do not touch the terminal file;
WP-30 supplies its final header before your branch is merged.

Add the exact tests and manual/accessibility states in WP-40. Use the single
Rafu Lightning GUI lease or report precise deferrals.

Complete all changes before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change afterward. When holding the single GUI lease, run
`./script/build_and_run.sh --verify` and complete the manual matrix; otherwise
report the exact deferral. Stage only owned paths and create one local commit.
Do not push, merge, open a PR, or publish. After green gates and the successful
commit, remove only this dedicated worktree's `.build`; never remove the
primary checkout's cache. Report delivered behavior, SHA, paths, gate results,
panel-state and popover evidence, keyboard/VoiceOver/theme results, ADR/
reference updates, the terminal-header merge dependency, deferred checks,
risks, any intended reference-index row, and the next dependency (merge after
WP-30). Complete the Goal only after commit and handoff.
```
