# TG-40 — Terminal Manager hierarchy and group switcher

## Status and execution slot

- **Status:** Implemented on lane; awaiting authorized merge.
- **Wave:** 4; parallel with TG-41 and TG-42.
- **Branch:** `terminal-groups/tg-40-manager-switcher`.
- **Required base:** exact `<TG30_MERGED_SHA>`.
- **Prerequisite:** TG-30 workspace API is frozen.
- **Next dependency:** TG-90 starts after all Wave 4 branches merge.

## Goal

Present Terminal Groups, child panes, and saved layouts as one clear hierarchy
in the Terminal Manager. Make Control-Tab represent each visible or parked
group once and restore the correct focused pane.

Preserve all runtime, process, attention, save, and workspace behavior. This
lane is a presentation and action-routing consumer of the TG-30 API.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-40-manager-switcher.md`
4. `docs/plans/phases/terminal-groups.md`
5. `docs/plans/phases/pre-initial-push-workbench.md`
6. `docs/decisions/0004-embedded-terminal.md`
7. `docs/decisions/0014-terminal-as-editor-tab.md`
8. `docs/decisions/0018-conductor-external-agent-orchestration.md`
9. `docs/decisions/0021-agent-terminals.md`
10. `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
11. `docs/plans/phases/editor-terminal-tabs.md`
12. `docs/plans/phases/terminal-manager.md`
13. `docs/plans/phases/terminal-groups/TG-30-workspace-integration.md`,
    including its implementation record
14. `docs/references/skill-routing.md`
15. `docs/references/build-and-run.md`

Then read these lane-specific files:

- `Sources/RafuApp/Terminal/TerminalsPanelModel.swift`;
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`;
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift`;
- `Sources/RafuApp/Views/EditorTabSwitcherView.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupModel.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupRestorationCodec.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift` as read-only;
- the frozen Terminal Group API and candidate generation in
  `Sources/RafuApp/Models/WorkspaceSession.swift`;
- `Sources/RafuApp/Terminal/TerminalSessionColor.swift`;
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`;
- `Tests/RafuAppTests/TerminalsPanelTests.swift`;
- `Tests/RafuAppTests/TerminalIdentityTests.swift`;
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`;
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`;
- `docs/references/window-scoped-modifier-key-switcher.md`;
- `docs/references/terminal-signals-and-shell-catalog.md`;
- `docs/references/ui-design-language.md`; and
- `docs/references/scrollview-legacy-scroller-always-setting.md`.

Use the project-local `swiftui-expert-skill`. Read its complete `SKILL.md`,
`latest-apis.md`, `state-management.md`, `view-structure.md`,
`layout-best-practices.md`, `list-patterns.md`, `focus-patterns.md`,
`accessibility-patterns.md`, and `macos-views.md`. Use Build macOS Apps
`swiftui-patterns`; read its complete `SKILL.md` and `components-index.md`.
If this lane adds task or cross-actor behavior, also use the root
`swift-concurrency-pro` review path.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Terminal/TerminalsPanelModel.swift`;
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`;
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift`;
- `Sources/RafuApp/Views/EditorTabSwitcherView.swift`; and
- new `Sources/RafuApp/Views/TerminalGroupSavedLayoutsSection.swift`.

### Test paths

- `Tests/RafuAppTests/TerminalsPanelTests.swift`;
- `Tests/RafuAppTests/TerminalIdentityTests.swift`;
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`;
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupManagerHierarchyTests.swift`; and
- new `Tests/RafuAppTests/TerminalGroupSwitcherPresentationTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-manager-switcher.md`, only for a
  new reusable list, switcher, focus, or accessibility fact.

All other paths are read-only. Do not edit `WorkspaceSession`, runtime,
renderer, store, editor canvas, commands, save sheet, Agent/Ensemble code,
`Package.*`, ADR, or shared index.

## Implementation contract

### M1. Pure hierarchy model

Replace the flat presentation row model with stable rows for:

- group header;
- live, exited, stopped, or unavailable child pane; and
- saved layout.

Derive the model from frozen group snapshots, controller presentation data,
parked group IDs, and saved records. Do not dual-bookkeep expanded, parked,
current, attention, or selected session state.

Keep user expansion state by stable group ID. A model refresh must not reset an
unrelated expanded group or rename field.

### M2. Group row

A group row shows:

- group name;
- pane count and live count;
- visible or parked state;
- aggregate attention count;
- saved or unsaved state from the optional saved-layout identity;
- focused/current state; and
- actions for Reveal, Hide Group, Rename, Save, Start All Restartable Panes,
  and Close Group when valid.

Every action has a visible trailing or menu path and an accessibility label.
Color does not carry state alone. Close Group routes through TG-30 confirmation
and does not call the manager directly.

### M3. Pane row

A child row shows pane name, provider or shell, folder, status, color, focus,
and attention. Actions route through the frozen workspace API:

- Reveal and Focus;
- Close Pane;
- Restart exited shell;
- Start Pane for safe stopped shell;
- rename/color through existing pane/session methods when allowed; and
- the exact fixed Agent or Ensemble message from TG-10, derived from the
  unavailable saved-pane kind.

Clicking a child row reveals the outer group and focuses that exact pane. It
does not create a duplicate tab or session.

### M4. Saved layouts section

Add a top-pinned or clearly separated Saved Terminal Groups section. Each row
shows name, pane count, and Open/Delete actions. Opening creates an inert group
with fresh runtime IDs through `WorkspaceSession`; two Opens are independent.
Deleting does not close a live group that came from that layout. The workspace
API detaches every open instance, which then presents as unsaved.

Empty, loading, and store-error states expand correctly under the AGENTS panel
alignment rule. Do not read the store from `body`.

### M5. Control-Tab group candidates

Update switcher types and view for one group candidate:

- one visible group once;
- one parked group once;
- group name and pane count;
- aggregate attention and parked label;
- current focused pane summary as secondary text; and
- activation that reveals/selects the group and focuses its last focused
  runtime pane.

Keep file and other editor-tab candidates unchanged. Left/Right browse,
Control release/Return commit, reverse traversal, and Escape cancellation
remain unchanged. Do not list each pane or child session.

### M6. Accessibility and density

VoiceOver must identify row level, group/pane name, current/focused state,
parked state, status, attention count, derived unavailable message, and action.
Full Keyboard Access reaches expansion, rows, and menus in visual order.

Keep the panel top-pinned and usable at 250, 310, and 460 pt widths. Larger
text can expand row height. Do not add decorative row animation.

## Tests

Pin:

- one group with one, several, exited, stopped, and unavailable panes;
- two groups with independent expansion and current state;
- parked and visible derivation;
- group and pane attention separation;
- reveal exact pane without duplicate tab/session;
- Hide Group and Close Group routing;
- saved/unsaved state, two independent Opens, and Delete detachment;
- empty/loading/error states;
- one Control-Tab candidate per visible/parked group;
- file candidate compatibility;
- forward/reverse/cancel/commit behavior; and
- complete accessibility values without hue.

Run read-only Terminal Group integration, attention, workspace-close, command
palette, and Notch Companion filters.

## Manual acceptance

Under the Rafu Lightning GUI lease, verify:

- panel widths 250, 310, and 460 pt;
- one and several groups, expanded and collapsed;
- live, exited, stopped, unavailable, focused, parked, and attention rows;
- exact pane reveal/focus and group hide/close;
- saved layout open and delete;
- Control-Tab forward/reverse/cancel/commit with files and parked groups;
- two windows;
- keyboard-only operation and VoiceOver; and
- Indigo, Khadi, Increase Contrast, and largest supported text.

## Verification and handoff

Complete all changes and the implementation record before the common final
sequence. After the parallel suite, run Rafu Lightning under the shared GUI
lease or list every exact deferred state. Run `git diff --check`, commit only
TG-40 paths, and remove this worktree's `.build` after the green commit.

The handoff reports hierarchy and candidate mappings, exact action routing,
accessibility/manual evidence, tests, warnings, paths, branch, commit message,
SHA, next dependency, and **Deviations**.

## Implementation record

Implemented the Terminal Manager as a stable group-and-pane hierarchy derived
only from TG-30 snapshots, controller presentation data, presented group IDs,
and saved-layout records. Expansion is local state keyed by group ID. Group
and pane actions use the frozen `WorkspaceSession` routes; pane activation
reveals its outer group and focuses its exact pane.

Pane rows include provider or shell, folder, status, color-capable controller
actions, focus, and attention. Unavailable panes are inert and use the fixed
TG-10 saved-profile messages through `TerminalPanePresentation`. Sessions
not yet assigned to a Terminal Group remain on the legacy row path, once each.
Group and pane action menus show only valid actions.

Legacy-row derivation receives its presented IDs, current ID, and workspace
root, so it preserves the existing visible, parked, current, and relative
folder behavior. Pane status is separate from provider/shell, and a named
color label is visible and accessible. Group Save and saved-layout Open/Delete
controls are disabled while a store mutation is in progress.

The Saved Terminal Groups section reads the already-observed workspace values.
It does not start store reads from its view body. An authorized TG-30
dependency correction added the observed, generation- and epoch-guarded
`WorkspaceSession.isTerminalGroupStoreLoading` value. The section has a
bounded scroll area for up to 32 records. Its Open and Delete actions use the
frozen workspace routes, so independent inert instances and deletion
detachment remain owned by TG-30.

Control-Tab retains its group destination identity and now presents each group
with pane count, parked state, focused-pane summary, and aggregate attention.
The existing candidate generator still lists each visible or parked group once.

Added behavior tests for derived group/pane state, unavailable-message mapping,
legacy compatibility, exact reveal/focus without a duplicate outer tab,
independent saved opens followed by deletion detachment, and group-only
switcher candidate/commit/cancel behavior with a file candidate. A pure saved
layout state model covers loading, empty, error, and records; the focused
workspace test proves the initial empty-result transition. A pure switcher
presentation model covers aggregate attention and focused-pane text. The
authorized WorkspaceSession loading-value test proves current-load completion
does not leave a stale loading state. The Terminal Manager source-contract audit
now checks the hierarchy resolver's `currentGroupID` and
`currentLegacySessionID` inputs, rather than the removed legacy row-local
variables. Parser and diff checks pass.

**Verification deviations:** an earlier build and test command overlapped; the
coordinator terminated the queued test and required a clean sequential rerun.
An initial full parallel-suite diagnostic lost its failure names to terminal
output truncation, so one coordinator-authorized full rerun wrote its output to
`/tmp/rafu-tg40-final-suite.log`. That rerun identified the stale owned
source-contract audit corrected above. No production behavior was changed by
that correction.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-40 from
docs/plans/phases/terminal-groups/TG-40-manager-switcher.md: present Terminal
Groups, child panes, and saved layouts as one accessible Terminal Manager
hierarchy and make Control-Tab switch each group once; preserve runtime and
workspace behavior, verify, and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run
`git switch terminal-groups/tg-40-manager-switcher` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-40-manager-switcher, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG30_MERGED_SHA>`.
Do not create or replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-40-manager-switcher.md;
docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/0023-terminal-groups-and-saved-layouts.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/plans/phases/terminal-groups/TG-30-workspace-integration.md, including its
implementation record; docs/references/skill-routing.md;
docs/references/build-and-run.md; and every lane-specific source, test, and
reference path in TG-40. Read and use the complete project-local
swiftui-expert-skill and the exact latest API,
state, structure, layout, list, focus, accessibility, and macOS view references
in TG-40. Read and use Build macOS Apps swiftui-patterns and its components
index. Use root swift-concurrency-pro only if task or actor behavior changes.

Edit only TerminalsPanelModel.swift, WorkspaceTerminalsPanelView.swift,
EditorTabSwitcher.swift, EditorTabSwitcherView.swift, new
TerminalGroupSavedLayoutsSection.swift, TG-40-owned tests, this plan's record,
and conditional docs/references/terminal-group-manager-switcher.md only when
its documented trigger applies. Treat WorkspaceSession, runtime,
renderer, store, editor canvas, commands, save sheet, Agent/Ensemble code,
Package.swift, ADRs, and shared indexes as read-only.

Implement M1 through M6. Use stable group and pane rows. Route every action
through the frozen workspace API. Reveal a child by revealing one outer group
and focusing one exact pane. Show saved layouts without reading from body.
Control-Tab lists each visible or parked group once, never each pane. Preserve
all file candidate and switcher commit/cancel behavior.

Add the exact tests and run the named read-only regressions. Use one SwiftPM
invocation at a time. Isolate failures and never edit an unowned failure.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Under the shared GUI lease, run Rafu Lightning and the TG-40 manual
matrix or report exact deferrals. Run `git diff --check`.

Stage only TG-40 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm clean status, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Report hierarchy/candidate behavior, paths, focused/full tests, warnings,
Rafu Lightning/manual/accessibility evidence, risks, reference need, branch,
commit message, SHA, and next dependency. Include Deviations with `None` when
none. Complete the Goal only after commit and full handoff.
```
