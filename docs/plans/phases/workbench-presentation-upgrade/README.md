# Workbench presentation upgrade — parallel worktree execution

## Status

Originally planned on 2026-07-29. WP-00 through WP-60 are implemented and
merged at integration commit
`f1a276720fcf68b940da4927522fcfbf5e23cde0`. A hands-on review of that build on
2026-07-30 produced eight bounded follow-ups in
[`workbench-presentation-follow-ups.md`](../../../issues/workbench-presentation-follow-ups.md).
WP-71 through WP-74 are the correction wave and all four can run concurrently
from one exact follow-up plan commit. WP-90 remains serial and now runs only
after those four corrections are merged.

This is the execution contract for
[`workbench-presentation-upgrade.md`](../workbench-presentation-upgrade.md).
It splits that design into one contract-first foundation, six implementation
plans that ran concurrently from the same foundation commit, four follow-up
plans that can run concurrently from the integrated result, and one final
integration/visual-QA plan.

This folder does not broaden the parent phase. In particular, it adds no
terminal layout commands, no new theme key, no process behavior, no Liquid
Glass, and no feature removal.

## Why the work is waved

The presentation system needs shared metrics, styles, and pure state resolvers.
If six agents invented those independently, every branch would edit the same
support files and the final merge would be a design reconciliation rather than
an integration. WP-00 therefore lands the shared contract first. Every visible
lane then consumes that contract without editing it.

```mermaid
flowchart LR
    A["Plan commit on<br/>codex/workbench-presentation-parallel-plans"]
    F["WP-00<br/>shared foundation"]
    S["WP-10<br/>shell deck"]
    E["WP-20<br/>editor tabs and groups"]
    T["WP-30<br/>terminal manager"]
    U["WP-40<br/>utility panels"]
    P["WP-50<br/>Settings"]
    N["WP-60<br/>Ensemble"]
    M["Merged original wave<br/>f1a2767"]
    A2["Follow-up plan commit<br/>one exact base SHA"]
    E1["WP-71<br/>editor interactions"]
    C1["WP-72<br/>chrome lifecycle"]
    R1["WP-73<br/>responsive navigation"]
    T1["WP-74<br/>terminal hierarchy/picker"]
    Q["WP-90<br/>integration and visual QA"]

    A --> F
    F --> S
    F --> E
    F --> T
    F --> U
    F --> P
    F --> N
    S --> M
    E --> M
    T --> M
    U --> M
    P --> M
    N --> M
    M --> A2
    A2 --> E1
    A2 --> C1
    A2 --> R1
    A2 --> T1
    E1 --> Q
    C1 --> Q
    R1 --> Q
    T1 --> Q
```

WP-10 through WP-60 have no source or test path overlap. They may execute at
the same time in separate worktrees. Their results merge serially so the
coordinator can attribute a regression to one commit.

## Plans, branches, and model fit

| Plan | Suggested branch | Wave | Recommended model | Primary ownership |
|---|---|---:|---|---|
| [WP-00 Foundation](WP-00-foundation.md) | `codex/presentation-foundation` | 0, serial | `gpt-5.6-sol` high | metrics, control/workbench styles, theme fixture and style contracts |
| [WP-10 Shell deck](WP-10-shell-deck.md) | `codex/presentation-shell-deck` | 1, parallel | `gpt-5.6-sol` high | window deck, Files-side composition, title-band verification |
| [WP-20 Editor tabs and groups](WP-20-editor-tabs-groups.md) | `codex/presentation-editor-tabs` | 1, parallel | `gpt-5.6-sol` high | editor tab caps, split-group framing, live terminal tile perimeter |
| [WP-30 Terminal manager](WP-30-terminal-manager.md) | `codex/presentation-terminal-manager` | 1, parallel | `gpt-5.6-sol` high | terminal panel density, current-session state, row border consumption |
| [WP-40 Utility panels](WP-40-utility-panels.md) | `codex/presentation-utility-panels` | 1, parallel | `gpt-5.6-sol` high | rails, Search, Source Control, branch popover, Runs panel, status bar |
| [WP-50 Settings](WP-50-settings.md) | `codex/presentation-settings` | 1, parallel | `gpt-5.6-terra` xhigh | adaptive settings navigation and section hierarchy |
| [WP-60 Ensemble](WP-60-ensemble.md) | `codex/presentation-ensemble` | 1, parallel | `gpt-5.6-terra` xhigh | goal-first composer, one CLI/model representation, run canvases |
| [WP-71 Editor interactions](WP-71-editor-interactions.md) | `codex/presentation-editor-interactions` | follow-up 1, parallel | `gpt-5.6-sol` high | inactive tab visibility and Find first-responder routing |
| [WP-72 Window chrome lifecycle](WP-72-window-chrome-lifecycle.md) | `codex/presentation-window-chrome-lifecycle` | follow-up 1, parallel | `gpt-5.6-sol` high | titlebar/safe-area invariant across split and close topology changes |
| [WP-73 Responsive navigation](WP-73-responsive-navigation.md) | `codex/presentation-responsive-navigation` | follow-up 1, parallel | `gpt-5.6-terra` xhigh | full-width Source Control modes and compact Settings hierarchy |
| [WP-74 Terminal hierarchy and picker](WP-74-terminal-hierarchy-picker.md) | `codex/presentation-terminal-hierarchy-picker` | follow-up 1, parallel | `gpt-5.6-sol` high | terminal perimeter hierarchy and Terminal Manager shell picker |
| [WP-90 Integration and QA](WP-90-integration-qa.md) | `codex/presentation-integration-qa` | follow-up 2, serial | `gpt-5.6-sol` high | integrated tests, visual/accessibility matrix, references and indexes |

The model entries are recommendations, not source-of-truth decisions. Use
`gpt-5.6-sol` high where correctness crosses window, responder, editor,
terminal, Git, or integration boundaries. Use `gpt-5.6-terra` xhigh for the
bounded, fully specified SwiftUI hierarchy lanes.

## Branch and worktree procedure

The plan set is committed on
`codex/workbench-presentation-parallel-plans`. Do not create the six Wave 1
worktrees from that plan commit directly.

### 1. Run and merge WP-00

Record the exact plan commit as `<PLAN_SHA>`:

```bash
git rev-parse codex/workbench-presentation-parallel-plans
```

From a checkout that is not already using the foundation branch:

```bash
git worktree add ../rafu-presentation-foundation \
  -b codex/presentation-foundation \
  <PLAN_SHA>
```

Execute WP-00, review its commit, then merge it into
`codex/workbench-presentation-parallel-plans`. The merge commit is the
**foundation commit**. Record its exact SHA; do not substitute a moving branch
name when creating Wave 1.

### 2. Create all six Wave 1 worktrees from the exact foundation SHA

Replace `<FOUNDATION_SHA>` with the recorded commit:

Before creating them, run `df -h .` and leave enough capacity for six
independent SwiftPM caches. Budget up to 5 GB per active worktree plus headroom
for staged app bundles and logs. If the machine cannot safely hold that, keep
implementation work parallel but serialize final build/test gates and remove
each green lane's `.build` immediately after its local commit before starting
the next lane's gate.

Also inventory available display `backingScaleFactor` values before fan-out.
If no true 1× display is available, schedule the external-display/user evidence
required by WP-90; a simulated or unit-test-only result cannot close that
manual gate.

```bash
git worktree add ../rafu-presentation-shell \
  -b codex/presentation-shell-deck <FOUNDATION_SHA>
git worktree add ../rafu-presentation-editor \
  -b codex/presentation-editor-tabs <FOUNDATION_SHA>
git worktree add ../rafu-presentation-terminals \
  -b codex/presentation-terminal-manager <FOUNDATION_SHA>
git worktree add ../rafu-presentation-utilities \
  -b codex/presentation-utility-panels <FOUNDATION_SHA>
git worktree add ../rafu-presentation-settings \
  -b codex/presentation-settings <FOUNDATION_SHA>
git worktree add ../rafu-presentation-ensemble \
  -b codex/presentation-ensemble <FOUNDATION_SHA>
```

Paste the Goal-mode prompt from the matching plan into each worktree agent.
Every prompt explicitly authorizes a local commit on that lane branch. No
prompt authorizes push, merge, PR creation, release work, or edits to `main`.
Before dispatch, replace every base-SHA placeholder in that prompt with the
recorded exact SHA. The embedded prompt grants its commit or ADR authority only
when the user actually dispatches it.

### 3. Merge Wave 1 in attribution-friendly rounds

All six agents may run concurrently. Merge one branch at a time into
`codex/workbench-presentation-parallel-plans`:

1. WP-10 Shell, then WP-20 Editor.
2. WP-30 Terminal Manager, then WP-40 Utility Panels.
3. WP-50 Settings, then WP-60 Ensemble.

WP-30 precedes WP-40 so the terminal panel already owns its complete primary
header when WP-40 removes the old outer utility header. This is a semantic
ordering only; the branches do not edit the same file.

After each merge, verify the owned-path diff and run lint, build, and the
parallel tests. After each pair, run the staged Rafu Lightning verification and
the pair's focused manual checks. Run only one SwiftPM command and one staged
app verification at a time.

### 4. Create all four follow-up worktrees from one exact plan commit

The correction plans and issue ledger are committed on
`codex/workbench-presentation-followup-plans`. Record that immutable commit as
`<FOLLOWUP_BASE_SHA>`:

```bash
git rev-parse codex/workbench-presentation-followup-plans
```

Confirm it descends from
`f1a276720fcf68b940da4927522fcfbf5e23cde0`, then create all four worktrees
from that exact SHA:

```bash
git worktree add ../rafu-presentation-editor-followup \
  -b codex/presentation-editor-interactions <FOLLOWUP_BASE_SHA>
git worktree add ../rafu-presentation-chrome-followup \
  -b codex/presentation-window-chrome-lifecycle <FOLLOWUP_BASE_SHA>
git worktree add ../rafu-presentation-navigation-followup \
  -b codex/presentation-responsive-navigation <FOLLOWUP_BASE_SHA>
git worktree add ../rafu-presentation-terminal-followup \
  -b codex/presentation-terminal-hierarchy-picker <FOLLOWUP_BASE_SHA>
```

Before fan-out, check disk capacity for four SwiftPM caches and confirm the
shared staged-app GUI lease is free. Paste the complete Goal Mode prompt from
each matching plan. Replace `<FOLLOWUP_BASE_SHA>` in every prompt with the same
recorded SHA.

### 5. Merge the follow-up wave serially

The four agents run concurrently, but the coordinator merges one local commit
at a time:

1. WP-71 Editor interactions.
2. WP-72 Window chrome lifecycle.
3. WP-73 Responsive navigation.
4. WP-74 Terminal hierarchy and picker.

The order is attribution-friendly rather than conflict-driven. These lanes
have no intended production, test, or new-file overlap.

Before each merge, compare the lane to `<FOLLOWUP_BASE_SHA>`, verify every
changed path against the table below, read deferred checks, and reject shared
or foreign paths. After each merge run lint, build, and the parallel suite.
After the pair WP-71/WP-72 and again after WP-73/WP-74, run staged Rafu
Lightning and the combined manual checks. After all four, run both parallel and
serial suites uncontended and record the result as `<POST_FOLLOWUP_SHA>`.

### 6. Run WP-90 from the merged follow-up SHA

Create the final worktree only after all four commits are ancestors of the
integration state:

```bash
git worktree add ../rafu-presentation-integration \
  -b codex/presentation-integration-qa <POST_FOLLOWUP_SHA>
```

WP-90 owns cross-surface corrections, the complete screenshot/accessibility
matrix, explicit verification of WBP-001 through WBP-008, both test modes, and
documentation close-out. Merge it only after its full gate is green.

All coordinator merges described here are local. Do not push, open a PR,
publish, or release without separate user authorization.

## Zero-conflict ownership rule

### WP-00 shared contract and test handoff

Only WP-00 may edit:

- `Sources/RafuApp/Support/RafuMetrics.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`
- `Tests/RafuAppTests/RafuThemeTests.swift`
- `Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json`
- its dedicated new style-contract tests
- the one-time test-ownership split across
  `TerminalsPanelTests.swift`, `EditorThemeColorApplicationTests.swift`,
  `Conductor/EnsembleStartCanvasTests.swift`, and a new
  `Conductor/ConductorRunsPanelPresentationTests.swift`
- ADR 0022's acceptance status and decision-index status

After the foundation merge, Wave 1 consumes the shared production/style,
fixture, style-contract-test, and ADR files byte-for-byte. The four
test-ownership-split files are deliberate post-foundation handoffs:

- `EditorThemeColorApplicationTests.swift` → WP-20;
- `TerminalsPanelTests.swift` → WP-30;
- `ConductorRunsPanelPresentationTests.swift` → WP-40; and
- `EnsembleStartCanvasTests.swift` → WP-60.

A lane that needs a frozen shared primitive change records it as a WP-90
dependency instead of editing the file.

### Wave 1 exclusive source ownership

| Plan | Exclusively owned source paths |
|---|---|
| WP-10 | `WorkspaceWindowView.swift`, `WorkspaceSidebarView.swift`, `FlatWindowChrome.swift` |
| WP-20 | `EditorCanvasView.swift` |
| WP-30 | `EditorTerminalTabContent.swift`, `TerminalSessionColor.swift`, `WorkspaceTerminalsPanelView.swift`, `WorkspaceSession.swift` |
| WP-40 | `WorkspaceNavigatorView.swift`, `GitInspectorView.swift`, `ConductorRunsPanelView.swift`, `RafuSearchableDropdown.swift`, `WorkspaceStatusBar.swift` |
| WP-50 | `SettingsCanvas.swift`, `SettingsPaneStrip.swift` → `SettingsPaneNavigation.swift`, `RafuSettingsView.swift`, and the seven explicitly named settings section/tab files (including `AIProviderSettingsSection.swift`) |
| WP-60 | `EnsembleStartCanvas.swift`, `EnsembleCLIIconGrid.swift` → `EnsembleCLISelectionList.swift`, `EnsembleModelField.swift`, `EnsembleGoalPane.swift`, `ConductorGraphCanvas.swift`, `ConductorRunDetailCanvas.swift` |

Each plan contains the absolute repository-relative paths and its exclusive test
files. No two Wave 1 plans own the same path.

### Follow-up Wave 1 exclusive ownership

| Plan | Issues | Exclusively owned production paths | Exclusively owned existing test paths |
|---|---|---|---|
| WP-71 | WBP-001, WBP-008 | `EditorCanvasView.swift`, `DocumentFind.swift`, `CodeEditorView.swift`, `RafuTextView.swift`, and the document-Find methods only in `WorkspaceSession.swift` | `EditorFindTests.swift` |
| WP-72 | WBP-004, WBP-007 | `FlatWindowChrome.swift`, `WorkspaceWindowView.swift` | `FlatWindowChromeTests.swift` |
| WP-73 | WBP-002, WBP-003 | `GitInspectorView.swift`, `RafuSettingsView.swift`, `SettingsPaneNavigation.swift` | `UtilityPanelPresentationTests.swift`, `SettingsPresentationTests.swift` |
| WP-74 | WBP-005, WBP-006 | the terminal-border resolver/rendering only in `RafuWorkbenchStyles.swift`, `WorkspaceTerminalsPanelView.swift`, new `TerminalShellPickerView.swift` | terminal-border contracts only in `RafuWorkbenchStyleContractTests.swift`, `matchingIdentityKeepsNeutralAndFocusedSignals` only in `EditorTabAndGroupPresentationTests.swift`, `TerminalManagerPresentationTests.swift` |

The new test files are also exclusive:

- WP-71:
  `EditorTabVisibilityPresentationTests.swift` and
  `EditorFindFocusRoutingTests.swift`;
- WP-72: `WindowChromeTopologyLifecycleTests.swift`;
- WP-73: `ResponsiveNavigationPresentationTests.swift`; and
- WP-74: `TerminalShellPickerPresentationTests.swift`.

The narrowly qualified shared-file ownership in WP-71 and WP-74 does not
overlap: WP-71 may edit only document-Find routing in `WorkspaceSession.swift`;
WP-74 cannot edit that file. WP-74 may edit only the terminal-border portion of
`RafuWorkbenchStyles.swift` and one named terminal-border test in
`EditorTabAndGroupPresentationTests.swift`; WP-71 consumes that existing test
file read-only and places new tab-visibility coverage in its dedicated file.
Every other follow-up lane treats both qualified files as frozen.

A textual conflict among WP-71 through WP-74 means a lane exceeded ownership
or started from the wrong SHA. Do not resolve it by choosing one side.

Follow-up lanes also freeze:

- `Package.swift`, `Package.resolved`, `AGENTS.md`, and `CLAUDE.md`;
- all theme JSON and `RafuTheme.swift`;
- `RafuMetrics.swift` and `RafuControlStyles.swift`;
- shared plan/reference/decision indexes;
- the parent phase document;
- another follow-up lane's plan, source, tests, or proposed new file.

Each lane may update only its own plan implementation record and may add one
uniquely named factual reference note when the standing documentation rule
requires it. WP-90 owns shared status/index close-out.

### Integration-owned paths

Wave 1 agents must not edit:

- `Package.swift` or `Package.resolved`
- `AGENTS.md` or `CLAUDE.md`
- `Sources/RafuApp/App/**`
- `Sources/RafuApp/Views/WorkspaceSceneRoot.swift`
- `Sources/RafuApp/Support/RafuTheme.swift`
- any shared style file owned by WP-00
- `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`
- `docs/decisions/README.md` after WP-00
- `docs/references/README.md`
- `docs/plans/phases/README.md`
- the parent `workbench-presentation-upgrade.md`
- another lane's plan, source, test, or fixture

WP-90 owns those indexes, the parent plan status, the explicitly named verified
reference/test-plan notes, and the integrated style scan. It may adjust an
implementation file only to fix an integration defect that cannot be corrected
in its original lane without reopening the fan-out; such an edit must be called
out separately in the handoff.

### Documentation discovered during a lane

A lane may:

- update only its own `WP-*.md` implementation record; and
- add a uniquely named reference note when implementation reveals a reusable
  platform/toolchain nuance.

It must not edit a shared index. It reports the intended index row to WP-90.
Ordinary implementation details already covered by the plan do not justify a
new note.

## Common lane gate

Every implementation lane completes its source and documentation before this
final sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing modifies a file after `./script/test.sh`. If anything does, repeat the
affected sequence. The lane stages only owned paths and creates one intentional
local commit.

All implementation worktrees share one machine and one staged app identity:

- never start a second SwiftPM command in the same worktree while its
  `.build/.lock` is held;
- do not run multiple `build_and_run.sh` invocations concurrently;
- never launch, stop, `pkill`, or `pgrep` a bare `Rafu`; only Rafu Lightning is
  in scope;
- a lane may defer its staged-app/manual check to its coordinator merge round,
  but must list the exact deferred states in its handoff;
- after green gates and the lane commit, remove that worktree's `.build` cache
  as required by `AGENTS.md`.

The integration owner runs `./script/test.sh --no-parallel` in WP-90 and both
test modes after the final merge.

## Merge audit

Before every merge:

1. Compare an original Wave 1 lane against `<FOUNDATION_SHA>` or a follow-up
   lane against `<FOLLOWUP_BASE_SHA>`, and verify every changed path is owned by
   that lane.
2. Reject unplanned shared-file changes; do not resolve them silently.
3. Read the lane handoff and its deferred manual checks.
4. Merge without squashing unless the user chooses otherwise.
5. Run the merge-round gates before accepting the next pair.

A textual merge conflict in Wave 1 is evidence that an ownership rule was
broken or that the wrong base commit was used. Stop and investigate rather than
choosing one side by intuition.

## Set-level exit

The set is complete only when:

1. ADR 0022 is Accepted and its narrowed supersession of ADR 0012 is indexed.
2. WP-00, all six original Wave 1 branches, and all four follow-up branches are
   merged from their correct immutable bases.
3. WBP-001 through WBP-008 have passing automated regressions and completed
   manual evidence.
4. `git diff` confirms no hard-coded presentation color or new theme key.
5. The exact parent-plan automated and manual matrices are complete, including
   Indigo, Khadi, GitHub Light, the converged-surface fixture, 1×/2×, two
   windows, larger text, VoiceOver, Full Keyboard Access, Increase Contrast,
   Reduce Transparency, and Reduce Motion.
6. Format, build, parallel tests, serial tests, and staged Rafu Lightning launch
   are green on the integrated tree.
7. `ui-design-language.md`, `settings-surface.md`, the parent phase, active
   workbench phase, and shared indexes describe the implemented state.
8. Every worktree handoff names its commit, paths, evidence, deferred work, and
   any reusable nuance.
