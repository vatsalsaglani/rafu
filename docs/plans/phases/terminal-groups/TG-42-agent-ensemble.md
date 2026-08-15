# TG-42 — Agent Terminal and Ensemble aggregate migration

## Status and execution slot

- **Status:** Planned.
- **Wave:** 4; parallel with TG-40 and TG-41.
- **Branch:** `terminal-groups/tg-42-agent-ensemble`.
- **Required base:** exact `<TG30_MERGED_SHA>`.
- **Prerequisite:** TG-30 classified process insertion API is frozen.
- **Next dependency:** TG-90 starts after all Wave 4 branches merge.

## Goal

Verify TG-30's shared direct Agent Terminal route and move every Ensemble
session creation path from direct terminal-manager mutation to the Terminal
Group aggregate. Preserve delegated auth, environment restrictions, token
lifecycle, worktree/run ownership, output capture, exit callbacks, and
user-visible naming.

Direct Agent and Ensemble panes work live inside one-pane groups. Saved layouts
retain only an unavailable placeholder. They never save or restart an Agent or
Ensemble launch descriptor in v1.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-42-agent-ensemble.md`
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

- `Sources/RafuApp/Terminal/AgentTerminalLaunchService.swift`;
- `Sources/RafuApp/Views/AgentTerminalSheet.swift`;
- `Sources/RafuApp/Views/CommandPaletteView.swift` as read-only;
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift` as read-only;
- `Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift`;
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`;
- `Sources/RafuApp/Conductor/ConductorCore.swift`;
- `Sources/RafuApp/Conductor/Run/ConductorRunController.swift` as read-only;
- `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift` as
  read-only;
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleGrant.swift`;
- the classified insertion, reveal, close, and coordinator cleanup methods in
  `Sources/RafuApp/Models/WorkspaceSession.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupModel.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupRestorationCodec.swift` as read-only;
- `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift` as read-only;
- `Tests/RafuAppTests/AgentTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/ConductorTerminalSpecTests.swift`;
- `Tests/RafuAppTests/Conductor/RunTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/EnsembleCoordinatorLaunchTests.swift`;
- `Tests/RafuAppTests/Conductor/ProcessAttributionTests.swift` as read-only;
- `Tests/RafuAppTests/Conductor/EnsembleGrantTests.swift` as read-only;
- `docs/decisions/0018-conductor-external-agent-orchestration.md`;
- `docs/decisions/0021-agent-terminals.md`;
- `docs/references/agent-terminals.md`;
- `docs/references/conductor-pty-spawn-and-child-environment.md`;
- `docs/references/conductor-pty-output-capture-pattern.md`;
- `docs/references/ensemble-consent-and-token.md`;
- `docs/references/ensemble-run-state-observability.md`; and
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift`, completely.

Use the root project-local `swift-concurrency-pro` skill. Read its complete
`SKILL.md` plus `actors.md`, `structured.md`, `cancellation.md`, `interop.md`,
`bug-patterns.md`, and `testing.md`.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift`; and
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`.

### Test paths

- `Tests/RafuAppTests/AgentTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/ConductorTerminalSpecTests.swift`;
- `Tests/RafuAppTests/Conductor/RunTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/EnsembleCoordinatorLaunchTests.swift`;
- new `Tests/RafuAppTests/Conductor/TerminalGroupAgentIntegrationTests.swift`;
  and
- new `Tests/RafuAppTests/Conductor/TerminalGroupEnsembleIntegrationTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-agent-ensemble-lifecycle.md`, only
  for a new reusable Agent/Ensemble launch, rollback, token, process, or actor
  fact.

All other paths are read-only. Do not edit `WorkspaceSession`, Agent launch
service/sheet/palette/panel, Conductor core types, run/workflow controllers,
runtime, renderer, store, commands, panel, `Package.*`, ADR, or shared index.

## Implementation contract

### A1. Agent Terminal route audit

Do not change `AgentTerminalLaunchService` or its callers. Audit the sheet,
command palette, and Terminal Manager paths. Each must continue to submit its
current `TerminalProcessSpec` to `WorkspaceSession.openAgentTerminal(spec:)`.
TG-30 assigns the direct-Agent classification inside that shared method, uses
the bounded aggregate, creates one focused group, and preserves the exact
absolute executable, argv, verified model flag, starting-directory
containment, and `PATH`-only environment rules.

The safe saved record does not retain adapter ID, model ID, executable, argv,
or environment. It stores only
`SavedTerminalPaneKind.unavailableAgentTerminal`.
The UI derives the fixed text
`Agent Terminal profiles are not saved in this version.`

### A2. Ensemble role launch

`WorkspaceConductorRunLauncher` uses the aggregate insertion API instead of
`workspaceSession.terminal.newSession(spec:)`. Preserve:

- `openConductorRun(runID)` ordering;
- read-only handoff rejection;
- shared terminal exit/attention callback;
- lane-specific `onExit` callback;
- output-log URL and Process Resources attribution;
- reveal of the exact created pane; and
- `closeTerminalSession` termination behavior.

Pass the existing lane `onExit` closure into TG-30's single lifecycle
registration seam. Do not compose a second `controller.onExit` closure. The
launcher's owner-driven `terminate(sessionID:)` uses TG-30's owner-handled
close disposition so `ConductorRunController` or
`ConductorWorkflowController` remains the one abort-state owner.

Classify the pane as an Ensemble role. It is live and visible, but its saved
form is unavailable and contains no run ID, worktree path, handoff directory,
output-log URL, or capability. It stores only the fixed unavailable-Ensemble
saved-pane kind. Its exact derived message is
`Ensemble terminal profiles are not saved in this version.`

### A3. Ensemble coordinator launch and token rollback

`ConductorCoordinatorLauncher` uses the aggregate insertion API and preserves
provider/auth/model/goal/grant behavior.

Acquire the explicit terminal-capacity reservation before minting a capability
token. Consume the reservation once insertion succeeds. Cancel it on every
pre-insertion failure. If any later pre-spawn setup step fails after mint,
revoke the token and publish no false running coordinator state. Do not leave a
registered coordinator, controller, group, pane, process resource, or capacity
reservation after a failed start.

Preserve:

- exact coordinator token environment;
- in-memory token lifetime;
- coordinator registration and completion callback;
- exit-handler composition;
- graph/session reveal; and
- provider model default normalization.

Classify the pane as Ensemble coordinator. It is never restartable from saved
layout metadata.

### A4. Six-session cap across callers

Agent, role, and coordinator starts use the same manager capacity error as
ordinary shells. A rejected launch starts zero process and does not perform a
partial run or token transition.

Map the typed error to the existing user-visible Agent or Ensemble error
surface. Do not replace it with a generic auth or provider failure.

### A5. Cleanup and reveal compatibility

The returned session UUID remains the public run/controller identity. Existing
run manifests and coordinator records do not gain group or pane IDs.
`revealTerminalSession(_:)` finds the group and exact pane.

Group close and pane close must reach the existing run/coordinator cleanup
through TG-30's prepare/cleanup/finalize close protocol. Natural exit and a
user-driven close consume the same TG-30 lifecycle registration exactly once.
This lane does not add a second controller callback chain.

### A6. Direct mutation audit

At the end, search production code for direct `terminal.newSession` and other
manager mutations. Only the temporary compatibility implementation inside the
terminal/workspace boundary can remain. Report every remaining caller. Do not
edit a foreign caller in this lane.

## Tests

Pin:

- direct Agent Terminal creates one one-pane group;
- sheet, palette, and Terminal Manager all use the same compatible
  `openAgentTerminal(spec:)` route;
- `PATH` is the only explicit child environment key and no `RAFU_*` key exists;
- Agent saved conversion has no adapter/model/executable/argv/env;
- missing/unauthed Agent error remains exact;
- Ensemble role gets one group/pane and preserves both exit handlers;
- role natural exit and user close invoke its lifecycle callback once, while
  owner-driven abort does not invoke it or double-transition run state;
- output capture and resource attribution stay unchanged;
- coordinator preflights capacity before token mint;
- failure after mint revokes token and leaves no group/session/registration;
- coordinator success preserves token and completion cleanup;
- Agent/role/coordinator seventh-session rejection is distinct and starts
  zero processes;
- reveal focuses the correct pane; and
- direct mutation audit finds only documented compatibility boundaries.

Run read-only Agent, Ensemble end-to-end, run lifecycle, grant, recovery,
process attribution, output capture, Terminal Group integration, attention,
and Process Resources filters.

## Manual acceptance

Under the Rafu Lightning GUI lease, verify one installed direct Agent Terminal
and one safe local Ensemble fixture or fake adapter:

- each opens in one group and focuses the pane;
- provider/role identity and Resources row remain correct;
- hide/reveal and attention work;
- capacity error is clear;
- save/reopen shows an unavailable stopped pane and does not launch;
- group close ends and cleans the run/coordinator once; and
- no credential, token, output, or run path appears in saved JSON.

Do not use a real paid or destructive agent run only for this gate. Use the
repository fake adapter where it covers the behavior.

## Verification and handoff

Complete all changes and the implementation record before the common final
sequence. After the parallel suite, run the bounded Rafu Lightning checks or
report exact deferrals. Run `git diff --check`, commit only TG-42 paths, and
remove this worktree's `.build` after the green commit.

The handoff reports environment/token/output-capture preservation, rollback
proof, capacity results, remaining direct mutations, security/concurrency
review, tests, warnings, manual evidence, paths, branch, commit message, SHA,
next dependency, and **Deviations**.

## Implementation record

To be completed by the TG-42 implementor before the final gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-42 from
docs/plans/phases/terminal-groups/TG-42-agent-ensemble.md: verify every direct
Agent Terminal surface uses TG-30's bounded aggregate adapter, migrate Ensemble
role and coordinator creation to that aggregate, preserve auth, environment,
token, output, exit, and cleanup contracts, verify, and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run
`git switch terminal-groups/tg-42-agent-ensemble` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-42-agent-ensemble, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG30_MERGED_SHA>`.
Do not create or replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-42-agent-ensemble.md;
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
reference path in TG-42. Read and use the root swift-concurrency-pro skill with
all TG-42 named references. Do not use nested duplicate skills.

Edit only WorkspaceConductorRunLauncher.swift,
ConductorCoordinatorLauncher.swift, TG-42-owned tests, this plan's record, and
conditional docs/references/terminal-group-agent-ensemble-lifecycle.md only
when its documented trigger applies. Treat WorkspaceSession, all four Agent
Terminal launch surfaces, Conductor core/run/workflow types, Terminal Group
foundation, commands, manager, Package.swift, ADRs, and shared indexes as
read-only.

Implement A1 through A6. Verify all direct Agent callers use TG-30's shared
aggregate adapter. Route both Ensemble caller classes through the aggregate.
Preserve Agent PATH-only environment, Ensemble environment and token, output
capture, Process Resources attribution, exit callback composition, and cleanup.
Preflight capacity before token mint and roll back every pre-spawn setup side
effect on failure. Live Agent and Ensemble panes are not restartable saved
profiles; their saved form contains no provider, model, argv, environment,
token, run path, or output path.
Pass role lifecycle ownership through TG-30's one callback registration. Do
not install a second controller callback, and keep owner-driven abort from
causing a second run-state transition.

Add the exact focused tests and run all named read-only regressions. Use one
SwiftPM invocation at a time. Isolate failures and never edit an unowned
failure. Use fake adapters for bounded verification.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Under the GUI lease, run bounded Rafu Lightning checks or report
exact deferrals. Run `git diff --check`.

Stage only TG-42 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm clean status, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Report preserved security/process contracts, token rollback, capacity,
remaining direct mutations, paths, focused/full tests, warnings, manual
evidence, risks, reference need, branch, commit message, SHA, and next
dependency. Include Deviations with `None` when none. Complete the Goal only
after commit and full handoff.
```
