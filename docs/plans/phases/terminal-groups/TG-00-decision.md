# TG-00 — Terminal Groups decision and scope contract

## Status and execution slot

- **Status:** Planned.
- **Wave:** 0; serial prerequisite for all source plans.
- **Branch:** `terminal-groups/tg-00-decision`.
- **Required base:** exact `<PLAN_SHA>` from the committed plan set.
- **Next dependency:** TG-10 starts only after TG-00 merges.

## Goal

Record the durable product and architecture decision for compound terminal
tabs and safe saved layouts. Remove every direct conflict in current accepted
guidance before source code changes.

Pasting this plan's Goal Mode prompt is explicit approval to create and Accept
ADR 0023 with the contract in the parent phase. Reading this plan without
dispatching the prompt is not implementation approval.

This plan changes no Swift source, resource, package metadata, or test.

## Required reading and skills

Read completely, in order:

1. `AGENTS.md`
2. [`README.md`](README.md)
3. [`../terminal-groups.md`](../terminal-groups.md)
4. [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
5. [`../../rafu_product_architecture_plan.md`](../../rafu_product_architecture_plan.md)
6. [`../../../decisions/0004-embedded-terminal.md`](../../../decisions/0004-embedded-terminal.md)
7. [`../../../decisions/0014-terminal-as-editor-tab.md`](../../../decisions/0014-terminal-as-editor-tab.md)
8. [`../../../decisions/0016-terminal-attention-notifications.md`](../../../decisions/0016-terminal-attention-notifications.md)
9. [`../../../decisions/0018-conductor-external-agent-orchestration.md`](../../../decisions/0018-conductor-external-agent-orchestration.md)
10. [`../../../decisions/0021-agent-terminals.md`](../../../decisions/0021-agent-terminals.md)
11. [`../../../decisions/README.md`](../../../decisions/README.md)
12. [`../../../decisions/open-decisions.md`](../../../decisions/open-decisions.md)
13. [`../editor-terminal-tabs.md`](../editor-terminal-tabs.md)
14. [`../terminal-manager.md`](../terminal-manager.md)
15. [`../workbench-presentation-upgrade.md`](../workbench-presentation-upgrade.md)
16. [`../conductor/AT-01-agent-terminal-sessions.md`](../conductor/AT-01-agent-terminal-sessions.md)
17. [`../README.md`](../README.md)
18. [`../../../references/editor-search-and-restoration.md`](../../../references/editor-search-and-restoration.md)
19. [`../../../references/window-scoped-modifier-key-switcher.md`](../../../references/window-scoped-modifier-key-switcher.md)
20. [`../../../references/terminal-signals-and-shell-catalog.md`](../../../references/terminal-signals-and-shell-catalog.md)
21. [`../../../references/agent-terminals.md`](../../../references/agent-terminals.md)
22. [`../../../references/skill-routing.md`](../../../references/skill-routing.md)
23. [`../../../references/build-and-run.md`](../../../references/build-and-run.md)

No implementation skill is required because this is a documentation-only
decision plan. Do not use a skill to widen the approved product contract.

## Exclusive ownership

TG-00 may edit only:

- new `docs/decisions/0023-terminal-groups-and-saved-layouts.md`;
- `docs/decisions/0004-embedded-terminal.md`;
- `docs/decisions/0014-terminal-as-editor-tab.md`;
- `docs/decisions/0018-conductor-external-agent-orchestration.md`, only for
  the targeted restoration-schema, unavailable-placeholder, and six-session
  limit amendment;
- `docs/decisions/0021-agent-terminals.md`, only to clarify inert unavailable
  placeholders and no saved launch profile;
- `docs/decisions/README.md`;
- `docs/decisions/open-decisions.md`;
- `AGENTS.md`;
- `docs/plans/rafu_product_architecture_plan.md`;
- `docs/plans/phases/pre-initial-push-workbench.md`;
- `docs/plans/phases/editor-terminal-tabs.md`;
- `docs/plans/phases/terminal-manager.md`;
- `docs/plans/phases/workbench-presentation-upgrade.md`;
- `docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md`, only to
  replace its stale nonrestorable-tab wording with the inert-placeholder rule;
- `docs/plans/phases/README.md`;
- `docs/plans/phases/terminal-groups.md`;
- `docs/plans/phases/terminal-groups/README.md`, only the TG-00 status or
  execution record; and
- this plan's Status and implementation record.

All source, test, resource, package, script, environment, reference-index, and
other plan files are read-only. Do not create the final implementation
reference note in this plan.

## Decision contract

### D1. Create ADR 0023

Create **ADR 0023: Terminal Groups and saved layouts** with status Accepted.
It must state that current user direction supersedes or amends only these
older parts:

- ADR 0004's workspace-root-only terminal starting-directory rule, replaced
  by selected in-workspace file directory with workspace-root fallback;
- ADR 0004's panel/controller-only presentation boundary and bottom-panel
  toggle rule, replaced by one Terminal Group editor tab with pane views and
  group-level toggle behavior;
- ADR 0004's one-controller-per-panel-tab rule, replaced by one controller per
  live terminal pane inside the group tab;
- ADR 0004's session-level `Control-backtick` and close-tab behavior, including
  its 2026-07-21 amendment, replaced by group park/MRU/create and coordinated
  pane/group close;
- ADR 0014's one-session-per-terminal-tab presentation;
- ADR 0014's prohibition on terminal layout metadata restoration;
- ADR 0014's session-level `Control-backtick` parking and MRU rule, replaced
  by group-level park, group MRU reveal, and create fallback;
- `terminal-manager.md`'s v1 non-goal for splits inside one tab;
- ADR 0018's statement that the workspace UserDefaults restoration schema is
  untouched; and
- ADR 0018's terminal-cap language, so the six-live-session window limit
  includes Ensemble coordinator and role terminals.

ADR 0018 still prohibits restoration of a live role session. Only an inert,
unavailable metadata placeholder can restore, and it contains no launch
descriptor or Ensemble capability.

It must preserve lazy spawn, bounded scrollback, explicit user start, no task
runner, no automatic command execution, per-window ownership, and teardown.

### D2. Lock product terms and shortcuts

Copy the parent phase's exact terms and shortcut context. In particular:

- use Terminal Group, terminal pane, Split Right, and Split Down;
- `Command-T` opens a group or splits right;
- `Shift-Command-T` splits down only in an active group;
- `Control-Shift-backtick` always creates a new one-pane group;
- `Control-backtick` parks the selected group, otherwise reveals the most
  recently parked group, and creates a group only when none is parked;
- `Control-Command-Arrow` moves pane focus without wrap;
- `Command-S` and `Shift-Command-S` route by selected-tab context; and
- Control-Tab lists one group once.

Do not use Option-Command-Up/Down because editor multi-caret actions own them.

### D3. Lock safe saved data

State the complete allow-list and deny-list from the parent phase. Separate
`SavedTerminalGroupID` and record-local saved node IDs from runtime group,
pane, split, and session IDs. Each Open creates fresh runtime IDs, so the same
named layout can open more than once. A saved group is metadata, not a restored
terminal session. Only ordinary shell profiles restart in v1. Agent Terminal
and Ensemble panes restore as unavailable placeholders and save no launch
descriptor. Only an explicit user pane name can persist; OSC-reported titles
and computed display names cannot persist.

### D4. Lock lifecycle and capacity

Record the six-pane-per-group bound, the 24-retained-terminal-pane window
bound, and the separate six-live-session window cap across all shell, Agent,
and Ensemble paths. Define retained pane, live session, reserved slot, and live
process. New, Split, and Open Saved Group reject an operation that exceeds the
retained-pane bound without mutation. Record zero-start capacity preflight and
the honest per-pane result after an external spawn failure. Record group
hide/reveal, pane close, group close, actual live-process confirmation count,
exited-pane behavior, workspace switch, window close, and app-quit rules. State
that Start All Restartable Panes ignores unavailable placeholders.

### D5. Correct affected guidance

- Add a superseded note to ADR 0014. Keep legacy decode compatibility.
- Amend ADR 0004's start-directory rule and add the Terminal Groups
  cross-reference.
- Add the targeted restoration and capacity amendment to ADR 0018. Do not
  change its naming, delegated-auth, file-handoff, capability, or merge gates.
- Clarify ADR 0021 without allowing Agent launch descriptors to persist.
- Correct the stale restoration sentence in
  `docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md`.
- Remove the terminal-split non-goal from `terminal-manager.md` and point to
  this phase. Add one prominent Terminal Groups supersession section that
  marks the old one-session-per-tab, session-level park/MRU, session-level
  restoration, and one-session tab-close rules as historical compatibility
  behavior. Replace current normative guidance with group ownership and
  prepare/cleanup/finalize close behavior.
- Mark T2 restoration and the six-session choice as resolved in
  `editor-terminal-tabs.md`. Add the same prominent supersession section and
  mark its session-per-tab, session park, placeholder restoration, and
  one-session tab-close text as historical rather than current guidance. Close
  TD1 with the exact contextual `Command-T`, group-only `Shift-Command-T`, and
  always-new `Control-Shift-backtick` routes.
- In `terminal-manager.md`, record group-level toggle as the narrow replacement
  for session-level toggle and Set Pane Starting Folder as the narrow exception
  to its old workspace-root/profile guidance. Keep observed OSC working
  directory display live-only. Supersede its accepted no-cap trade-off for
  exited sessions: exited panes now count toward the 24-retained-pane bound.
- Amend acceptance item 7 in the active phase for safe named Terminal Group
  metadata and inert, zero-process restoration.
- Update acceptance item 22 in the active phase to list one group once.
- Add a new active acceptance item for one compound tab, contextual
  `Command-T`, group-only `Shift-Command-T`, directional focus, rename, Save,
  inert zero-process restore, always-new `Control-Shift-backtick`, and
  group-level `Control-backtick` park/MRU/create order, with separate six-pane,
  24-retained-pane, and six-live-session bounds.
- Update both stale "21 acceptance items" statements in the active phase to
  the new total of 23.
- Change the active phase status from fully Implemented to In Progress. State
  that its earlier workbench baseline is implemented, but acceptance items 7,
  22, and 23 remain open until the Terminal Groups set completes.
- Change `terminal-groups.md` from Proposed to In Progress after ADR 0023 is
  Accepted. Change its execution README from Proposed to Active and record that
  TG-00 is complete and TG-10 is next.
- Update the canonical plan so it does not call the embedded terminal a
  current non-goal.
- Update the presentation plan only to point layout behavior to this phase;
  do not rewrite its implemented visual scope.
- Update the Terminal Groups row that already exists in the phase index after
  ADR 0023 is Accepted. Do not add a duplicate row.
- Update `AGENTS.md` only with the durable feature boundary and source-of-truth
  pointer. Do not add unproved implementation details.

## Tests and validation

Perform a documentation consistency check before the final gate:

- all new relative links resolve;
- ADR 0023 has one indexed Accepted row;
- no active document says terminal splits are a current non-goal;
- no active document says a live terminal process restores;
- Agent and Ensemble naming follows ADR 0018 and ADR 0021;
- all shortcut statements agree; and
- the source contract plans still use the exact ADR filename.

Run the complete common final sequence even though this plan is docs-only.

## Manual acceptance

No GUI pass is required. The merge owner must review the ADR diff and confirm
that it does not approve process persistence, command injection, or Agent or
Ensemble capability persistence.

## Verification and handoff

Complete all documentation and the implementation record before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing modifies a tracked file after the parallel suite. Run
`git diff --check`, stage only TG-00 paths, and create one local commit. Do not
push or merge. Remove only this worktree's `.build` after the green commit.

The handoff includes the ADR result, every corrected conflict, exact paths,
gate results, branch, commit message, commit SHA, remaining risks, next step
(user-authorized merge to primary `main` and TG-10), and a **Deviations**
section.

## Implementation record

To be completed by the TG-00 implementor before the final gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-00 from
docs/plans/phases/terminal-groups/TG-00-decision.md: record and reconcile
Rafu's Terminal Groups decision, verify all affected guidance, commit it
locally, and provide the exact decision commit for TG-10."

You are in a dedicated worktree. Run `git status --short --branch` before any
branch change. Stop if the worktree is not clean. Then run
`git switch terminal-groups/tg-00-decision` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-00-decision, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<PLAN_SHA>`. Do not
create or replace a branch. Do not rebase or modify user work.

Read completely, in order: AGENTS.md;
docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-00-decision.md;
docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/plans/rafu_product_architecture_plan.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0016-terminal-attention-notifications.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/README.md; docs/decisions/open-decisions.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/plans/phases/workbench-presentation-upgrade.md;
docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md;
docs/plans/phases/README.md;
docs/references/editor-search-and-restoration.md;
docs/references/window-scoped-modifier-key-switcher.md;
docs/references/terminal-signals-and-shell-catalog.md;
docs/references/agent-terminals.md;
docs/references/skill-routing.md; and
docs/references/build-and-run.md. No implementation skill is required.

Treat this dispatched prompt as explicit approval to create and Accept ADR
0023 with the exact parent-phase contract. Implement only the TG-00-owned
documentation paths. Do not edit source, tests, resources, packages, scripts,
references, or another plan. Preserve lazy bounded terminals, explicit user
start, no automatic command execution, no process restoration, and the Agent
and Ensemble capability boundaries.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete the consistency checks and implementation record before this final
order:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Run `git diff --check`.

Stage only TG-00-owned paths and create one intentional local commit. This
prompt authorizes that local commit only. Do not push, merge, open a PR,
publish, release, or edit main. Confirm a clean branch, record the branch,
commit message, and `git rev-parse HEAD`.
Then remove only this worktree's `.build` as the last filesystem step.

Report delivered decision changes, changed paths, documentation consistency
evidence, build and parallel-test results, warning count, security review,
remaining risks, branch, commit message, commit SHA, and next dependency.
Include a Deviations section with `None` when there are no deviations. For a
deviation, give the contract item, evidence, reason, owner, authorization, and
required merge-owner action. Complete the Goal only after the clean local
commit and full handoff.
```
