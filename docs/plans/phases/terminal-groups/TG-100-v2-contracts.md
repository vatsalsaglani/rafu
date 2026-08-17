# TG-100 — Terminal Groups v2 contracts

## Status

Planned.

## Branch and worker

- Worker: Luna Implementor
- Branch: `terminal-groups/tg-100-v2-contracts`
- Required base: `<TG_V2_PLAN_SHA>`
- Execution environment: a coordinator-created Git worktree. Never edit the
  primary checkout.

## Goal

Freeze the resource and pane-metadata contracts required for Terminal Groups
v2. Add ADR 0024. Separate all four window limits and add source contracts for
pane rename and pane theme-color changes. This lane must not change reachable
runtime or UI behavior.

The approved limits are:

- at most 20 open or parked Terminal Groups per workspace window;
- at most 10 retained panes per group;
- at most 200 retained panes per workspace window;
- at most 200 live terminal sessions per workspace window; and
- at most 32 saved layouts per workspace, unchanged.

Group and retained-pane limits count active and parked groups. All capacity
failures are typed and cause no mutation. A pane name remains optional and
bounded to 80 Unicode scalars. A saved pane color remains a theme token. Never
persist a custom hex color, OSC title, process data, command, environment,
provider/model value, token, output, or Agent/Ensemble capability.

## Required reading

Read these files before editing:

- `AGENTS.md`
- `docs/decisions/0018-conductor-external-agent-orchestration.md`
- `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
- `docs/plans/phases/terminal-groups.md`
- `docs/plans/phases/terminal-groups/README.md`
- `docs/plans/phases/terminal-groups/manifest.md`
- `docs/plans/phases/terminal-groups/TG-10-source-contracts.md`
- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`
- `Tests/RafuAppTests/TerminalGroupContractTests.swift`
- `.agents/skills/swift-concurrency-pro/SKILL.md`

## Exclusive ownership

- `docs/decisions/0024-terminal-group-v2-limits-and-pane-metadata.md`
- `docs/decisions/README.md`
- `docs/decisions/0018-conductor-external-agent-orchestration.md`
- `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
- `docs/plans/phases/terminal-groups.md`
- `docs/plans/phases/editor-terminal-tabs.md`
- `docs/plans/phases/pre-initial-push-workbench.md`
- `docs/plans/phases/terminal-manager.md`
- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`
- `Tests/RafuAppTests/TerminalGroupContractTests.swift`
- this plan file

Do not edit the manifest. The coordinator owns it. You are not alone in the
repository. Do not revert or rewrite another lane's work.

## Contract work

1. Add accepted ADR 0024. Record that it supersedes only the numeric limits in
   ADR 0023 and ADR 0018. Explain the explicit 200-live-session resource bound
   and the later Release measurement requirement.
2. Add one `nonisolated`, `Sendable` limit contract with separate constants for
   groups, panes per group, retained panes, and live sessions. Do not reuse one
   constant for a different resource.
3. Add a typed group-capacity error. Keep reservation and close-token payloads
   bounded by the 10-pane per-group limit.
4. Add bounded commands/effects needed to set or clear an explicit pane name
   and set or clear a pane theme color by `TerminalPaneID`. Keep runtime IDs and
   saved IDs separate.
5. Reconcile current source-of-truth plans. Completed lane records remain
   historical facts; add narrow supersession notes instead of rewriting them.
6. Tests must prove exact constant values, name validation, theme-token-only
   metadata, `Sendable` value boundaries, and legacy codec compatibility.

## Gates

Run these commands in this order, with no tracked-file edit after the test:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
git diff --check
```

Use parallel tests only. Commit all owned changes to the listed branch. Remove
only this worktree's `.build` directory after the green commit.

## Goal Mode start prompt

> Call `create_goal` first with the objective: "Complete TG-100 from
> `docs/plans/phases/terminal-groups/TG-100-v2-contracts.md`" and no token
> budget. Confirm that your environment is a Git worktree, that the branch is
> `terminal-groups/tg-100-v2-contracts`, that the clean starting commit is
> `<TG_V2_PLAN_SHA>`, and that the repository root is not the primary checkout.
> Stop without edits if any check fails. Read every required file and skill.
> Implement only the exclusive paths. Run the ordered gates with parallel
> tests, commit all work, then remove only this worktree's `.build`. Never
> merge, rebase, push, or edit `main`. Report branch, commit SHA, changed files,
> test results, security/concurrency review, unresolved risks, and a named
> Deviations section.

