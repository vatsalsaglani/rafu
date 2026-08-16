# TG-30 — Workspace, editor-tab, and restoration cutover

## Status and execution slot

- **Status:** Implemented on lane; awaiting authorized merge.
- **Wave:** 3; serial integration plan.
- **Branch:** `terminal-groups/tg-30-workspace-integration`.
- **Required base:** exact `<WAVE2_MERGED_SHA>`.
- **Prerequisites:** TG-20, TG-21, and TG-22 are merged.
- **Next dependency:** TG-40, TG-41, and TG-42 start from the merged TG-30
  commit.

## Goal

Replace the active one-session terminal-tab presentation with one compound
Terminal Group tab. Connect runtime, renderer, editor layout, workspace
restoration, lifecycle, attention, and saved-layout actions through one
window-owned `WorkspaceSession`.

At the end of TG-30, all UI `WorkspaceSession` Terminal Group
methods are frozen for Wave 4. Later parallel lanes consume them without
editing `WorkspaceSession`.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-30-workspace-integration.md`
4. `docs/plans/phases/terminal-groups.md`
5. `docs/plans/phases/pre-initial-push-workbench.md`
6. `docs/decisions/0004-embedded-terminal.md`
7. `docs/decisions/0014-terminal-as-editor-tab.md`
8. `docs/decisions/0018-conductor-external-agent-orchestration.md`
9. `docs/decisions/0021-agent-terminals.md`
10. `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
11. `docs/plans/phases/editor-terminal-tabs.md`
12. `docs/plans/phases/terminal-manager.md`
13. `docs/plans/phases/terminal-groups/TG-20-runtime.md`, including its
    implementation record
14. `docs/plans/phases/terminal-groups/TG-21-renderer-focus.md`, including its
    implementation record
15. `docs/plans/phases/terminal-groups/TG-22-persistence.md`, including its
    implementation record
16. `docs/references/skill-routing.md`
17. `docs/references/build-and-run.md`

Then read these lane-specific files:

- `Sources/RafuApp/Models/WorkspaceSession.swift`, completely;
- `Sources/RafuApp/Views/EditorCanvasView.swift`, completely;
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`, completely;
- `Sources/RafuApp/Editor/EditorLayout.swift`;
- `Sources/RafuApp/Editor/EditorCanvasRoute.swift`;
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupView.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupSplitView.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRestorationCodec.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift`;
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`;
- `Sources/RafuApp/Terminal/TerminalAttentionCenter.swift`;
- `Sources/RafuApp/Terminal/TerminalsPanelModel.swift` as read-only;
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift`;
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`;
- `Sources/RafuApp/App/RafuAppCommands.swift` as read-only;
- `Sources/RafuApp/Views/CommandPaletteView.swift` as read-only;
- `Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift` as
  read-only;
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift` as
  read-only;
- every test file in the ownership section below;
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`;
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`;
- `Tests/RafuAppTests/EditorThemeColorApplicationTests.swift`;
- `Tests/RafuAppTests/AgentTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/EnsembleCoordinatorLaunchTests.swift`;
- `docs/references/editor-window-close-resolution-order.md`;
- `docs/references/editor-canvas-routing.md`;
- `docs/references/workspace-lifecycle-dual-funnel.md`;
- `docs/references/editor-search-and-restoration.md`;
- `docs/references/terminal-signals-and-shell-catalog.md`;
- `docs/references/window-scoped-modifier-key-switcher.md`; and
- `docs/references/memory-attribution-and-timeline.md`.

Use these skills and named references:

1. project-local `swiftui-expert-skill`: complete `SKILL.md`,
   `latest-apis.md`, `state-management.md`, `view-structure.md`,
   `layout-best-practices.md`, `focus-patterns.md`,
   `accessibility-patterns.md`, `macos-scenes.md`, and `macos-views.md`;
2. root project-local `swift-concurrency-pro`: complete `SKILL.md`,
   `actors.md`, `structured.md`, `async-streams.md`, `cancellation.md`, `interop.md`,
   `bug-patterns.md`, and `testing.md`;
3. Build macOS Apps `swiftui-patterns`: complete `SKILL.md` and
   `split-inspectors.md`;
4. Build macOS Apps `window-management`: complete `SKILL.md` and
   `api-snippets.md`; and
5. Build macOS Apps `build-run-debug`: complete `SKILL.md`.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Models/WorkspaceSession.swift`;
- `Sources/RafuApp/Views/EditorCanvasView.swift`; and
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`.

### Test paths

- `Tests/RafuAppTests/TerminalEditorTabTests.swift`;
- `Tests/RafuAppTests/WorkspaceCloseActionTests.swift`;
- `Tests/RafuAppTests/TerminalAttentionTests.swift`;
- `Tests/RafuAppTests/EditorTabAndGroupPresentationTests.swift`;
- `Tests/RafuAppTests/EditorTabVisibilityPresentationTests.swift`;
- `Tests/RafuAppTests/EditorThemeColorApplicationTests.swift`;
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`;
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`;
- `Tests/RafuAppTests/AgentTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/EnsembleCoordinatorLaunchTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupSessionIntegrationTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupRestorationIntegrationTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupCloseIntegrationTests.swift`; and
- new `Tests/RafuAppTests/TerminalGroupAttentionIntegrationTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-workspace-restoration.md`, only for
  a new reusable workspace, restoration, window, or actor fact.

All other paths are read-only. Do not edit the runtime, renderer, store,
editor-layout contract, commands, panel, switcher source, Agent/Ensemble caller,
`Package.*`, ADR, shared index, or another lane test. If a Wave 2 API cannot
support this cutover, stop and report the contract defect. Do not patch a
foreign foundation file in this plan.

## Implementation contract

### W1. Window-owned integration

Keep exactly one `WorkspaceTerminalManager` per `WorkspaceSession`. Each
session binds to the one process-wide TG-22 saved-layout store actor for the
current app identity and base root. Install callbacks once with weak capture.
Do not put a group or controller in global state.

Expose read-only values for:

- selected/focused group and pane;
- focused terminal session;
- current terminal session for Terminal Manager presentation;
- presented group IDs and session IDs;
- parked groups in MRU order;
- live slot count and capacity error;
- saved layouts and store error; and
- pending group-close and save requests.

### W2. New group and split actions

Add surface methods with stable names for TG-40/TG-41:

- new Terminal Group;
- split focused pane right/down;
- focus pane left/right/up/down;
- focus exact pane;
- rename group;
- set a pane's starting folder to a user-selected folder inside the workspace;
- set divider fraction;
- close pane;
- request/confirm/cancel group close;
- hide/reveal group;
- save/save-as request and completion;
- open/delete saved group;
- start pane/start all restartable panes; and
- restart exited shell pane.

The close-pane surface method must use prepare, caller-owned coordinator or
role cleanup, and generation-checked finalize. It must not expose or call a
direct membership-mutating close command. Group close uses the same boundary
after its existing confirmation path.

`newTerminalTab()` remains source-compatible but routes to a new one-pane
group and preserves the current safe start-directory policy. Split actions
inherit the focused restartable pane's stored starting folder, or use the
workspace root for a nonrestartable pane. They never inspect a live working
directory. `toggleTerminal()` parks the selected group. Otherwise it reveals
the most recently parked group, or creates a group when none is parked.
`hideTerminalSession`,
`closeTerminalSession`, and `revealTerminalSession(_:)` remain compatible.

Starting-folder validation standardizes and resolves symlinks for both the
workspace root and selected directory, requires an existing readable
directory, and rejects traversal or resolved escape. Store only the normalized
workspace-relative value. Revalidate it before Start Pane, Restart, Split, and
Start All because a symlink can change after Save.

`openAgentTerminal(spec:)` keeps its current caller signature for the sheet,
palette, and Terminal Manager. It now uses the throwing aggregate insertion
API and assigns the direct-Agent nonrestartable classification inside
`WorkspaceSession`. A temporary unassigned Ensemble session from an old caller
becomes a new one-pane group when `revealTerminalSession(_:)` runs. This keeps
Ensemble callers functional before TG-42 removes direct manager mutation.

### W3. Editor resource and one-tab presentation

New outer tabs use `.terminalGroup(groupID:)`. Render the selected group's
snapshot with `TerminalGroupView`. One tab label shows:

- group name;
- terminal-group glyph;
- total pane count when greater than one;
- aggregate attention count; and
- close action for the complete group.

Double-click rename uses the same trim/default rule as the runtime. The tab can
move across existing editor groups as one resource. Internal panes never
become editor tabs and cannot be mirrored.

Keep a guarded legacy `.terminal(sessionID:)` render path during migration.
It must not be used for newly created terminals.

### W4. Focus and attention

Pass one focused-pane identity and action closure into the renderer. A pointer
focus callback and directional focus command update the manager before they
request AppKit focus. Selecting a terminal group restores focus to its last
focused pane.

Bell attention stays per session/pane. The outer tab aggregates the number of
child panes with attention. Revealing or focusing one pane clears only that
pane's attention under the existing policy. Existing notification, notch HUD,
companion, and reply routing continue to identify the session UUID.

### W5. Hide, close, and teardown

- `Control-backtick`-level toggle methods park or reveal the complete group.
- Pane close ends only its session and collapses the tree.
- Last-pane close requests group close.
- Group close with one or more actual live processes presents one confirmation
  with that process count. Attention and capacity reservations do not affect
  the count.
- Close first requests the generation-checked preparation token. Confirmed
  group close prepares again before any cleanup. If the affected session set
  or live-process count changed while the confirmation was open, refresh the
  sheet and require confirmation again. Otherwise call existing coordinator or
  role cleanup in the fresh token order, immediately finalize manager
  shutdown/membership mutation without suspension, then remove the outer tab.
  Failed or stale revalidation performs zero cleanup and asks the user to
  retry.
- Exited-only group close does not claim that it will stop a live process.
- Workspace switch, window close, and app quit collect grouped and temporary
  legacy session cleanup in stable order, invoke every registered role and
  coordinator cleanup exactly once, and only then shut down controllers and
  clear manager membership. They use the same cleanup helper as confirmed
  group close and do not bypass it with a direct `shutdownAll()` call.

Preserve the current generic editor close resolution: focused tab first, then
diff, then window. `Command-W` still closes one selected outer tab, not one
internal pane.

### W6. Capacity and error presentation seam

All WorkspaceSession ordinary-shell and direct-Agent creation routes through
the manager preflight. The two read-only Ensemble callers retain the temporary
adapter until TG-42. On capacity or validation failure, keep layout, group
tree, focus, and process resources unchanged. Expose one bounded error value
for the existing alert system or a new group-specific alert in
`WorkspaceWindowView`.

Apply the separate 24-retained-pane preflight to New Terminal Group, Split,
legacy-session wrapping, and Open Saved Group. A rejection leaves the editor
layout and saved record unchanged and does not construct a controller.

**Start All Restartable Panes** targets stopped ordinary-shell panes and
leaves unavailable Agent or Ensemble placeholders unchanged. Start Pane or
Start All on a parked group reveals it before pending-start state is applied so
the target panes can mount. Validate all target folders, shells, pane bounds,
and slots before any controller exists; a preflight failure starts zero panes.
After preflight, normal lazy view mounting starts each pane. An external spawn
or shell startup failure is a per-pane exited/error result and does not roll
back other panes. Do not claim transactionality for external process side
effects.

### W7. Saved-layout integration and inert restore

`WorkspaceSession` uses the shared injected TG-22 store actor. Save and Save As
persist a safe named snapshot while live panes continue unchanged.
First Save and Save As attach the returned `SavedTerminalGroupID` to the
current open instance. A successful Save As leaves the old named record
unchanged and renames the open group to the validated new saved-layout name.
Apply the new ID and name only after the store succeeds. A failed or stale
completion changes neither the group name nor its saved-layout association.
Later Save writes the current group name and content to the same ID.

The Application Support store is authoritative for named-layout existence,
listing, explicit Open content, Save, Save As, and Delete. The workspace
restoration payload holds only safe state and editor placement for one
specific open instance. It never writes a named record. Delete clears the
matching `SavedTerminalGroupID` from every open instance without closing it;
those groups become unsaved and stale restoration data cannot resurrect the
deleted named layout.

When a shared-store revision reload shows that a saved ID no longer exists,
detach that ID from every matching open instance in that receiving window.
Do not close or otherwise replace those groups. Thus Delete in one window also
detaches instances in every other window on the same workspace. An update to a
record that still exists does not replace an open instance's runtime layout.

Only explicitly saved groups can restore an outer tab across relaunch. During
workspace persistence:

- include safe open-instance records with their already-unique runtime IDs;
- retain outer editor-tab placement only for groups with a saved-layout ID;
- drop unsaved group resources from the restorable editor layout; and
- do not persist a live session ID.

During restore:

1. resolve the workspace bookmark;
2. load the authoritative named-layout store;
3. accept an open-instance restoration record only when its
   `SavedTerminalGroupID` still exists, then insert its inert snapshot with
   zero controllers;
4. restore editor layout and keep only group resources with a matching valid
   snapshot; and
5. select the restored focused runtime pane ID after re-keying, without
   requesting process start.

A bad group record drops only that group resource and shows a bounded error. It
must not clear file tabs or the complete workspace restoration payload.
Remove invalid group tabs in their saved positions without reordering
surviving tabs. If an invalid tab was selected, use the existing
nearest-surviving-tab selection rule. If its editor group becomes empty,
collapse that split leaf and repair focused editor-group identity through
`EditorLayoutState`.

Both `openLocalWorkspace(at:)` and `restoreLastWorkspaceIfAvailable()` cancel
or invalidate the previous saved-layout load, clear the old workspace's list
and store error, close its grouped sessions through the normal teardown path,
then load the standardized new root. Apply an async load result only when its
workspace generation still matches. A stale result cannot repopulate another
workspace or window.

Every async Save, Save As, Delete, initial load, and revision-triggered list
operation captures the workspace generation and its exact target runtime group
ID and/or saved-record ID before awaiting the actor. Apply its returned ID,
name, detachment, list, or error only when the generation and target identity
still match. Cancel all session-owned store tasks on workspace/window teardown.
Actor cancellation does not claim to undo an atomic write that already
committed; the stale completion still cannot mutate the new workspace UI.

Use a newest-request epoch for initial and revision-triggered list loads, so an
older response from the same workspace generation cannot replace a newer list
or error. Allow only one saved-layout mutation task per `WorkspaceSession` at a
time. Disable Save, Save As, and Delete mutation routes while it is active,
increment a mutation epoch on start or cancellation, and apply completion only
when that epoch also matches. The process-wide store actor still serializes
mutations from different windows.

Subscribe once per active workspace generation to the shared store's bounded
change stream before requesting the first list. The store registers the
continuation and emits its current revision before returning, so a mutation at
the subscribe/list boundary cannot be missed. A matching newer revision
triggers a fresh list; a different workspace does not. Cancel the subscription
on workspace switch, window close, and deinit. Thus two windows on one
workspace see each other's successful Save/Save As/Delete without sharing
runtime group state.

### W8. Control-Tab candidate seam

Change candidate generation to include one Terminal Group once, plus parked
groups once. The candidate selects/reveals the outer tab and restores its
focused pane. It does not add one entry per child session.

TG-10 owns the `.terminalGroup(groupID:)` destination case. TG-30 owns group
candidate data and activation behavior. TG-40 owns final switcher view and
label presentation.

### W9. Surface contract for Wave 4

Freeze all public/session methods needed by:

- TG-40 group/pane rows, saved-layout rows, and switcher;
- TG-41 menu, palette, save sheet, and contextual Save; and
- TG-42 Agent and Ensemble classified session insertion.

Include one throwing classified process-session insertion method that lets
TG-42 state Ensemble role or coordinator nonrestartable kind without exposing
group tree mutation. Capacity failure occurs before the caller mints a token
or publishes run state. Keep `openAgentTerminal(spec:)` as the direct-Agent
adapter for all current UI callers.

The classified insertion method accepts the existing lane lifecycle callback.
`WorkspaceSession` owns one callback registration per session and consumes it
exactly once on natural exit or a user-driven pane, group, workspace, or window
close. The user-driven close path invokes it before manager finalize. Natural
exit invokes it after the shared terminal exit handler. An owner-driven role
abort uses a separate close disposition that removes the registration without
invoking it because the run controller performs its own state transition.
There is no second callback installed directly on the terminal controller.

Also expose a narrow reserve/consume/cancel wrapper for the Ensemble
coordinator. The reservation contains no process spec or capability. Window
teardown and caller cancellation release it.

## Tests

Add or update focused tests for:

- new shell opens as one group and one pane;
- new group starts in the selected in-workspace file directory and falls back
  to the workspace root;
- split adds a pane, not an editor tab;
- mixed tree rendering and group tab identity;
- pointer and keyboard focus state;
- aggregate/per-pane attention clearing;
- hide/reveal same group and sessions;
- pane close and split collapse;
- last-pane and group close confirmation/count/cleanup;
- stale-during-confirmation revalidation refreshes changed details and performs
  zero cleanup before a new confirmation;
- six-pane and six-live-session limits;
- 24-retained-pane success and no-mutation rejection;
- Start All Restartable Panes zero-start preflight and per-pane external
  failure state;
- explicit starting-folder update, split inheritance, and no live-CWD read;
- symlink escape rejection at selection and after a saved link changes before
  start;
- legacy session reveal wraps one one-pane group;
- one Control-Tab candidate per visible or parked group;
- two Opens of one named layout have disjoint runtime IDs;
- delete detaches open instances and stale restoration does not resurrect it;
- Delete in a second window refreshes the first window and detaches all of its
  matching open instances without closing them;
- Save, Save As, and safe store error seams;
- successful Save As renames only its target open group; stale Save, Save As,
  and Delete completions cannot attach, detach, rename, list, or report an
  error after workspace switch or target replacement;
- out-of-order list results in one generation keep the newest request, and an
  in-flight saved-layout mutation disables a second mutation until completion;
- only saved groups in editor restoration;
- inert restore registers no controller or process resource;
- corrupt/missing group drops without clearing file tabs;
- invalid selected-group removal preserves surviving tab order, uses nearest
  selection fallback, collapses an empty split leaf, and repairs editor focus;
- old `.terminal` payload tolerance;
- workspace switch and window teardown; and
- role/coordinator cleanup precedes controller shutdown for workspace switch,
  window close, and app quit;
- stale async saved-layout load rejection in both workspace-open funnels;
- cross-window saved-library refresh and subscription cancellation;
- mutation at the subscribe/first-list boundary is observed without a lost
  revision;
- classified lifecycle callback once on natural exit or user close, no call
  on owner-driven abort, and no double call during group/window teardown;
- two `WorkspaceSession` instances remain independent.

Run read-only regressions for EditorLayout, switcher, Terminal Manager,
attention/notch, Process Resources, Agent Terminal, Ensemble terminal launch,
restoration, and window close.

## Manual acceptance

Acquire the single Rafu Lightning lease and verify:

- new one-pane group;
- selected-file starting directory and workspace-root fallback;
- right, down, mixed, and nested splits;
- divider drag and fraction retention during tab switches;
- pointer focus and direct session typing;
- pane close, last-pane close, and group close confirmation;
- hide/reveal with a running command;
- attention on one of several panes;
- Save and restore to stopped placeholders without a shell process;
- Set Pane Starting Folder, split inheritance, Start Pane, and Start All
  Restartable Panes;
- capacity error at six live sessions;
- no-mutation error at 24 retained panes;
- old file tabs and editor-group drag/drop;
- workspace switch and a second window; and
- no launch or termination of release Rafu.

TG-41 later adds the final menu and save-sheet paths. Use available temporary
surface actions for TG-30 or defer those exact paths.

## Verification and handoff

Complete all edits, manual notes, and the implementation record before the
common final sequence. After the parallel suite, run
`./script/build_and_run.sh --verify` under the GUI lease. The GUI run must not
modify a tracked file. Run `git diff --check`, commit only TG-30 paths, and
remove this worktree's `.build` after the green commit.

The handoff reports frozen Wave 4 APIs, restored-process count proof,
capacity/lifecycle/attention behavior, focused/full tests, Rafu Lightning and
deferred states, warnings, paths, branch, commit message, SHA, next dependency,
and **Deviations**.

## Implementation record

Implemented on `terminal-groups/tg-30-workspace-integration` from
`893caf7f50c77bfa9138519e20ba8d836cdc5b2e`.

- W1-W3: `WorkspaceSession` owns one compound `.terminalGroup` editor tab,
  group selection, split/focus operations, safe folder fallback, tab rename,
  and Wave 4 save/close request surfaces.
- W4-W6: focused-pane attention is scoped to one child session; close and
  teardown use generation-checked tokens, stable lifecycle/coordinator order,
  live reservations, six live panes, and 24 retained panes.
- W7-W8: named layouts use the injected or shared actor with subscription
  before list, generation/list/mutation epochs, cross-window delete
  detachment, inert restore, and one group switcher candidate.
- W9: classified insertion, owner close, natural exit, capacity wrappers, and
  exact-once callbacks are frozen on `WorkspaceSession`.

Focused integration tests use an actor-backed saved-layout store with explicit
subscription, list, save, and stale-result barriers. Every test that starts a
long-lived library binding tears its session down explicitly. Final build,
parallel suite, and Rafu Lightning verification are recorded in the lane
handoff commit.

Deviation: the focused Swift Testing filter initially hung because tests
emitted a store change before the registered stream had delivered its initial
list. The production subscription-first implementation was retained; tests
now await subscriber registration and initial list completion before changes.

Compatibility: `newTerminalTab`, Agent insertion, and temporary ungrouped
Ensemble sessions are source-compatible entry points that reveal one
compound Terminal Group. The guarded `.terminal` render path remains only for
decoded legacy restoration records.

Corrective validation: ordinary-shell Start Pane and Start All use the
manager-owned atomic live-capacity transaction, then reveal only after a
successful start. Focused workspace tests cover stopped/exited starts, folder
inheritance, ungrouped adoption, pane/group close, stale Save As/Delete after
a real workspace replacement, saved-only persistence, and layout repair that
preserves a selected file tab.

Coordinator-authorized test-path deviation: `Tests/RafuAppTests/TerminalsPanelTests.swift`
was updated only in its C/D reveal and hide migration assertions. It
now verifies the compound group, parked group ID, and retained child session.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-30 from
docs/plans/phases/terminal-groups/TG-30-workspace-integration.md: cut Rafu's
workspace and editor presentation over to one compound Terminal Group tab,
connect safe inert restoration and complete lifecycle behavior, freeze the
Wave 4 session API, verify in Rafu Lightning, and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run
`git switch terminal-groups/tg-30-workspace-integration` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-30-workspace-integration, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<WAVE2_MERGED_SHA>`.
Confirm TG-20, TG-21, and TG-22 are present. Do not create or replace a branch,
rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-30-workspace-integration.md;
docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/0023-terminal-groups-and-saved-layouts.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/plans/phases/terminal-groups/TG-20-runtime.md;
docs/plans/phases/terminal-groups/TG-21-renderer-focus.md;
docs/plans/phases/terminal-groups/TG-22-persistence.md;
docs/references/skill-routing.md; docs/references/build-and-run.md; and every
lane-specific source, test, and reference path in TG-30. Read all three Wave 2
implementation records. Read and use the project-local swiftui-expert-skill
with the exact references in TG-30;
the root swift-concurrency-pro with its named references; Build macOS Apps
swiftui-patterns, window-management, and build-run-debug. Do not use nested
duplicate skills.

Edit only WorkspaceSession.swift, EditorCanvasView.swift,
WorkspaceWindowView.swift, TG-30-owned tests, this plan's record, and one
conditional docs/references/terminal-group-workspace-restoration.md only when
its documented trigger applies. Treat runtime, renderer, store, EditorLayout,
commands, panel, switcher, Agent/Ensemble callers, Package.swift, ADRs, shared
indexes, and other tests as read-only. TG-30 also owns the five existing theme,
switcher, manager-presentation, Agent, and coordinator-launch test paths listed
in its ownership section. Stop on a Wave 2 contract defect.

Implement W1 through W9. New terminals use one .terminalGroup outer tab.
Preserve legacy decode and wrap temporary unassigned sessions on reveal. Keep
one focused pane, per-pane attention, exact group MRU toggle behavior,
generation-checked prepare/cleanup/finalize close, six-pane and six-session
preflight, the 24-retained-pane bound, and Start All Restartable Panes
zero-start validation. Keep
`openAgentTerminal(spec:)` compatible and classify it inside WorkspaceSession.
Restore only explicitly saved groups as stopped placeholders with zero process
or Process Resources action. Treat the Application Support actor as named
layout authority, reject stale workspace loads, and freeze all Wave 4
WorkspaceSession methods before handoff. Subscribe per workspace generation so
two windows refresh the shared named library and cancel cleanly.
Generation-check every Save, Save As, Delete, and list completion against its
exact target. Reconcile cross-window Delete by detaching matching open
instances. Keep selection, tab order, and editor-group focus valid when a bad
restored group is removed. Run role/coordinator cleanup before all teardown.

Add the exact focused tests and run all named read-only regressions. Use one
SwiftPM invocation at a time. Isolate a failure and never edit an unowned
failure.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked edits, documentation, and the implementation record
before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Under the single GUI lease, run
`./script/build_and_run.sh --verify` and the TG-30 manual matrix. Report exact
deferrals. Run `git diff --check`.

Stage only TG-30 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm a clean branch, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Report delivered behavior, frozen Wave 4 APIs, paths, focused/full tests,
build warnings, Rafu Lightning/manual evidence, zero-process restore proof,
capacity/lifecycle/attention/concurrency findings, risks, reference need,
branch, commit message, SHA, and next dependency. Include Deviations with
`None` when none. Complete the Goal only after the clean commit and full
handoff.
```
