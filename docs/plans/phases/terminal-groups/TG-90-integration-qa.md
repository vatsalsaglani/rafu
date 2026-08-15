# TG-90 — Terminal Groups integration, security, measurement, and close-out

## Status and execution slot

- **Status:** Planned.
- **Wave:** 5; final serial plan.
- **Branch:** `terminal-groups/tg-90-integration-qa`.
- **Required base:** exact `<WAVE4_MERGED_SHA>`.
- **Prerequisites:** TG-00 through TG-42 are merged in the execution order.
- **Next dependency:** user-authorized local merge to primary `main`, then
  final gates.

## Goal

Prove the complete Terminal Groups set as one product. Fix only integrated
defects, close temporary compatibility seams that have no callers, complete
security and concurrency review, record optimized Rafu Lightning resource
evidence, and make every decision, phase, and reference document honest.

TG-90 does not change ADR 0023 to match an implementation deviation. Fix code
to match the decision or stop for user direction.

## Required reading and skills

Read completely:

- `AGENTS.md`;
- `docs/plans/phases/terminal-groups/README.md`;
- `docs/plans/phases/terminal-groups/TG-90-integration-qa.md`;
- `docs/plans/phases/terminal-groups/TG-00-decision.md` and its implementation
  record;
- `docs/plans/phases/terminal-groups/TG-10-source-contracts.md` and its
  implementation record;
- `docs/plans/phases/terminal-groups/TG-20-runtime.md` and its implementation
  record;
- `docs/plans/phases/terminal-groups/TG-21-renderer-focus.md` and its
  implementation record;
- `docs/plans/phases/terminal-groups/TG-22-persistence.md` and its
  implementation record;
- `docs/plans/phases/terminal-groups/TG-30-workspace-integration.md` and its
  implementation record;
- `docs/plans/phases/terminal-groups/TG-40-manager-switcher.md` and its
  implementation record;
- `docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md` and its
  implementation record;
- `docs/plans/phases/terminal-groups/TG-42-agent-ensemble.md` and its
  implementation record;
- [`../terminal-groups.md`](../terminal-groups.md);
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md);
- `docs/decisions/0004-embedded-terminal.md`;
- `docs/decisions/0014-terminal-as-editor-tab.md`;
- `docs/decisions/0016-terminal-attention-notifications.md`;
- `docs/decisions/0018-conductor-external-agent-orchestration.md`;
- `docs/decisions/0021-agent-terminals.md`;
- `docs/decisions/0023-terminal-groups-and-saved-layouts.md`;
- `docs/decisions/README.md`;
- `docs/plans/rafu_product_architecture_plan.md`;
- `docs/plans/phases/editor-terminal-tabs.md`;
- `docs/plans/phases/terminal-manager.md`;
- `docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md`;
- `docs/plans/phases/README.md`;
- the complete production ownership list in this plan;
- `Tests/RafuAppTests/TerminalGroupContractTests.swift`;
- `Tests/RafuAppTests/TerminalGroupRestorationContractTests.swift`;
- `Tests/RafuAppTests/EditorLayoutTests.swift`;
- `Tests/RafuAppTests/TerminalGroupRuntimeTests.swift`;
- `Tests/RafuAppTests/TerminalGroupLifecycleTests.swift`;
- `Tests/RafuAppTests/TerminalGroupCapacityTests.swift`;
- `Tests/RafuAppTests/TerminalGroupViewPresentationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupFocusBridgeTests.swift`;
- `Tests/RafuAppTests/TerminalGroupSplitViewTests.swift`;
- `Tests/RafuAppTests/TerminalGroupRestorationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupSavedLayoutStoreTests.swift`;
- `Tests/RafuAppTests/TerminalGroupPersistenceSecurityTests.swift`;
- `Tests/RafuAppTests/TerminalEditorTabTests.swift`;
- `Tests/RafuAppTests/WorkspaceCloseActionTests.swift`;
- `Tests/RafuAppTests/TerminalAttentionTests.swift`;
- `Tests/RafuAppTests/EditorTabAndGroupPresentationTests.swift`;
- `Tests/RafuAppTests/EditorTabVisibilityPresentationTests.swift`;
- `Tests/RafuAppTests/EditorThemeColorApplicationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupSessionIntegrationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupRestorationIntegrationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupCloseIntegrationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupAttentionIntegrationTests.swift`;
- `Tests/RafuAppTests/TerminalsPanelTests.swift`;
- `Tests/RafuAppTests/TerminalIdentityTests.swift`;
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`;
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`;
- `Tests/RafuAppTests/TerminalGroupManagerHierarchyTests.swift`;
- `Tests/RafuAppTests/TerminalGroupSwitcherPresentationTests.swift`;
- `Tests/RafuAppTests/SearchCommandPaletteTests.swift`;
- `Tests/RafuAppTests/TerminalGroupCommandPresentationTests.swift`;
- `Tests/RafuAppTests/TerminalGroupSaveSheetTests.swift`;
- `Tests/RafuAppTests/TerminalPaneStartingFolderPickerTests.swift`;
- `Tests/RafuAppTests/AgentTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/ConductorTerminalSpecTests.swift`;
- `Tests/RafuAppTests/Conductor/RunTerminalTests.swift`;
- `Tests/RafuAppTests/Conductor/EnsembleCoordinatorLaunchTests.swift`;
- `Tests/RafuAppTests/Conductor/TerminalGroupAgentIntegrationTests.swift`;
- `Tests/RafuAppTests/Conductor/TerminalGroupEnsembleIntegrationTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupsEndToEndTests.swift`;
- all lane-created reference notes;
- `docs/references/README.md`;
- `docs/references/build-and-run.md`;
- `docs/references/memory-and-file-indexing.md`;
- `docs/references/memory-caps-and-pressure.md`;
- `docs/references/memory-attribution-and-timeline.md`;
- `docs/references/editor-search-and-restoration.md`;
- `docs/references/window-scoped-modifier-key-switcher.md`;
- `docs/references/workspace-lifecycle-dual-funnel.md`;
- `docs/references/terminal-signals-and-shell-catalog.md`;
- `docs/references/agent-terminals.md`;
- `docs/references/conductor-pty-spawn-and-child-environment.md`;
- `docs/references/ensemble-consent-and-token.md`; and
- `docs/references/skill-routing.md`.

Use:

1. project-local `swiftui-expert-skill` with complete `SKILL.md`, latest APIs,
   state, structure, layout, focus, accessibility, performance, trace
   recording/analysis, macOS scenes, and macOS views references;
2. root project-local `swift-concurrency-pro` with complete `SKILL.md`, actors,
   structured work, async streams, cancellation, interop, bug patterns,
   diagnostics, and testing references;
3. Build macOS Apps `build-run-debug`, complete;
4. Build macOS Apps `appkit-interop` with representables and responder-menus;
5. Build macOS Apps `swiftui-patterns` with commands-menus and
   split-inspectors;
6. Build macOS Apps `window-management`, complete; and
7. Build macOS Apps `telemetry` if a narrow signpost is required for measured
   typing or split-render spans.

Use `test-triage` only after a failure needs classification.

## Exclusive ownership

TG-90 may edit only to fix a proved integration defect or remove an unused
temporary adapter:

- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRestoration.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupView.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupSplitView.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupRestorationCodec.swift`;
- `Sources/RafuApp/Terminal/TerminalGroupSavedLayoutStore.swift`;
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`;
- `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`;
- `Sources/RafuApp/Terminal/RafuTerminalView.swift`;
- `Sources/RafuApp/Terminal/TerminalsPanelModel.swift`;
- `Sources/RafuApp/Models/WorkspaceSession.swift`;
- `Sources/RafuApp/Editor/EditorLayout.swift`;
- `Sources/RafuApp/Editor/EditorTabSwitcher.swift`;
- `Sources/RafuApp/Services/WorkspaceRestorationStore.swift`;
- `Sources/RafuApp/Views/EditorCanvasView.swift`;
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`;
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`;
- `Sources/RafuApp/Views/EditorTabSwitcherView.swift`;
- `Sources/RafuApp/Views/TerminalGroupSavedLayoutsSection.swift`;
- `Sources/RafuApp/Views/TerminalGroupSaveSheet.swift`;
- `Sources/RafuApp/Views/TerminalPaneStartingFolderPicker.swift`;
- `Sources/RafuApp/App/RafuAppCommands.swift`;
- `Sources/RafuApp/Views/CommandPaletteView.swift`;
- `Sources/RafuApp/Conductor/Run/WorkspaceConductorRunLauncher.swift`;
- `Sources/RafuApp/Conductor/Ensemble/ConductorCoordinatorLauncher.swift`;
- `script/build_and_run.sh`, only if an optimized Rafu Lightning staging mode
  is absent and is required for Release-configuration measurement; and
- each exact test file in the required-reading list above.

TG-90 owns these documentation paths:

- this plan's Status and implementation record;
- new `docs/references/terminal-group-layout-and-restoration.md`;
- any existing reserved optional lane reference paths listed in the execution
  README;
- `docs/references/README.md`;
- `docs/references/editor-search-and-restoration.md`;
- `docs/references/editor-window-close-resolution-order.md`;
- `docs/references/window-scoped-modifier-key-switcher.md`;
- `docs/references/workspace-lifecycle-dual-funnel.md`;
- `docs/references/memory-caps-and-pressure.md`;
- `docs/references/agent-terminals.md`;
- `docs/references/build-and-run.md`, only if the optimized Lightning mode is
  added;
- `docs/plans/phases/terminal-groups.md`;
- `docs/plans/phases/terminal-groups/README.md`;
- `docs/plans/phases/terminal-groups/TG-00-decision.md`, integrated Status
  only;
- `docs/plans/phases/terminal-groups/TG-10-source-contracts.md`, integrated
  Status only;
- `docs/plans/phases/terminal-groups/TG-20-runtime.md`, integrated Status only;
- `docs/plans/phases/terminal-groups/TG-21-renderer-focus.md`, integrated
  Status only;
- `docs/plans/phases/terminal-groups/TG-22-persistence.md`, integrated Status
  only;
- `docs/plans/phases/terminal-groups/TG-30-workspace-integration.md`, integrated
  Status only;
- `docs/plans/phases/terminal-groups/TG-40-manager-switcher.md`, integrated
  Status only;
- `docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md`, integrated
  Status only;
- `docs/plans/phases/terminal-groups/TG-42-agent-ensemble.md`, integrated
  Status only;
- `docs/plans/phases/pre-initial-push-workbench.md`;
- `docs/plans/phases/editor-terminal-tabs.md`;
- `docs/plans/phases/terminal-manager.md`;
- `docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md`, only for
  final consistency of the inert unavailable-placeholder rule;
- `docs/plans/phases/README.md`;
- `docs/plans/rafu_product_architecture_plan.md`;
- `docs/decisions/README.md`, status/index corrections only; and
- `AGENTS.md`, only if implementation proved a rule that nearly every future
  task must know.

`Package.*`, dependencies, resources, unrelated source/tests/docs, accepted ADR
body text, release workflow, signing, and distribution paths are read-only.
Every production correction must be named separately in the handoff.

## Integration contract

### Q1. Ancestry and ownership audit

Before editing:

- confirm every lane commit is an ancestor of HEAD;
- compare each branch to its exact base;
- confirm changed paths match lane ownership;
- read every deviation and deferred check; and
- search for unresolved conflict markers, TODO stubs, temporary compatibility
  comments, and stale placeholders outside the documented Goal Mode templates.
  The immutable base tokens in tracked prompt templates remain by design; the
  coordinator substituted SHAs only in dispatched prompt copies.

Reject an unexplained foreign change. Do not hide it in the final commit.

### Q2. Direct mutation and model audit

Prove one authoritative model for group tree, focus, membership, capacity, and
saved records. Search for:

- direct `terminal.newSession` outside documented compatibility boundaries;
- new `.terminal(sessionID:)` creation;
- duplicate group or pane state in a view;
- session UUID used as pane ID;
- named saved-record ID reused as a runtime group, pane, or split ID;
- process start during decode/restore;
- store access from `body`;
- strong callback cycles; and
- Agent or Ensemble data entering a restartable saved profile.

Remove a temporary adapter only when the search and tests prove zero callers.

### Q3. Automated end-to-end coverage

Use `Tests/RafuAppTests/TerminalGroupsEndToEndTests.swift` for new integrated
tests when lane tests do not already prove:

- one pane, two columns, two rows, a four-pane grid, and a mixed nested tree;
- divider fraction save/restore;
- narrow-window minimum-size clamping does not overwrite a saved divider
  fraction, which returns when space is available;
- pointer plus four-direction focus;
- one outer editor tab and one Control-Tab candidate;
- group rename and default numbering;
- contextual New/Split/Save/Save As commands plus the always-available
  `Control-Shift-backtick` New Terminal Group and exact `Control-backtick`
  park/MRU/create order;
- save-sheet, folder-picker, and close-confirmation modal precedence for New,
  Split, Save, Save As, Close, toggle, and directional-focus shortcuts;
- pane and group close, confirmation, cleanup, and split collapse;
- stale close confirmation performs zero cleanup and refreshes changed session
  or live-process details before a new confirmation;
- role cleanup exactly once on natural exit or user close, with no callback or
  double transition on owner-driven abort;
- role/coordinator cleanup before controller shutdown on workspace switch,
  window close, and app quit;
- park/reveal and exact pane reveal by session;
- per-pane and aggregate attention;
- two Opens with fresh runtime IDs, delete detachment, and inert workspace
  restore without stale-record resurrection;
- zero process/resource registration during restore;
- explicit starting-folder validation, split inheritance, and no live-CWD
  persistence;
- starting-folder symlink escape rejection at selection and start-time
  revalidation;
- selected in-workspace file start directory and workspace-root fallback;
- Start All Restartable Panes zero-start preflight and honest per-pane external
  failure state;
- six panes per group and six live sessions across shell, Agent, role, and
  coordinator;
- 24 retained panes across open/parked groups and no-mutation rejection of the
  next New, Split, or Open;
- Agent/Ensemble unavailable saved placeholders;
- token and output-capture rollback;
- old workspace and `.terminal` migration;
- malformed Terminal Group field tolerance plus invalid-group removal with
  surviving tab order, nearest selection, split collapse, and valid focus;
- file tab, editor group, document Save, and window close compatibility; and
- shared-store concurrent writes and cross-window refresh, stale async load
  rejection, subscription cancellation, and two independent workspace
  sessions; and
- subscription-before-first-list coverage with no lost boundary mutation.

Prefer new uniquely named integration tests. Do not weaken a lane regression to
make the integrated suite pass.

### Q4. Persistence security inspection

Save a test layout that contains sentinel output, environment, token, command,
raw standardized workspace root, absolute child starting folder, Agent
provider/model, run ID, output-log data, and an OSC-reported terminal title in
its live controllers. Inspect the actual saved JSON and prove that none of
those sentinels or prohibited keys occur. Confirm that an approved absolute
shell profile can remain, the workspace map key is the expected digest, and
the raw standardized workspace root is absent.

Restore under instrumentation or spies and prove zero:

- terminal controller construction;
- SwiftTerm view construction;
- PTY/process start;
- Process Resources registration;
- Agent adapter probe/auth call;
- Ensemble token mint; and
- output-log file access.

Also verify corrupt and unsupported records fail locally without deleting file
tabs or the store file.

### Q5. Full GUI and accessibility matrix

In Rafu Lightning, complete:

- one, right, down, mixed, and nested group layouts;
- divider drag, window resize, tab switch, editor-group move, and relaunch;
- every shortcut with SwiftTerm first responder;
- mouse focus, tab rename, pane actions, manager actions, and saved-layout
  actions;
- hide/reveal with a live command;
- exited/restart behavior;
- attention and notification reply routing;
- group close with 0, 1, and several live processes;
- stale folder, missing shell, corrupt record, and capacity errors;
- selected-file start directory and workspace-root fallback;
- workspace switch, window close, app quit, and second-window isolation;
- direct Agent and fake Ensemble paths;
- VoiceOver and Full Keyboard Access;
- default and largest text;
- Indigo and Khadi;
- Increase Contrast, Reduce Transparency, and Reduce Motion; and
- 1x and 2x display scale when hardware is available.

Report a hardware-only deferral exactly. A simulated result does not close a
real 1x display or VoiceOver hardware gate.

### Q6. Optimized Rafu Lightning measurement

Measure an optimized **Rafu Lightning** bundle, never the release Rafu app and
never a raw SwiftPM GUI executable. If the canonical script cannot stage an
optimized Lightning bundle, add the smallest documented script mode that uses
SwiftPM release configuration while retaining the Lightning app name, bundle
ID, Application Support root, Keychain service, IPC socket, and CLI name.

Record OS, hardware, display scale, Swift toolchain, exact commit, method, and
three repetitions for:

- baseline workspace with no terminal group;
- 1 visible active pane;
- 4 visible active panes; and
- 6 visible active panes; and
- 24 retained inert panes, proving zero controller/view/process construction.

Record resident memory after a stable quiet point, incremental pane cost,
typing-path p50/p95, split/focus command latency, and behavior while all panes
produce bounded output. Use Instruments/signposts. Do not infer performance
from native implementation or the debug build.

The typing p95 target remains one display frame. If it fails, diagnose and fix
the cause or leave the plan blocked. Do not change the target in docs.

### Q7. Documentation close-out

Create `terminal-group-layout-and-restoration.md` with:

- scope and verified OS/toolchain;
- group/tree/focus ownership;
- AppKit split and first-responder boundary;
- save allow/deny list and schema;
- inert restoration order;
- separate per-group pane, retained-pane, and live-session capacity, zero-start
  Start All preflight, and the nontransactional external-start limit;
- lifecycle and cleanup funnels;
- Agent/Ensemble classification;
- failure modes and diagnostics;
- verification commands and measured results; and
- related code, ADR, and phase links.

Index every lane reference note. Change this plan and each completed
predecessor child plan from its lane status to Integrated and Verified. This
future-stable status is true on the integration branch and remains true after
the authorized merge. Change the parent phase from In Progress to Implemented
and the execution README from Active to Completed, with exact integrated
evidence. Update the active phase, old terminal phases, canonical plan, and
phase index to the exact implemented result. Return the active phase from In
Progress to Implemented only when items 7, 22, and 23 and all set-level gates
pass. Do not claim a deferred manual or performance gate as complete.

## Final verification order

Finish all source, tests, references, and plan updates before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing modifies a tracked file after the parallel suite. Then, without source
changes, run:

```bash
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

Run the optimized Lightning measurement and manual matrix after the tracked
tree is fixed. If a source or doc change follows, repeat the full format,
lint, build, parallel, serial, and launch sequence.

Run `git diff --check`, stage only TG-90 paths, and create one local commit.
Do not push or merge. Remove only this worktree's `.build` after the green
commit.

## Handoff

Report:

- every merged lane commit and ancestry result;
- every TG-90 production correction separately;
- final changed paths;
- focused, parallel, and serial test totals and duration;
- build warnings;
- Rafu Lightning and optimized Lightning evidence;
- full manual/accessibility matrix;
- persistence approved keys and prohibited-sentinel result;
- memory/typing measurements and trace location;
- concurrency, security, lifecycle, and cleanup review;
- all reference/phase/index changes;
- remaining risks or blocked gates;
- branch, commit message, and final SHA;
- next action: user-authorized local merge to primary `main` and post-merge
  gates; and
- **Deviations**, with `None` only when all contract items passed.

## Implementation record

To be completed by the TG-90 implementor before the final gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-90 from
docs/plans/phases/terminal-groups/TG-90-integration-qa.md: audit and prove the
complete Terminal Groups implementation, fix only integrated defects, complete
security/accessibility/optimized-Lightning measurements and documentation,
pass parallel and serial gates, and commit the final local integration result."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run
`git switch terminal-groups/tg-90-integration-qa` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-90-integration-qa, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<WAVE4_MERGED_SHA>`.
Confirm every TG-00 through TG-42 lane commit is present. Do not create or
replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-90-integration-qa.md;
docs/plans/phases/terminal-groups/TG-00-decision.md;
docs/plans/phases/terminal-groups/TG-10-source-contracts.md;
docs/plans/phases/terminal-groups/TG-20-runtime.md;
docs/plans/phases/terminal-groups/TG-21-renderer-focus.md;
docs/plans/phases/terminal-groups/TG-22-persistence.md;
docs/plans/phases/terminal-groups/TG-30-workspace-integration.md;
docs/plans/phases/terminal-groups/TG-40-manager-switcher.md;
docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md;
docs/plans/phases/terminal-groups/TG-42-agent-ensemble.md; every implementation
record in those files; docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0016-terminal-attention-notifications.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/0023-terminal-groups-and-saved-layouts.md;
docs/decisions/README.md;
docs/plans/rafu_product_architecture_plan.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/plans/phases/conductor/AT-01-agent-terminal-sessions.md;
docs/plans/phases/README.md;
docs/references/README.md; docs/references/skill-routing.md;
docs/references/build-and-run.md; all lane-created reference notes; and every
exact source, test, and reference path in TG-90. Read and use the exact SwiftUI,
concurrency, build-run-debug,
appkit-interop, swiftui-patterns, window-management, and conditional telemetry
skills listed in TG-90. Use test-triage only after a real failure.

First perform Q1 ancestry and ownership audit. Then implement Q2 through Q7.
Edit only TG-90-owned paths and only fix a production file for a proved
integration defect or unused compatibility adapter. Name every such correction
in the handoff. Do not edit an accepted ADR body to match code, add a
dependency, launch release Rafu, use a raw SwiftPM GUI executable, or widen
Agent/Ensemble saved capability.

Add missing integrated tests without weakening lane regressions. Inspect real
saved JSON with sentinels and prove zero process/capability action during
restore. Complete the full Rafu Lightning, two-window, keyboard, pointer,
lifecycle, accessibility, theme, and error matrix. Measure an optimized Rafu
Lightning bundle for baseline and 1/4/6 visible active panes with Instruments
or signposts. If canonical tooling lacks this mode, add only the narrow
documented Lightning-safe mode allowed by TG-90.

Prove the six-pane, 24-retained-pane, and six-live-session bounds, stale store
completion rejection, cross-window Delete detachment, modal shortcut
precedence, restoration selection fallback, and teardown cleanup order.

Use one SwiftPM invocation at a time. Do not poll. Isolate each failure. A red
required gate blocks completion.

Set this plan's Status to `Integrated and Verified` and complete all tracked
source, tests, references, phase/index updates, and the implementation record
before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may modify a tracked file after the full parallel suite. Then run the
serial suite and `./script/build_and_run.sh --verify` without tracked changes.
Complete optimized measurement and manual checks. If any tracked file changes,
repeat the complete sequence. Run `git diff --check`.

Stage only TG-90 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm clean status, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Provide the complete TG-90 handoff fields, including every lane SHA, every
production correction, parallel and serial totals, launch/manual/accessibility
evidence, approved saved keys, sentinel result, optimized memory/typing data,
docs, risks, branch, commit message, SHA, and next local merge action. Include
Deviations with `None` only when all items passed. Complete the Goal only after
the clean commit and full handoff.
```
