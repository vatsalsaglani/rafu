# TG-110 — Runtime capacity and pane metadata

## Status

Planned.

## Branch and worker

- Worker: Luna Implementor
- Branch: `terminal-groups/tg-110-v2-runtime-capacity-metadata`
- Required base: `<TG100_MERGED_SHA>`
- Execution environment: a coordinator-created Git worktree.

## Goal

Apply the TG-100 contracts to every runtime, restoration, saved-layout, Agent,
and Ensemble path. Make pane rename and theme-color mutations authoritative in
the Terminal Group snapshot and mirror them to a live controller when one
exists.

## Required reading

- `AGENTS.md`
- `docs/decisions/0024-terminal-group-v2-limits-and-pane-metadata.md`
- `docs/plans/phases/terminal-groups/TG-100-v2-contracts.md`
- `docs/plans/phases/terminal-groups/TG-20-runtime.md`
- `docs/plans/phases/terminal-groups/TG-22-persistence.md`
- `docs/plans/phases/terminal-groups/TG-30-workspace-integration.md`
- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`
- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift`
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift`
- `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `.agents/skills/swift-concurrency-pro/SKILL.md`

## Exclusive ownership

- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift`
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift`
- `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Tests/RafuAppTests/TerminalGroupCapacityTests.swift`
- `Tests/RafuAppTests/TerminalGroupRuntimeTests.swift`
- `Tests/RafuAppTests/TerminalGroupLifecycleTests.swift`
- `Tests/RafuAppTests/TerminalGroupRestorationContractTests.swift`
- `Tests/RafuAppTests/TerminalGroupRestorationIntegrationTests.swift`
- `Tests/RafuAppTests/TerminalGroupPersistenceSecurityTests.swift`
- `Tests/RafuAppTests/TerminalGroupSavedLayoutStoreTests.swift`
- `Tests/RafuAppTests/TerminalGroupSessionIntegrationTests.swift`
- `Tests/RafuAppTests/TerminalGroupCommandPresentationTests.swift`
- `Tests/RafuAppTests/AgentTerminalTests.swift`
- `Tests/RafuAppTests/Conductor/EnsembleCoordinatorLaunchTests.swift`
- `Tests/RafuAppTests/Conductor/RunTerminalTests.swift`
- this plan file

Do not edit views, shared contract files, ADRs, the manifest, or another lane's
tests. Do not revert other work.

## Behavior

1. Enforce 20 groups before every group insertion. Active and parked groups
   count. Group 20 succeeds; group 21 returns a typed error with no mutation.
2. Enforce 10 panes in one group, 200 retained panes, and 200 live sessions by
   their separate constants. Keep all preflight, reservation, consume, cancel,
   and rollback behavior atomic.
3. Apply the same bounds to ordinary shells, saved-layout open, inert restore,
   Agent terminal adoption, and Ensemble run terminals. Saved-layout library
   capacity remains 32.
4. Restoration remains inert, bounded, and sibling-isolated when one record is
   malformed.
5. Rename a pane by runtime pane ID. Empty input clears the explicit name.
   Reject an invalid name before mutation. Update the snapshot, mirror the live
   controller, increment generation, and schedule workspace persistence.
6. Set or clear a theme-token pane color by pane ID. Mirror the equivalent
   preset to a live controller. Never put a custom hex color in the snapshot.
   Stopped and unavailable panes still accept safe name and color metadata.
7. Keep legacy session-ID rename/color APIs working for legacy terminal tabs.

Tests must prove no controller construction, token mint, tree change, partial
restoration, or metadata drift after a failed operation. Include 20/21 group,
10/11 pane, 200/201 retained, and 200/201 live boundaries.

## Gates and Goal Mode prompt

Run `./script/format.sh --fix`, `./script/format.sh --lint`,
`./script/build.sh`, `./script/test.sh`, and `git diff --check` in that order.
Use parallel tests only. No tracked-file edit is permitted after the test.

> Call `create_goal` first with objective "Complete TG-110 from
> `docs/plans/phases/terminal-groups/TG-110-v2-runtime-capacity-metadata.md`".
> Confirm a clean Git worktree on branch
> `terminal-groups/tg-110-v2-runtime-capacity-metadata` at exact commit
> `<TG100_MERGED_SHA>` and confirm it is not the primary checkout. Stop without
> edits if false. Read all required files and the concurrency skill. Implement
> only owned paths. Run the ordered parallel gates, commit, and remove this
> worktree's `.build` last. Do not merge, rebase, or push. Report branch, commit
> SHA, changed files, tests, security and concurrency review, risks, and
> Deviations.

