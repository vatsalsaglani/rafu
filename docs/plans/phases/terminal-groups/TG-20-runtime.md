# TG-20 — Terminal Group runtime aggregate and lifecycle

## Status and execution slot

- **Status:** Implemented on lane; awaiting authorized merge.
- **Wave:** 2; parallel with TG-21 and TG-22.
- **Branch:** `terminal-groups/tg-20-runtime`.
- **Required base:** exact `<TG10_MERGED_SHA>`.
- **Prerequisite:** TG-10 contracts are frozen.
- **Next dependency:** TG-30 starts after all Wave 2 branches merge.

## Goal

Make `WorkspaceTerminalManager` the one aggregate owner of Terminal Groups,
pane-to-session membership, process capacity, group focus, park order, and
multi-session cleanup effects. Preserve the existing controller and SwiftTerm
process boundary.

This plan does not edit editor layout, `WorkspaceSession`, views, persistence
stores, commands, Agent launchers, or Ensemble launchers.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-20-runtime.md`
4. `docs/plans/phases/terminal-groups.md`
5. `docs/plans/phases/pre-initial-push-workbench.md`
6. `docs/decisions/0004-embedded-terminal.md`
7. `docs/decisions/0014-terminal-as-editor-tab.md`
8. `docs/decisions/0018-conductor-external-agent-orchestration.md`
9. `docs/decisions/0021-agent-terminals.md`
10. `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
11. `docs/plans/phases/editor-terminal-tabs.md`
12. `docs/plans/phases/terminal-manager.md`
13. `docs/references/skill-routing.md`
14. `docs/references/build-and-run.md`

Then read these lane-specific files:

- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift`;
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`;
- `Sources/RafuApp/Terminal/RafuTerminalView.swift` as read-only context;
- the terminal methods and cleanup hooks in
  `Sources/RafuApp/Models/WorkspaceSession.swift` as read-only context;
- `Sources/RafuApp/Conductor/ConductorCore.swift`, especially
  `TerminalProcessSpec`;
- `Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift`;
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`;
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`;
- `Tests/RafuAppTests/TerminalEditorTabTests.swift`;
- `Tests/RafuAppTests/TerminalAttentionTests.swift`;
- `Tests/RafuAppTests/Conductor/ConductorTerminalSpecTests.swift`;
- `docs/references/conductor-pty-spawn-and-child-environment.md`;
- `docs/references/workspace-lifecycle-dual-funnel.md`;
- `docs/references/memory-caps-and-pressure.md`; and
- `docs/references/concurrency.md`.

Use the root project-local `swift-concurrency-pro` skill. Read its complete
`SKILL.md` plus `references/actors.md`, `references/bug-patterns.md`,
`references/cancellation.md`, `references/interop.md`, and
`references/testing.md`. Review every callback, actor boundary, and teardown
path. Do not use the nested duplicate.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`; and
- new `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift`.

### Test paths

- new `Tests/RafuAppTests/TerminalGroupRuntimeTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupLifecycleTests.swift`; and
- new `Tests/RafuAppTests/TerminalGroupCapacityTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-runtime-lifecycle.md`, only for a
  new reusable process, callback, actor, or teardown fact.

All other paths are read-only. In particular, do not edit `WorkspaceSession`,
`EditorLayout`, the TG-10 contract files, `ProcessResourceRegistry`, any
Conductor file, any view, `Package.*`, ADR, shared index, or other lane test.

## Implementation contract

### R1. One aggregate mutation entry

Add an aggregate operation with the frozen TG-10 command/effect types. The
public group mutation path is equivalent to:

```swift
func perform(_ command: TerminalGroupCommand) throws -> TerminalGroupEffect
```

Keep query methods for snapshots, controller lookup by pane/session, group
lookup by session, and capacity. Do not expose direct mutable group arrays.

Keep current `newSession`, `close`, and `notePark` entry points as temporary
compatibility adapters. Current callers must compile and behave as before on
this isolated branch. Mark the adapters for TG-42/TG-90 migration. Do not
remove them here.

### R2. Group state and pure reducer

Use a pure reducer in `TerminalGroupRuntime.swift` for:

- one-pane group creation;
- right and down split insertion after the focused pane;
- normalized fraction update;
- exact and directional focus;
- pane removal and split collapse;
- group rename with whitespace trim and empty-to-default behavior;
- post-store saved-layout ID/name commit;
- deleted saved-layout detachment across every matching group; and
- stopped/unavailable pane insertion.

Reject a seventh leaf before mutation. The six-pane group bound includes
live, stopped, exited, and unavailable panes and is not the window capacity
count. Reject New, Split, or saved-group insertion before it would exceed 24
retained panes across the window. The rejected operation changes no group,
pane, focus, controller, or process state.

Directional focus uses normalized leaf rectangles derived from the tree and
fractions. Select the nearest candidate in the requested half-plane. Break
ties by primary-axis distance, then cross-axis distance, then stable tree
order. Do not wrap at an outer edge.

### R3. Unique membership

Maintain one mapping between group ID, pane ID, and optional session ID.

- A pane occurs in one group.
- A session occurs in one pane or in the temporary unassigned legacy set.
- A session cannot be mirrored.
- Moving focus or revealing does not create a controller.
- Finalizing a prepared leaf close removes one membership and returns the
  session cleanup result in the effect.
- Finalizing the last-leaf close returns the outer-group removal effect.

Assertions can protect programmer errors in debug builds, but all decoded or
user-driven invalid input must fail with a typed error and no partial mutation.

### R4. Retained-pane and live-session capacity

Define one window limit of six live terminal sessions. Count committed lazy
controllers that will spawn when mounted and controllers with a running child.
Do not count stopped placeholders, naturally exited controllers, or sessions
with bell attention merely because they have attention. A temporary reserved
slot exists only during one validated start transaction. It becomes one
committed live-session slot when controller construction succeeds, or it is
released on failure. It never appears as a pane or live process.

All new aggregate ordinary-shell, classified process-spec, split, restart,
Start Pane, and Start All Restartable Panes operations must use one preflight.
A request for more slots than available returns one capacity effect/error and
creates zero controllers, panes, process resources, or partial tree changes.

The two current nonthrowing `newSession` adapters cannot report a typed
capacity error without breaking their callers. Keep their current behavior in
TG-20 only. TG-30 moves shell and direct-Agent callers to the throwing API;
TG-42 moves the two Ensemble callers. The six-session guarantee is a set-level
gate after TG-42, not a false claim on the isolated TG-20 branch. TG-90 removes
an adapter only after its caller audit is empty.

The manager reserves all requested capacity before controller construction. A
failed construction releases all remaining reservations, closes controllers
created by that transaction, and restores Rafu-owned state. Tests must not
claim that Rafu can undo external side effects from a shell startup file.

Implement the TG-10 explicit reservation API for secure classified callers.
Consume a reservation exactly once when the final live launch request is
inserted. Cancel releases it. A reservation from another manager generation,
a double consume, or a post-shutdown consume returns a typed error. Workspace
teardown clears all reservations.

The separate retained-pane counter includes every live, exited, stopped, and
unavailable pane in open or parked groups. It excludes temporary unassigned
legacy sessions until TG-30 wraps them. Closing panes releases retained
capacity. A natural process exit does not release retained capacity while its
exited pane remains.

### R5. Lazy controller ownership

Keep one existing `WorkspaceTerminalController` per live pane. Keep actual
process spawn in the controller's current lazy SwiftTerm view-mount path. A
group or pane snapshot must not create a view or process.

Factor duplicate session callback wiring into one manager helper without
changing exit, bell, attention-clear, memory-timeline, Process Resources, or
output-capture behavior.

### R6. Park, reveal, and selection

Park order moves from session-tab identity to group identity. Parking a group
does not change a child controller or process. The manager exposes group MRU
order and a lookup from any session ID to its group and pane.

`selectedID` remains temporarily compatible for old call sites, but the
authoritative group state stores one focused pane. Snapshot queries derive the
focused session from that pane.

### R7. Close and teardown effects

Preparing one pane close returns a generation-checked token with its session
ID and actual live-process count. Preparing a group close returns all child
session IDs in stable pane order and the actual live-process count. Preparation
does not shut down a controller or mutate membership. After caller-owned
coordinator or role cleanup, finalize validates a freshly prepared token,
closes controllers exactly once, and removes pane/group membership. The caller
must reprepare immediately before cleanup and use the fresh token without an
actor suspension. A stale reprepare changes nothing and performs no cleanup.

`shutdownAll()` closes grouped and temporary legacy sessions, clears groups,
capacity reservations, selection, counters, and park order. Natural exit keeps
the pane and controller as exited, releases its live slot, and allows an
explicit capacity-checked restart.

The manager does not call Ensemble code. TG-30 and TG-42 consume cleanup
effects through existing `WorkspaceSession` hooks.

## Tests

Use fakes that create no real SwiftTerm view or shell for the new reducer and
capacity tests. Pin:

- right/down and nested split tree shape;
- four focus directions, deterministic tie-break, and no wrap;
- close leaf, root leaf, and recursive split collapse;
- unique pane and session membership;
- rename/default numbering;
- saved-layout association, Save-As name commit, and detach-all by saved ID;
- group MRU park order;
- lookup from session to group and pane;
- one, five, and six slot success;
- seventh slot rejection;
- Start All Restartable Panes capacity rejection with no partial state;
- Start All Restartable Panes ignores unavailable placeholders;
- a seventh pane is rejected even when no pane is live;
- 24 retained panes can exist across groups, while the 25th New, Split, or
  saved-group leaf is rejected without mutation;
- exited slot release and restart reservation;
- explicit reservation consume/cancel, double-consume rejection, and teardown
  release;
- group close stable cleanup order;
- close preparation is nonmutating, reports actual live processes, and rejects
  a stale finalize token;
- stale close-confirmation revalidation performs zero caller cleanup;
- `shutdownAll` for grouped and legacy sessions;
- callback wiring exactly once; and
- temporary legacy adapter behavior and its documented capacity exemption.

Run the existing Terminal, Agent Terminal, Ensemble terminal-spec, process
resource, attention, and quiescence test filters read-only. If a PTY test fails
only under load, use the repository isolation table. Do not change an unowned
test.

## Manual acceptance

No visible call site exists on this branch. Do not launch a real shell solely
for TG-20. Use headless tests to prove no process starts during group mutation.

## Verification and handoff

Complete all changes and the implementation record before the common final
sequence. Run `git diff --check`, create one local commit from TG-20-owned
paths, and remove this worktree's `.build` after the green commit.

The handoff reports the aggregate API, compatibility adapters, capacity proof,
lifecycle and concurrency review, focused/full tests, warnings, paths, branch,
commit message, SHA, next dependency, and **Deviations**.

## Implementation record

Implemented on `terminal-groups/tg-20-runtime` from base
`b52f9c8153822911505fd5d7d211ac30288c7b3f`.

- Added `TerminalGroupRuntime`, a value-only reducer for bounded group trees,
  focus geometry, split collapse, saved-layout association, group parking,
  close-token validation, and retained-pane checks. It owns no view,
  controller, process, store, or process start.
- Made `WorkspaceTerminalManager` the aggregate entry point for group
  mutations, snapshots, group/pane/session lookup, and one manager-bound
  capacity-reservation seam. Existing `newSession`, `close`, and `notePark`
  stay as documented legacy adapters for TG-30/TG-42 migration.
- Added headless reducer, lifecycle, and capacity tests. They do not mount a
  SwiftTerm view or start a shell.
- Corrective work keeps aggregate launch mutations on proposed runtime values
  until all validation and controller construction succeeds. Start All keeps
  exited controller/session identity, creates controllers only for stopped
  panes, and selects the final focused pane in stable tree order.
- Reservations now move from reserved to committed only after an aggregate
  insertion. The frozen explicit consume call then succeeds once as an
  acknowledgement; it rejects before insertion, after cancellation, after
  shutdown, and after a prior consume.
- Final close validates a copied runtime before shutdown. A fresh token shuts
  controllers down in stable tree order before membership removal; a stale
  token performs zero controller cleanup.
- Added an inert decoded-snapshot insertion seam for TG-22/TG-30. It
  preserves validated runtime group, pane, and split IDs plus start
  availability, accepts no session/controller state, and applies the same
  retained and duplicate-membership guards as saved-layout insertion.
- Runtime projections use a UUID tie-break for equal group names, so manager
  rows retain deterministic order after unrelated dictionary mutations.
- The aggregate does not call WorkspaceSession or Ensemble cleanup. Its close
  effect returns stable session IDs to the future caller-owned cleanup path.
- No reusable platform fact required a new reference note: this lane adds no
  new callback, actor, async stream, process-I/O, or teardown mechanism.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-20 from docs/plans/phases/terminal-groups/TG-20-runtime.md:
make WorkspaceTerminalManager the bounded Terminal Group aggregate with pure
tree mutation, unique membership, zero-start capacity preflight, and correct
teardown;
preserve current callers, verify, and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run `git switch terminal-groups/tg-20-runtime`
and run `git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-20-runtime, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG10_MERGED_SHA>`.
Do not create or replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-20-runtime.md;
docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/0023-terminal-groups-and-saved-layouts.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/references/skill-routing.md; docs/references/build-and-run.md; and every
lane-specific source, test, and reference path in TG-20. Read and use the root
.agents/skills/swift-concurrency-pro/SKILL.md and its actors, bug-patterns,
cancellation, interop, and testing references. Do not use its nested duplicate.

Edit only WorkspaceTerminalController.swift, new TerminalGroupRuntime.swift,
the three new TG-20 test files, this plan's implementation record, and a
conditional `docs/references/terminal-group-runtime-lifecycle.md` only if its
documented trigger applies. Treat WorkspaceSession,
EditorLayout, TG-10 contracts, ProcessResourceRegistry, Conductor files, all
views, Package.swift, shared indexes, and other lane tests as read-only.

Implement R1 through R7. Keep process spawn lazy. Enforce six panes per group,
24 retained panes per window, and six live sessions per window. Make retained,
live-capacity, and profile preflight no-mutation and zero-start. Treat a later
external spawn or shell-startup failure as that pane's exited/error result. Do
not roll back other panes or claim to undo external side effects.
Keep one session in one pane. Return cleanup effects to WorkspaceSession. Keep
legacy newSession, close, and notePark adapters until later migration. Do not
add UI, persistence I/O, automatic commands, or process restoration.

Add the focused headless tests and run the named read-only regressions. Use one
SwiftPM invocation at a time. Isolate a failing test before diagnosis and do
not edit an unowned failure.

Update this plan's Status and implementation record before the final gate.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Run `git diff --check`.

Stage only TG-20-owned paths and create one intentional local commit. This
prompt authorizes that commit only. Do not push, merge, open a PR, publish,
release, or edit main. Confirm a clean branch, record branch, commit message,
and `git rev-parse HEAD`, then remove only this worktree's `.build` as the last
filesystem step.

Report delivered behavior, aggregate API, compatibility adapters, capacity
and no-partial-start proof, lifecycle/concurrency findings, paths, focused and
full test evidence, warning count, risks, reference need, branch, commit
message, SHA, and next dependency. Include Deviations with `None` when none.
Complete the Goal only after the clean local commit and full handoff.
```
