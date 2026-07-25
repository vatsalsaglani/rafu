# C8-04 — Plan gate, propose-merge, merged state, proposals

- **Status:** Ready. Branch: `conductor/c8-04-plan-gate` (from `main`
  AFTER wave 2 fully merged — verify `ConductorEnsembleTokenStore` and
  `ConductorGraphModel` both exist; either missing ⇒ STOP and report).
  Wave 3 — runs parallel with C8-07. (C8-05 moved to wave 2, so the
  skill pack and Settings are already on `main` when you branch.)

## Goal

Close the coordinator loop. `rafu ensemble run --plan-gate` parks a fully
validated run at a human **plan gate** (files as tabs, parsed-step
preview) before anything spawns; `rafu ensemble propose-merge` surfaces a
child's diff at the human merge gate and **never merges**; applying a
merge stamps `mergedAt` and streams a `merged` event so
`await --state merged` completes; worker artifacts may carry a
`proposes:` block that surfaces as ghost nodes on the graph.

## Read first

`AGENTS.md`; conductor `README.md`; `C8-execution-plan.md`;
`C8-coordinator-ux.md` ("The plan gate", "Two-way, within limits");
`C8-cli-and-skill-spec.md` (`propose-merge`, the loop sequence);
ADR 0018 Amendment; `docs/references/ensemble-ipc-verbs.md`;
`docs/references/conductor-pipeline-engine.md` (gate FSM, `approveGate`
reentrancy guards); `Sources/RafuApp/Conductor/Run/
ConductorWorkflowController.swift` (states, `stepDidComplete`,
`advance(after:)`, `applyToWorkspace`).

## Owned paths

- `Sources/RafuApp/Conductor/ConductorCore.swift` — additive ONLY:
  `Gate.Kind.plan` case; `Step.proposals: [String]? = nil`
- `Sources/RafuApp/Conductor/Run/ConductorWorkflowController.swift` —
  plan-gate state + verbs; `mergedAt` stamp; proposals parse
- `Sources/RafuApp/Conductor/Run/ConductorRunController.swift` —
  `mergedAt` stamp in its `applyToWorkspace()` only
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleRequestService.swift`
  — `--plan-gate` on `run`; new `propose-merge` handler
- `Sources/RafuCore/Ensemble/` — parser/runner/models for `--plan-gate`
  and `propose-merge`; `LauncherIPCProtocol.swift` kind
  `.ensembleProposeMerge` (+ `logName` row in `LauncherIPCServer.swift`)
- `Sources/RafuApp/Views/ConductorRunDetailCanvas.swift` — plan-gate
  section (verbs + file list)
- `Sources/RafuApp/Conductor/Run/ConductorGraphModel.swift` — ghost
  nodes from `Step.proposals`; plan-gate node kind (additive to C8-06's
  `default`-tolerant switch)
- Tests: extend `WorkflowGateTests` patterns in NEW
  `Tests/RafuAppTests/Conductor/PlanGateTests.swift`,
  `ProposeMergeTests.swift`; parser tests
- Docs: append to `ensemble-ipc-verbs.md`; extend
  `conductor-pipeline-engine.md` (plan-gate FSM);
  `ensemble-manual-test-plan.md` NEW section **L**; this plan's status
  line.

**Forbidden:** `RafuAppCommands.swift`, `CommandPaletteView.swift`,
`WorkspaceWindowView.swift` (C8-07 owns them this wave); `Package.swift`;
Settings and `Sources/RafuApp/Resources/EnsembleSkills/` (C8-05,
already merged — read-only to you); `ConductorRunsPanelView.swift`
(C8-07 may touch it);
adapters; `EditorCanvasView.swift`.

## Design contract

### Plan gate

- `ConductorWorkflowRunRequest`: add `var planGateRequested: Bool = false`.
  `ConductorWorkflowState`: add `.awaitingPlanGate`.
- In `start(_:launcher:)`: after existing validation and manifest-v0
  construction, when `planGateRequested` — write the manifest with
  `gate = Gate(kind: .plan, stepIndex: 0)`, all steps `.pending`,
  publish, set `.awaitingPlanGate`, fire `onGateReady` with a
  `ConductorGateReadyEvent` (`kind: .step` stays; add `.plan` to its
  `Kind` — additive enum + notifier tolerance: plan gates are NEVER
  remotely approvable, mirror the merge-gate rule), and RETURN before
  materializing worktrees or launching anything. **Nothing spawns behind
  a plan gate.**
- Verbs on the controller:
  - `approvePlanGate()` — guarded like `approveGate()` (state +
    generation reentrancy); **re-loads and re-parses** the workflow +
    agent files via `ConductorDefinitionLibrary` at approval time (D2:
    files are truth; the user may have hand-edited at the gate). Parse
    failure ⇒ stay parked, surface the issue string on the controller
    (`planGateIssue: String?`), never a silent fallback to the stale
    parse. Success ⇒ rebuild steps, clear gate, proceed into the normal
    materialize-and-launch path.
  - `declinePlanGate(note: String)` — run → `.aborted`,
    `recoveryNote = note` (bounded 1000 chars), publish; the event
    center already emits on publish, so the awaiting coordinator sees
    `aborted` and reads the note via `status`. This is "Revise" from the
    coordinator's side: it rewrites files and submits a NEW
    `run --plan-gate`.
- `EnsembleRunState.awaitingPlanGate` already exists on the wire (C8-02
  reserved it); map `.awaitingPlanGate` into the derived-state function.

### Plan-gate UI (run detail canvas)

When `manifest.gate?.kind == .plan`: a "Plan Gate" section above the step
timeline — the parsed step list (agent, provider, gate markers), a file
list (workflow file + each agent file) where each row opens the file as
an ordinary editor tab (`session.openFile(atRelativePath:)`), verbs
**Approve Plan** (prominent), **Request Changes…** (note field →
`declinePlanGate`), and a parse-issue banner when `planGateIssue` is
set. The existing "Approve Gate" menu path must also work: extend
`approveGate()` to forward to `approvePlanGate()` when the state is
`.awaitingPlanGate` (single user-facing verb, zero menu edits — C8-07
owns the commands file this wave). Graph: plan-gate node uses the gate
glyph with label "Plan gate".

### propose-merge

- CLI: `rafu ensemble propose-merge <run>... [--message <text>] [--json]`
  → kind `.ensembleProposeMerge`, **token required** (the caller must be
  the coordinator that started the runs; foreign run ⇒ 77; run not at
  `awaitingMergeGate` ⇒ 65 with the actual state named).
- Server handler: for each run, verify `startedBy` matches the token's
  coordinator AND live state is `.awaitingMergeGate`; then re-raise gate
  attention (`WorkspaceSession.raiseConductorGateAttention` via a new
  small internal hook or by re-firing the gate event through the center
  + notifier path — reuse, do not duplicate policy), attach the message
  as a note (`ConductorEnsembleNoteStore`, attributed to the
  coordinator), respond `.proposeMerge(accepted: [runID], state:
  "awaiting_human")`. **The verb never applies anything** — applying
  stays the user's `applyToWorkspace()` in the existing UI.
- `applyToWorkspace()` (both controllers): on success, set
  `manifest.mergedAt = Date()`, publish (event flows; derived state
  becomes `merged`), THEN the existing cleanup. `await --state merged`
  then completes push-based. Rejection path: the user discarding the
  worktree already yields `aborted` — coordinator distinguishes via
  state + notes.

### `proposes:` in artifacts

In `stepDidComplete(_:)`, after artifact existence is confirmed: read the
artifact file (bounded 1 MiB — reuse the catalog cap constant), scan
frontmatter with `ConductorFrontmatter` for a list-valued `proposes:`
key; store the trimmed non-empty lines (cap 16 entries, each ≤ 200
chars) into `steps[index].proposals`; publish. No frontmatter, scalar
`proposes`, or over-cap ⇒ `nil` / truncate silently-but-logged-in-
manifest? No: truncate and append a final entry "… (truncated)". Never
throw — a malformed artifact still completes the step (proposals are
advisory). Graph model: each proposal renders a ghost node (kind
addition `proposedGhost`, dashed-border card, `⋯`-style glyph
`ellipsis.circle`, label "Proposed", no verbs in v1 — admission is the
coordinator's `run` decision; dismissed-vs-admitted bookkeeping is a
recorded follow-up).

## Tests

- `PlanGateTests`: `--plan-gate` parks before any launch (launcher spy
  asserts zero launches); approve re-parses (hand-edit the workflow file
  between park and approve — new content wins); parse failure at approve
  keeps the park + sets `planGateIssue`; decline sets aborted + bounded
  note; remote-approve refused for plan gates (notifier category test
  pattern from `GateNotificationActionTests`); manifest round-trip for
  `Gate.Kind.plan` + pre-C8 decode unaffected.
- `ProposeMergeTests`: token/ownership/state matrix (77/65); accepted
  path posts note + responds awaiting_human; `applyToWorkspace` stamps
  `mergedAt` + emits event + derived state `merged` (both controllers);
  await-driven completion via the event center (subscribe, apply,
  receive `merged`).
- Proposals: frontmatter list parsed, caps enforced, malformed artifact
  never fails the step; graph ghost nodes appear (extend
  `GraphModelTests`).
- Parser: new verb + flags; `--plan-gate` on run.

## Gates

Standard: `swift build` 0 warnings; `swift test` + `--no-parallel`;
format `--fix`/`--lint`; HEADLESS ONLY; no logging of note/artifact
content anywhere (`rg` checks per C8-02/03).

## Documentation deliverables

Append `propose-merge` + `--plan-gate` + `merged`/`awaitingPlanGate`
states + `proposes:` schema to `docs/references/ensemble-ipc-verbs.md`;
extend `docs/references/conductor-pipeline-engine.md` with the plan-gate
FSM and the approve-time re-parse rule; `ensemble-manual-test-plan.md`
section **L — Plan gate and merge loop** (L1 park-before-spawn, L2 edit
file at gate then approve, L3 decline with note, L4 propose-merge
notification, L5 apply → coordinator's await returns, L6 ghost nodes).
Intended index rows in the report.

## Handoff report

Delivered behavior; changed paths; test evidence; FSM diff (old→new
states/verbs); remaining risks (name the dismissed-proposal bookkeeping
follow-up); docs; branch; commit messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-04-plan-gate. Preflight: run `git status --short
--branch` ONCE. On this branch + clean tree → proceed. Detached HEAD or
wrong branch + clean tree → checkout the branch if it exists, else
`git checkout -b conductor/c8-04-plan-gate main`, then proceed and say
so. Dirty tree with edits you did not make → STOP. Then verify
prerequisites: ConductorEnsembleTokenStore (Sources/RafuApp/Conductor/
Ensemble/) and ConductorGraphModel (Sources/RafuApp/Conductor/Run/) both
exist. Either missing ⇒ STOP and report — wave 2 has not merged.

GOAL: implement docs/plans/phases/conductor/C8-04-plan-gate-and-propose-merge.md
— the plan-gate flow (`run --plan-gate` parks a validated run before
ANYTHING spawns; Approve re-parses the files at approval time; Request
Changes aborts with a bounded note), the propose-merge verb (token-
scoped, never merges, re-raises the human gate), the mergedAt stamp +
streamed `merged` state that completes `await --state merged`, and the
`proposes:` artifact block rendered as ghost nodes. The plan file is
your authoritative design contract, edit list, and test list — read it
FIRST, then AGENTS.md, the conductor README ground rules, ADR 0018 with
its Amendment, C8-coordinator-ux.md's plan-gate section,
docs/references/conductor-pipeline-engine.md, and
docs/references/ensemble-ipc-verbs.md.

HARD CONSTRAINTS: nothing spawns behind a plan gate (a launcher-spy test
must prove zero launches while parked); propose-merge never applies,
commits, or merges anything — applying remains the user's existing
verb; plan gates are never remotely approvable; approve-time re-parse
means hand-edited files win and a parse failure keeps the park (never a
stale-parse fallback); ConductorCore.swift edits are additive
var-optional-nil only; malformed artifacts never fail a completed step.
DO NOT touch RafuAppCommands.swift, CommandPaletteView.swift,
WorkspaceWindowView.swift, ConductorRunsPanelView.swift, Package.swift,
or Settings — C8-07 owns the first three this wave and C8-05 already
landed the rest. HEADLESS ONLY.

DEFINITION OF DONE:
1. The full loop is provable headlessly with FakeConductorAdapter:
   run --plan-gate → park → hand-edit → approve → steps run → merge
   gate → propose-merge → user applyToWorkspace → mergedAt → awaiting
   coordinator receives `merged` through the event stream.
2. Decline-with-note round-trips to the coordinator via status/events.
3. Ownership/state matrices for propose-merge (77/65) covered by tests.
4. Ghost nodes render from Step.proposals with caps enforced.
5. swift build 0 warnings; swift test AND swift test --no-parallel
   green; format --fix + --lint clean.
6. ensemble-ipc-verbs.md + conductor-pipeline-engine.md updated;
   manual-test-plan section L added; intended index rows in the report.
7. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. Shared-file needs are a HANDOFF with a proposed diff.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence; the FSM state/verb diff; remaining risks incl. the
dismissed-proposal follow-up; docs written; branch name; every commit
message; last commit id from `git rev-parse HEAD`.
```
