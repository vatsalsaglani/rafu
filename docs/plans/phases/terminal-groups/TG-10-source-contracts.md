# TG-10 — Terminal Group source contracts and migration shim

## Status and execution slot

- **Status:** Planned.
- **Wave:** 1; serial source prerequisite.
- **Branch:** `terminal-groups/tg-10-contracts`.
- **Required base:** exact `<TG00_MERGED_SHA>`.
- **Prerequisite:** TG-00 and Accepted ADR 0023 are present.
- **Next dependency:** TG-20, TG-21, and TG-22 start from the merged TG-10
  commit.

## Goal

Land the shared value types, commands, effects, restoration DTOs, editor-tab
resource, and legacy decode shim that every later plan consumes. Do not change
live terminal behavior or add a visible call site.

At the end of TG-10, later lanes must not invent a second runtime ID, saved
layout ID, tree, launch profile, persistence record, command, or effect model.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-10-source-contracts.md`
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

- `docs/references/swift-6-2-memberwise-initializer-default-property.md`;
- `docs/references/editor-search-and-restoration.md`;
- `Sources/RafuApp/Editor/EditorLayout.swift`;
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift`;
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift`;
- `Sources/RafuApp/Terminal/TerminalSessionColor.swift`;
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`;
- every `EditorTabResource` switch in
  `Sources/RafuApp/Models/WorkspaceSession.swift`;
- every `EditorTabResource` switch in
  `Sources/RafuApp/Views/EditorCanvasView.swift`;
- every `EditorTabResource` switch in
  `Sources/RafuApp/Views/EditorTabSwitcherView.swift`;
- `Tests/RafuAppTests/EditorLayoutTests.swift`;
- `Tests/RafuAppTests/TerminalEditorTabTests.swift`;
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`;
- `Tests/RafuAppTests/TerminalsPanelTests.swift`; and
- `Tests/RafuAppTests/SettingsCanvasTests.swift`.

Use the root project-local `swift-concurrency-pro` skill. Read its complete
`SKILL.md` and only `references/new-features.md`, `references/diagnostics.md`,
`references/actors.md`, `references/async-streams.md`, and
`references/testing.md`. Review the new `Sendable` and actor-boundary
contracts. Do not use the nested duplicate skill.

## Exclusive ownership

### Production paths

- new `Sources/RafuApp/Terminal/TerminalGroupModel.swift`;
- new `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift`;
- `Sources/RafuApp/Editor/EditorLayout.swift`;
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift`;
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift`;
- `Sources/RafuApp/Models/WorkspaceSession.swift`, only for exhaustive
  `EditorTabResource` compile shims;
- `Sources/RafuApp/Views/EditorCanvasView.swift`, only for exhaustive
  `EditorTabResource` compile shims; and
- `Sources/RafuApp/Views/EditorTabSwitcherView.swift`, only for exhaustive
  `EditorTabResource` compile shims.

### Test paths

- new `Tests/RafuAppTests/TerminalGroupContractTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupRestorationContractTests.swift`; and
- `Tests/RafuAppTests/EditorLayoutTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-contract-isolation.md`, only if
  TG-10 proves a reusable Swift 6.2 codec or isolation fact that current
  references do not contain.

All other source, tests, ADRs, plans, shared indexes, `AGENTS.md`, `Package.*`,
resources, scripts, and build metadata are read-only. If the optional
restoration field breaks a current memberwise initializer call, solve it with a
compatible explicit initializer in the owned DTO. Do not edit foreign tests.

## Source contract

### C1. Stable identities and layout vocabulary

Define nonisolated, `Codable`, `Hashable`, and `Sendable` value IDs:

- `TerminalGroupID`;
- `TerminalPaneID`; and
- `TerminalGroupSplitID`.

Define a runtime-only `TerminalGroupCapacityReservationID` and a bounded,
generation-checked reservation value. It is not Codable and cannot enter a
snapshot or saved record.

These are runtime IDs. Also define separate record-domain IDs:

- `SavedTerminalGroupID` for one reusable named layout;
- `SavedTerminalPaneID`; and
- `SavedTerminalGroupSplitID`.

Each wraps a UUID and provides a default UUID initializer. Runtime IDs, saved
record IDs, and live session UUIDs are different domains and are not
interchangeable.

Define:

- `TerminalGroupSplitPlacement { right, down }`;
- `TerminalPaneFocusDirection { left, right, up, down }`; and
- `TerminalGroupSplitAxis { columns, rows }`.

The public API uses right/down. The stored tree uses columns/rows. Do not use
horizontal/vertical for terminal product commands.

Declare every TG-10 tree, snapshot, launch-profile, classification, command,
effect, close-token, capacity, and saved/restoration value type `nonisolated`
and honestly `Sendable` under RafuApp's default MainActor isolation. Apply
`Codable` only to the safe value types that cross a codec boundary. None of
these values can contain a closure, controller, AppKit/SwiftTerm object, or
other actor-confined reference.

### C2. Recursive tree and snapshot

Define one recursive `TerminalGroupNode` with:

- `.pane(TerminalPaneID)`; and
- `.split(id:axis:fraction:first:second:)`.

Define one bounded, immutable `TerminalGroupSnapshot` that includes runtime
group ID, group name, recursive root node, focused runtime pane ID, optional
`SavedTerminalGroupID`, and the bounded pane snapshots. Define
`TerminalPaneSnapshot` with runtime pane ID, optional live session ID, explicit
user pane name, separately identified reported title, runtime pane kind, theme
color, status, optional safe launch profile, and start availability. The
persistence codec must not confuse a reported title, runtime provider
identity, or computed display name with the explicit user pane name.

The snapshot must make invalid states unrepresentable or detectable:

- each pane ID occurs once in the tree;
- focused pane occurs in the tree;
- each non-nil session ID occurs once; and
- fractions are finite and normalized.

Enforce at most six leaves in one group and at most 24 retained terminal panes
across all open and parked groups in one window. The retained count includes
live, exited, stopped, and unavailable panes. These bounds are separate from
the six-live-session capacity across the complete window. New, Split, and Open
Saved Group return a typed no-mutation error before they exceed the retained
bound. Do not add an unbounded collection to observable state.

### C3. Launch and restoration classification

Define a safe `TerminalPaneLaunchProfile` for ordinary shells only. It stores
either the preferred-shell choice or one approved shell path, plus one
normalized workspace-relative starting folder. It never stores an observed
live working directory.

Define a runtime-only, non-Codable, `Equatable`, and `Sendable`
`TerminalPaneRuntimeKind` with exactly these cases:

- ordinary shell;
- direct Agent Terminal with its `ConductorCLIID` provider;
- Ensemble role;
- Ensemble coordinator;
- unavailable Agent Terminal; and
- unavailable Ensemble.

Status and start availability distinguish live, idle, exited, and stopped
ordinary-shell panes. The two unavailable cases never have a live session ID
or launch request. For persistence, define
`SavedTerminalPaneKind { ordinaryShell, unavailableAgentTerminal,
unavailableEnsemble }`. The unavailable UI message is fixed and derived from
this enum. The exact messages are
`Agent Terminal profiles are not saved in this version.` and
`Ensemble terminal profiles are not saved in this version.` No saved case
contains a free-form label/reason, provider, model, runtime error, executable
argv, environment, token, credential, `TerminalProcessSpec`, or session UUID.

Define a separate runtime-only, non-Codable live launch request for ordinary
shells and classified `TerminalProcessSpec` insertions. It is the only command
payload used to construct a controller. Saved and restoration records cannot
contain this type. The aggregate insertion API is throwing and returns a typed
capacity or validation error before it returns a controller/session identity.
For callers that must complete secure setup before constructing the final
process spec, define reserve, consume, and cancel operations. A reservation is
manager-scoped, single-use, generation-checked, and carries no executable,
environment, token, or process spec.

### C4. Command and effect boundary

Define one `TerminalGroupCommand` family for:

- create group;
- split focused pane right/down;
- focus exact pane or direction;
- rename group;
- commit a saved-layout ID and validated name to one group after store success;
- detach one deleted saved-layout ID from every matching group;
- set one pane's explicit starting folder;
- set divider fraction;
- park or reveal group;
- prepare pane or group close and return one generation-checked close token;
- finalize prepared pane or group close with that token;
- restart exited shell pane;
- insert stopped saved group;
- start pane; and
- start all restartable panes.

Define `TerminalGroupEffect` values for editor-layout insertion/removal,
selection, process cleanup, persistence, close confirmation, capacity error,
and user-visible validation error. Effects do not mutate `EditorLayoutState`
directly.

This contract keeps editor-layout ownership in `WorkspaceSession` and process
ownership in `WorkspaceTerminalManager`.

Close preparation is nonmutating. Its token carries stable affected session
IDs and the actual live-process count. On confirmation, `WorkspaceSession`
prepares again before any cleanup. If the affected set or live count changed,
it refreshes the confirmation and requires a new confirmation. Otherwise it
uses the fresh token, performs existing coordinator or role cleanup, and sends
finalize synchronously on MainActor without an `await` or another mutation in
between. Finalize validates the fresh token, shuts controllers down exactly
once, and mutates membership. A stale or failed revalidation performs zero
cleanup and zero mutation.

### C5. Safe saved records

In `TerminalGroupRestoration.swift`, define versioned records for:

- one saved-layout envelope;
- one reusable named saved group keyed by `SavedTerminalGroupID`;
- one recursive saved node; and
- one saved pane; and
- one inert open-tab restoration record for a specific window-restored group
  instance.

Named records use only record-domain pane and split IDs. They contain no
runtime group, pane, split, or session ID. The pure instantiation contract
creates fresh runtime IDs and remaps focus on every Open. The open-tab
restoration record can retain the already-unique runtime IDs for that one
specific tab. It cannot be used as a reusable named template.

The records include only the allow-list in the parent phase. They have no field
for output, reported OSC title, computed display name, provider/model identity,
free-form unavailable text, runtime error, environment, token, PID, PTY, live
controller, process spec, or session UUID. Unsupported schema versions must
produce a typed error.

The saved-layout envelope uses an opaque, deterministic workspace key derived
from the standardized root. It contains no raw absolute workspace root.

Define a `nonisolated protocol TerminalGroupSavedLayoutStoring: Sendable` with
async load, save, delete, and list operations, plus a bounded change stream for
successful workspace-library mutations. The change value carries only
workspace identity and a monotonic in-process revision, not saved records. Use
newest-one buffering. Subscription registers with the store actor before the
stream returns and immediately yields that workspace's current revision. This
closes the initial-list subscription gap. Tests and `WorkspaceSession` must be
able to inject a store. TG-22 supplies the concrete Application Support actor.

### C6. Editor resource migration

Add `EditorTabResource.terminalGroup(groupID:)`. It is restorable only when a
matching safe restoration record exists; do not make `isRestorable` perform a
store lookup. Add a pure classification method that lets TG-30 validate group
resources against the restoration envelope.

Adding the enum case makes current exhaustive switches fail to compile. Add a
minimal explicit `.terminalGroup` branch to every current exhaustive switch,
only in the three owned call-site files. These branches are compile shims:

- `WorkspaceSession` treats the group as no selected document and drops it
  from active restoration until TG-30;
- `EditorCanvasView` uses one bounded unavailable placeholder that cannot
  create a controller or process; and
- `EditorTabSwitcherView` uses the stored or fallback Terminal Group title
  and only the existing outer-tab selection behavior.

Do not create a Terminal Group resource from a user action, change current
`.terminal` routing, or add group behavior in TG-10. TG-30 replaces the
workspace and canvas shims. TG-40 replaces the switcher presentation shim.

Add `EditorTabSwitcherDestination.terminalGroup(groupID:)` in
`Sources/RafuApp/Editor/EditorTabSwitcher.swift`. In TG-10 it is an additive
identity contract only. Add the minimal exhaustive activation branch in
`WorkspaceSession`; it performs no selection or process action until TG-30.
Add a bounded unavailable label branch to the destination switch in
`EditorTabSwitcherView`; no candidate produces it yet. These are compile shims
for the new destination case, not live behavior.
The existing `.terminal(sessionID:)` destination remains compatible. TG-30
creates group candidates and activation behavior. TG-40 owns their final
presentation.

Keep `EditorTabResource.terminal(sessionID:)` decodable and source-compatible.
Do not remove it in TG-10. A legacy resource remains nonrestorable.

Extend editor-layout tests to prove:

- new group resource round-trip;
- legacy terminal resource round-trip;
- unknown or unsupported group restoration does not clear file tabs; and
- file-resource behavior is unchanged.

### C7. Workspace restoration envelope

Add an optional terminal-group restoration field to `RestorableWorkspace`.
Old payloads without the field must decode. Existing memberwise initializer
call sites must compile without edits. Use an explicit initializer if Swift
6.2 synthesized-initializer behavior requires it.

Decode the optional terminal-group field through a tolerant boundary. A
missing, malformed, or unsupported terminal-group field becomes no Terminal
Group restoration data plus a bounded diagnostic; it must not fail decoding
of the existing workspace, file tabs, editor groups, or selection. Within a
valid field, decode records through a tolerant per-record boundary. One
malformed record produces a bounded record diagnostic and is omitted while
valid sibling records and all nonterminal workspace data survive.

Do not start, resolve, or register a process during encode or decode.

## Tests

Add focused pure tests for:

- ID and enum codec round-trips;
- tree traversal, duplicate detection, focused-pane validation, finite
  fraction validation, a six-leaf bound, and a 24-retained-pane bound;
- safe launch-profile encoding;
- separation of saved and runtime IDs, plus fresh re-keying on two opens;
- explicit user pane name persistence and OSC-title sentinel exclusion;
- prohibited-key absence in encoded saved records;
- current and unsupported schema behavior;
- old `RestorableWorkspace` decode;
- malformed and unsupported terminal-group fields preserve old workspace and
  file-tab decode;
- one malformed group record beside one valid record drops only the malformed
  record;
- editor group and legacy terminal resource decode;
- terminal-group switcher destination identity without a live call site;
- file-tab restoration compatibility.

Run read-only regression filters for `EditorLayout`, `TerminalEditorTab`,
`TerminalsPanel`, and `SettingsCanvas` before the full suite.

## Manual acceptance

No GUI pass is required because TG-10 adds no visible call site. Inspect an
encoded test fixture and confirm that it contains no prohibited process or
terminal-content field.

## Verification and handoff

Complete source, tests, documentation, and the implementation record before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing modifies a tracked file after the parallel suite. Run
`git diff --check`. Stage only TG-10 paths and create one local commit. Do not
push or merge. Remove only this worktree's `.build` after the commit.

The handoff must include the frozen type/API list, compatibility evidence,
encoded-field inspection, focused and full test results, warnings, branch,
commit message, commit SHA, next dependency, and **Deviations**.

## Implementation record

To be completed by the TG-10 implementor before the final gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-10 from
docs/plans/phases/terminal-groups/TG-10-source-contracts.md: land the shared
Terminal Group value, command, effect, restoration, editor-resource, and
legacy migration contracts without changing live behavior; verify and commit
the source foundation locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run `git switch terminal-groups/tg-10-contracts`
and run `git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-10-contracts, the tree is clean, the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG00_MERGED_SHA>`,
and Accepted ADR 0023 is present. Do not create or replace a branch, rebase,
or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-10-source-contracts.md;
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
lane-specific source, test, and reference path in TG-10. Read and use the root
.agents/skills/swift-concurrency-pro/SKILL.md plus only its new-features,
diagnostics, actors, async-streams, and testing references. Do not use the
nested duplicate.

Edit only TG-10-owned paths. Implement C1 through C7 exactly. Declare all
cross-actor contract values explicitly nonisolated and honestly Sendable. The
three central
call-site files are owned only for explicit exhaustive-switch compile shims;
do not change reachable current behavior. Keep all new domain values bounded
and Sendable. Keep runtime and saved IDs separate. Re-key every named layout
Open. Persist only explicit pane names, never OSC titles. Keep legacy .terminal
decoding. Make old RestorableWorkspace
payloads and call sites compatible. Add no user action, process start, store
I/O, package change, or automatic command. If another foreign call site needs
an edit, stop and report the merge-owner need.

Add the focused tests and run the named read-only regressions. For a failing
foreign test, run it alone and do not edit it. Use one SwiftPM invocation at a
time and do not poll.

Update this plan's Status and implementation record. Create only the optional
`docs/references/terminal-group-contract-isolation.md` when the lane proves the
reusable fact defined in its documentation ownership.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Run `git diff --check`.

Stage only TG-10 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm a clean branch, record the branch, commit message, and
`git rev-parse HEAD`, then remove only this worktree's `.build` as the last
filesystem step.

Report the frozen API/type list, delivered behavior, paths, focused tests,
full parallel total and duration, build warnings, codec/security inspection,
concurrency review, risks, reusable nuance, branch, commit message, commit SHA,
and next dependency. Include Deviations with `None` when none. Complete the
Goal only after the clean local commit and complete handoff.
```
