# TG-22 — Safe saved-layout codec and Application Support store

## Status and execution slot

- **Status:** Planned.
- **Wave:** 2; parallel with TG-20 and TG-21.
- **Branch:** `terminal-groups/tg-22-persistence`.
- **Required base:** exact `<TG10_MERGED_SHA>`.
- **Prerequisite:** TG-10 restoration records and store protocol are frozen.
- **Next dependency:** TG-30 wires the store after Wave 2 merges.

## Goal

Implement the safe conversion and bounded Application Support store for named
Terminal Group layouts. Prove that save and load perform no terminal process,
view, Process Resources, or capability action.

This plan does not edit `WorkspaceSession`, current workspace restoration,
terminal runtime, editor layout, views, commands, Agent code, or Ensemble code.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-22-persistence.md`
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
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift` as read-only;
- `Sources/RafuCore/RafuAppIdentity.swift`;
- `Sources/RafuApp/LanguageIntelligence/Registry/WorkspaceTrustStore.swift`
  as an Application Support and test-injection pattern;
- `Sources/RafuApp/Terminal/TerminalShellCatalog.swift` as read-only;
- `Sources/RafuApp/Conductor/ConductorCore.swift`, especially
  `TerminalProcessSpec`, as a prohibited-type audit target;
- `Tests/RafuAppTests/WorkspaceTrustStoreTests.swift`;
- `Tests/RafuAppTests/AppSupportRootTests.swift`;
- `docs/references/app-variants-and-state-isolation.md`;
- `docs/references/editor-search-and-restoration.md`;
- `docs/references/workspace-lifecycle-dual-funnel.md`; and
- `docs/references/swift-6-2-memberwise-initializer-default-property.md`.

Use the root project-local `swift-concurrency-pro` skill. Read its complete
`SKILL.md` plus `references/actors.md`, `references/structured.md`,
`references/async-streams.md`, `references/cancellation.md`, and
`references/testing.md`. Do not use the nested duplicate.

## Exclusive ownership

### Production paths

- new `Sources/RafuApp/Terminal/TerminalGroupRestorationCodec.swift`; and
- new `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift`.

### Test paths

- new `Tests/RafuAppTests/TerminalGroupRestorationTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupSavedLayoutStoreTests.swift`; and
- new `Tests/RafuAppTests/TerminalGroupPersistenceSecurityTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-saved-layout-store.md`, only for a
  new reusable atomic-store, schema, app-identity, or concurrency fact.

All other paths are read-only. Do not edit the TG-10 records or protocol to
fit the store. Stop and report a contract defect instead.

## Implementation contract

### P1. Pure runtime-to-record conversion

Implement a pure codec that converts one valid group snapshot into the frozen
saved record. It must:

- remove live session UUIDs and controller state;
- map runtime group, pane, and split IDs to record-domain IDs;
- keep only ordinary shell restart profiles;
- convert Agent Terminal and Ensemble panes to their fixed unavailable
  `SavedTerminalPaneKind` cases;
- convert folders to normalized workspace-relative paths;
- reject a folder outside the workspace;
- retain group name, explicit user pane names, theme-token colors, tree,
  fractions, focus, and saved-layout identity; and
- validate all IDs and tree membership before it returns a record.

Do not observe or save a controller's live OSC working directory. Use only the
explicit starting folder in the safe profile. Do not save `reportedTitle`, a
computed display name, or other OSC-derived text.

### P2. Record-to-placeholder conversion

Decode a named saved record into a group snapshot with fresh runtime group,
pane, and split IDs and zero live session IDs. Opening the same record twice
must produce disjoint runtime IDs while it preserves topology and focus by
remapping record-domain IDs. Every pane is stopped or unavailable. Decoding
does not resolve an executable, construct `TerminalProcessSpec`, call the
terminal manager, access SwiftTerm, or register a process resource.

Provide a separate open-instance restoration decoder for the TG-10 workspace
record. It validates and retains that one instance's runtime IDs, produces zero
live session IDs, and never inserts it into the named-layout store. The named
Open decoder and open-instance restore decoder must not share identity rules by
accident.

Return typed validation failures for:

- unsupported schema;
- duplicate IDs;
- missing focused pane;
- invalid tree;
- nonfinite or invalid fraction;
- absolute or escaping relative path;
- unknown saved-pane kind, or a missing/unapproved shell profile for an
  ordinary-shell pane; and
- exceeded bounds.

A missing folder or shell is a recoverable pane validation result for TG-30's
UI, not permission to substitute another folder or shell.

### P3. Bounded store shape

Implement `TerminalGroupSavedLayoutStoring` below the current app identity's
Application Support root. Use one versioned JSON file with workspace-keyed
records. One process-wide store actor per app identity and base root serializes
every read-modify-write across windows. A `WorkspaceSession` holds a reference
to this actor; it does not construct an independent file authority. Tests
inject a temporary base directory and explicit app identity.

Bounds:

- at most 32 saved groups per workspace;
- at most 6 panes per group;
- group and pane names at most 80 Unicode scalar values after trim;
- relative folder at most 1,024 UTF-8 bytes;
- total encoded file at most 256 KiB.

Reject writes that exceed a bound. Do not truncate identity or path data
silently. Bounded user-facing error text can truncate at a valid UTF-8
boundary.

Derive the JSON map key as deterministic SHA-256 over the standardized local
workspace root using Apple CryptoKit. Store only the encoded digest, never the
raw absolute root, and do not interpolate either value into a filename. Do not
log the root or digest.

### P4. Atomic and variant-safe writes

Create the app-identity-specific directory as needed. Encode deterministically
where practical and write atomically. Do not combine incompatible Foundation
write options. Never write inside the workspace.

Rafu and Rafu Lightning must use different Application Support roots through
`RafuAppIdentity`. Tests prove the separation.

Load failure must not delete or overwrite the unreadable file. Return an exact
error so TG-30 can show it. An unsupported record does not cause file-tab
restoration data to clear.

This store is the sole authority for named-layout existence, library listing,
explicit Open content, Save, Save As, and Delete. The workspace restoration
store can hold only one open-tab instance snapshot and placement. It cannot
create or resurrect a named record.

After a successful Save, Save As, or Delete, emit one newest-one buffered
workspace revision through the TG-10 change stream. Do not emit for failed or
cancelled writes. Do not put records or paths in logs. Concurrent clients must
not lose an event needed to trigger a fresh list.

Register each continuation inside the store actor before returning its stream,
and immediately yield that workspace's current revision. Keep newest-one
buffering and remove continuations on termination. This makes subscription
before first list safe when another window mutates at that boundary.

### P5. Save, Save As, list, and delete semantics

- Save updates the matching saved-layout ID.
- First Save creates and returns a new saved-layout ID with the current group
  name.
- Save As creates and returns a new ID and does not mutate the old record.
- Names are unique within a workspace using a stable case-insensitive,
  diacritic-insensitive comparison. A conflict returns an exact error.
- List uses stable name order with ID tie-break.
- Delete removes only the requested saved-layout record.
- Delete returns the removed `SavedTerminalGroupID` so TG-30 can detach all
  open instances from it. It does not close a live group.
- Removing the last record for one workspace does not remove another
  workspace's data.

No store operation starts a pane. Start Pane and Start All Restartable Panes
remain runtime and workspace actions.

### P6. Security audit helper

Tests must inspect encoded JSON keys and values. Add no production reflection
or security scanner. The encoded representation must not contain keys or test
sentinels for:

- session ID, PID, PTY, controller, output, scrollback, transcript, history;
- executable arguments, process spec, command, environment, token,
  `RAFU_ENSEMBLE_TOKEN`, credential, secret, reply ID; or
- a raw absolute workspace root or child folder.

## Tests

Add focused async and pure tests for P1 through P6, including:

- shell record round-trip;
- two Opens produce disjoint runtime group, pane, and split IDs;
- one open-instance restore retains its unique runtime IDs but does not create
  a named record;
- Agent and Ensemble unavailable conversion;
- fixed unavailable-message derivation with no persisted free-form reason;
- explicit user pane name survives and an OSC-title sentinel is absent;
- zero live IDs after decode;
- path traversal and absolute-path rejection;
- deterministic workspace digest and raw-root sentinel exclusion;
- missing folder and shell typed results;
- each size/count bound;
- old/current/unsupported schema;
- corrupt file preserved after failed load;
- atomic update, Save As, name conflict, list, delete, and two workspaces;
- release and Lightning root separation;
- cancellation before a write;
- concurrent writes from two injected window clients preserve both updates;
- successful mutations notify both clients, while failed/cancelled writes do
  not notify;
- subscription-before-first-list sees a boundary mutation, and the immediate
  current-revision event remains newest-one bounded;
- encoded prohibited-field and sentinel absence.

Run read-only `AppSupportRoot`, `WorkspaceTrustStore`, editor restoration, Agent
Terminal, Ensemble grant, and process-resource regression filters.

## Manual acceptance

No GUI call site exists on this branch. Inspect the temporary test file and
record its exact approved key set. Confirm no test touches real Application
Support.

## Verification and handoff

Complete all changes and the implementation record before the common final
sequence. Run `git diff --check`, commit only TG-22 paths, and remove this
worktree's `.build` after the green commit.

The handoff reports the file/schema shape, bounds, approved key set, atomic
write and app-variant evidence, security/concurrency review, tests, warnings,
branch, commit message, SHA, next dependency, and **Deviations**.

## Implementation record

To be completed by the TG-22 implementor before the final gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-22 from
docs/plans/phases/terminal-groups/TG-22-persistence.md: build the bounded,
variant-safe Terminal Group saved-layout codec and atomic Application Support
store, prove that persisted data contains no live process or capability state,
verify, and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run `git switch terminal-groups/tg-22-persistence`
and run `git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-22-persistence, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG10_MERGED_SHA>`.
Do not create or replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-22-persistence.md;
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
lane-specific source, test, and reference path in TG-22. Read and use the root
.agents/skills/swift-concurrency-pro/SKILL.md and its actors, structured,
async-streams, cancellation, and testing references. Do not use its nested
duplicate.

Edit only new TerminalGroupRestorationCodec.swift, new
TerminalGroupSavedLayoutStore.swift, the three new TG-22 tests, this plan's
Status and record, and conditional
docs/references/terminal-group-saved-layout-store.md only when its documented
trigger applies. Treat WorkspaceSession,
WorkspaceRestorationStore, runtime, editor layout, views, commands, Agent and
Ensemble code, TG-10 contracts, Package.swift, and shared indexes as read-only.

Implement P1 through P6. Store only approved metadata below the current
RafuAppIdentity Application Support root. Serialize every window client
through one store actor per app identity and root. Use injected temporary roots
in tests. Re-key every named Open to fresh runtime IDs. Restore stopped or
unavailable panes with zero process actions. Enforce all bounds and atomic
Save/Save As/list/delete behavior. Never persist output, OSC titles, computed
display names, provider/model identity, free-form unavailable text, runtime
errors, environment, argv, process specs, live IDs, credentials, tokens, or
absolute child folders. Do not silently substitute a missing shell or folder.
Emit bounded workspace revisions only after successful mutations so two window
clients refresh without sharing runtime state.

Add all focused tests and run the named read-only regressions. Use one SwiftPM
invocation at a time. Isolate a failure and never edit an unowned failure.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Run `git diff --check`.

Stage only TG-22 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm a clean branch, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Report schema/file shape, approved keys, bounds, security and app-variant
proof, atomic/cancellation behavior, paths, focused/full tests, warnings,
risks, reference need, branch, commit message, SHA, and next dependency.
Include Deviations with `None` when none. Complete the Goal only after commit
and full handoff.
```
