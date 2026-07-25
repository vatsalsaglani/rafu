# C8-06 — The interactive graph canvas, agent icons, activity feed

- **Status:** Ready. Branch: `conductor/c8-06-graph-canvas` (from `main`
  AFTER C8-02 has merged — verify `ConductorRunManifest.startedBy` exists;
  missing ⇒ STOP and report). Wave 2 — runs parallel with C8-03.
- **This is the cockpit.** It must feel immediate, legible, and native —
  the C8-ux doc calls comprehension the make-or-break surface.

## Goal

Ship the graph canvas as a new editor-canvas mode: a live DAG of every
Ensemble run in the workspace, grouped into coordinator trees via
`startedBy`, projected from manifests + live controller state (D3: a
projection, never an authoring tool). Interactive: **click a node →
focus its terminal session or open its evidence; gate nodes carry the
gate verbs.** Every node shows the agent's icon with a small provider
badge (Claude Code, Codex, OpenCode, Cline, Kimi, Gemini, Cursor). Plus
an Activity feed segment in the Runs panel fed by the C8-02 event
center, and `startedBy` attribution on run rows.

## Read first

`AGENTS.md` (macOS interface rules — top-pinned panels, no color-only
state, no icon-only actions, Reduce Motion); conductor `README.md`;
`C8-execution-plan.md` (decisions 5, 8); `C8-coordinator-ux.md`
("Canvas anatomy", node vocabulary table, "Where conversation lives");
`Sources/RafuApp/Git/CommitGraphLayout.swift` +
`Views/GitCommitGraphView.swift` (the layout+Canvas pattern to copy);
`Sources/RafuApp/Conductor/Run/ConductorRunPresentation.swift` (glyph
discipline: views switch on semantic status, never on symbol strings);
`Sources/RafuApp/Views/EditorCanvasView.swift` (the routing chain);
`Sources/RafuApp/Support/FileIconProvider.swift` (SVG asset loader);
`swiftui-expert-skill` and Build macOS Apps `swiftui-patterns`.

## Owned paths

- NEW `Sources/RafuApp/Conductor/Run/ConductorGraphModel.swift`
- NEW `Sources/RafuApp/Conductor/ConductorCLIIcons.swift`
- NEW `Sources/RafuApp/Views/ConductorGraphCanvas.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift` (one additive branch +
  emptiness guard)
- `Sources/RafuApp/Models/WorkspaceSession.swift` (graph-canvas seam ONLY,
  anchored — see below)
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift` (Graph button,
  Activity segment, attribution chip)
- `Sources/RafuApp/App/RafuAppCommands.swift` + `Views/CommandPaletteView.swift`
  ("Show Ensemble Graph" entries)
- `Sources/RafuApp/Conductor/Run/ConductorRunPresentation.swift` (graph
  node helpers, additive)
- NEW `Resources/FileIcons/{opencode,cline,kimi,cursor}.svg`
- `script/build_and_run.sh` (staging asserts for the four SVGs)
- NEW tests `Tests/RafuAppTests/Conductor/GraphModelTests.swift`,
  `GraphCanvasRoutingTests.swift`; extend `FileIconAssetsTests.swift`
- `docs/plans/phases/conductor/ensemble-manual-test-plan.md` (NEW section
  K); NEW `docs/references/ensemble-graph-canvas.md`; this plan's status
  line.

**Forbidden:** `Package.swift`, `ConductorCore.swift`, engine files
(`ConductorWorkflowController`, `ConductorRunController`), everything in
`Sources/RafuApp/Conductor/Ensemble/` (C8-03 owns it this wave),
`ConductorRunDetailCanvas.swift` (C8-03 adds its Notes section), Settings.

## Design contract

### Layout model (`ConductorGraphModel.swift`, `nonisolated`, pure, testable)

```swift
nonisolated struct ConductorGraphNode: Identifiable, Equatable, Sendable {
    enum Kind: Equatable { case coordinator, run, step, gate }
    let id: String            // stable: "co-x", "run-x", "run-x/step-2", "run-x/gate"
    let kind: Kind
    let title: String         // "Implement A", "advisor", "Merge gate"
    let runID: String?
    let stepIndex: Int?
    let provider: ConductorCLIID?
    let status: RunStepStatus?          // steps
    let runState: EnsembleGraphState    // see below — semantic, not string
    let detail: String                  // "Codex • 12m", "waiting on step 2"
    let column: Int, row: Int           // layered layout position
}
nonisolated struct ConductorGraphEdge: Equatable, Sendable { let from: String; let to: String }
nonisolated enum ConductorGraphModel {
    static func build(manifests: [ConductorRunManifest],
                      liveStates: [String: ConductorWorkflowState],
                      coordinators: [CoordinatorNodeInput]) -> ConductorGraph
}
```

Layered left→right: column 0 coordinator roots (one synthesized root per
distinct `startedBy` even when the live session ended — title
"Coordinator (ended)"; runs with `startedBy == nil` are their own roots);
column n+1 children. Within a run, steps chain in order; a step with
`inputArtifacts` naming an earlier step's artifact gets an edge from
that step. A gate node (kind `.gate`) is appended when the manifest's
`gate` is set. Rows assigned to avoid overlap (simple per-column
counter; determinism is a test). Ghost/proposed nodes arrive with C8-04
(`Step.proposals`) — build the `Kind` switch and rendering with a
`default` so unknown future inputs degrade to a plain node, and note the
extension point in a comment.

`EnsembleGraphState`: reuse `ConductorRunPresentation.overallStatus`
precedence — do NOT reimplement it; add a
`ConductorRunPresentation.graphNode(for:live:)` helper (additive) that
returns glyph symbol + label + needsAttention, keeping the
symbol/label/color discipline in one file.

### Node vocabulary (obeys the C8-ux table; glyph AND text, never color alone)

| State | Symbol (existing family) | Primary verb on the node |
|---|---|---|
| pending | `circle.dotted` | — |
| running | `circle.fill` | Open Terminal |
| blocked/waiting | `pause.circle.fill` | Show dependency (detail text) |
| awaiting gate | `bolt.horizontal.circle.fill` | Approve · Revise · Abort |
| completed | `checkmark.circle.fill` | Open Artifact |
| interrupted | `exclamationmark.triangle.fill` | Retry · Abort · Keep Worktree |
| failed | `xmark.circle.fill` | Open Evidence · Retry |
| merge gate | `bolt.horizontal.circle.fill` | Open Diff · Apply · Discard |

### Canvas view (`ConductorGraphCanvas.swift`)

- `ScrollView([.horizontal, .vertical])` hosting a `ZStack`: one SwiftUI
  `Canvas` drawing edges as paths (theme `borderStrong`; NO color-coded
  meaning on edges), with node views positioned over it. Layout math
  hoisted out of `body` (the `GitCommitGraphView` rule); recompute only
  when manifests/live state change (`.task(id:)` / observation).
- **Nodes are real `Button`s** (hit-testing, Full Keyboard Access, focus
  ring via `focusRing` token) — never canvas-drawn shapes with tap
  gestures. Node content: status glyph + status label text, title,
  provider icon (see icons below) with the CLI name in `.help` and
  accessibility label, detail line. Selected node gets `selection`
  background; `RafuMetrics` radii/spacing; editor-surface background
  tokens (`cardBackground` on `editorBackground`).
- **Primary click = the state's primary verb** (table above): running →
  `session.workflowController(forRunID:)?.revealLiveTerminal(stepIndex:in:)`
  (falls back to `conductorRunController.revealLiveTerminal(for:in:)`);
  completed → `session.openFile(atRelativePath:)` on the artifact;
  failed → open `logs/output.log` as a tab; gates → the verb buttons are
  IN the node card (visible buttons, `RafuProminentButtonStyle` primary),
  wired exactly like `ConductorRunDetailCanvas` (via
  `workflowController(forRunID:)`, `Task { await approveGate() }` etc.).
  Secondary affordance on every node: "Show Run Detail" →
  `session.showConductorRunDetail(runID)`. All verbs also reachable via
  a context menu AND the existing menu/palette paths (no gesture-only
  actions).
- Coordinator root node: icon of its CLI, "Open Terminal" when the
  session is live (`terminalSessionID` → `session.revealTerminalSession`),
  plain "ended" detail otherwise. Read
  `session.conductorCoordinatorSessions` **defensively**: C8-03 lands it
  this same wave — code against the property; if your branch predates
  its merge, add a minimal placeholder of the same shape in YOUR plan's
  WorkspaceSession seam and flag the duplicate for the coordinator to
  reconcile at merge (both are additive; the merge is trivial).
- Empty state: `ContentUnavailableView("No Ensemble Runs", systemImage:
  WorkspaceNavigatorMode.runs.symbolName, description: …)` — and the
  whole canvas pins to the top (the AGENTS.md `.frame(maxHeight:
  .infinity, alignment: .top)` rule; empty states expand to center in
  remaining space).
- Motion: state changes update immediately; no decorative animation
  (frequent updates + Reduce Motion). Live "running" indication is the
  glyph + label, not a pulse.
- Accessibility: every node `.accessibilityLabel("<title>, <state
  label>, <provider display name>")`; the edge canvas
  `.accessibilityHidden(true)`; VoiceOver order column-major.

### Routing seam (`WorkspaceSession.swift` — anchored)

Immediately after `closeConductorRunDetail()` (~line 445) add, and
nothing else anywhere in the file:

```swift
var conductorGraphVisible: Bool  (default false, @Observable-tracked)
func showConductorGraph()   // sets true; selectedDocumentID = nil; selectedTreePath = nil; navigatorMode = .runs
func closeConductorGraph()  // false; falls back like closeConductorRunDetail()
```

`showConductorRunDetail` and `revealTerminalSession` must also clear
`conductorGraphVisible` (two one-line additions inside those methods —
graph, run detail, and terminal are peer canvas occupants).

`EditorCanvasView.swift`: insert the graph branch ABOVE the run-detail
branch: `session.conductorGraphVisible && session.selectedDocumentID ==
nil` → `ConductorGraphCanvas(session:)`; add `conductorGraphVisible ==
false` to the emptiness guard (branch 2). Keep the hunk minimal and
isolated (the C5 precedent — one commit).

### Entry points

- Runs panel header (next to "New Run…"): a "Graph" bordered button →
  `session.showConductorGraph()`.
- `RafuAppCommands.swift` Ensemble block: `Button("Show Ensemble
  Graph")` (no key equivalent — consistent with the block's comment;
  ⌘⇧E stays reserved for C8-07).
- `CommandPaletteView.swift`: `PaletteCommand(id: "conductor.show-graph",
  title: "Ensemble: Show Graph", keywords: ["ensemble","graph","runs"])`.

### Agent icons (`ConductorCLIIcons.swift` + SVGs)

- `claude.svg`, `codex.svg`, `gemini.svg` already exist in
  `Resources/FileIcons/`. ADD `opencode.svg`, `cline.svg`, `kimi.svg`,
  `cursor.svg`: **monochrome, template-style (`currentColor`), simple
  geometric letterform badges** (rounded-rect outline + "OC", "CL",
  "K", "▮|" cursor-caret mark). Do NOT imitate vendor logos — these are
  honest placeholders, visually consistent, tinted like symbols
  (`FileIconView` + `assetIsTemplate: true`).
- `ConductorCLIIcons.icon(for id: ConductorCLIID) -> FileIconProvider.Icon`
  mapping all seven (assetName + `assetIsTemplate: true`, symbol
  fallback `terminal` with `.secondary` tint). Rendered in graph nodes
  (14 pt badge), and reused by the Activity feed rows.
- `script/build_and_run.sh`: add four `test -f
  "$APP_RESOURCES/FileIcons/<name>.svg"` lines beside the existing
  staging assertions (~lines 184–186).

### Runs panel additions

- Segmented picker gains a third segment: `Runs | Workflows | Activity`.
  Activity = newest-first `List` over
  `ConductorEnsembleEventCenter.shared` ring buffer (cap 200 rows):
  relative time, provider icon when resolvable, one bounded line
  ("Implement A → awaiting gate", "note: …" truncated at 120 chars).
  Top-pinned; empty state expands. No per-row verbs beyond "Open Run"
  (→ `showConductorRunDetail`).
- `ConductorRunRowView`: when `manifest.startedBy != nil`, append a
  `RafuChip("via <startedBy label or id-prefix>")` — the "no silent
  runs" attribution.

## Tests

- `GraphModelTests`: deterministic layout (same input ⇒ same
  columns/rows); `startedBy` grouping (two coordinators + orphan runs ⇒
  three roots); ended-coordinator synthesis; artifact-edge derivation;
  gate node appended; unknown-kind tolerance (`default` path).
- `GraphCanvasRoutingTests` (pattern:
  `WorkflowPresentationTests.showAndCloseConductorRunDetail`):
  `showConductorGraph` clears doc selection + sets `.runs`;
  `showConductorRunDetail` and `revealTerminalSession` clear the graph;
  close falls back to last document; second-window independence (two
  sessions, one graph visible each — state ownership).
- `FileIconAssetsTests`: four new assets load; `ConductorCLIIcons`
  covers all seven `ConductorCLIID` cases (exhaustive switch — compiler
  enforced, plus a runtime allCases test).
- Presentation: `graphNode(for:live:)` glyphs are shape-distinct and
  labeled (extend the existing shape-distinctness test pattern).

## Gates

`swift build` 0 warnings; `swift test` + `--no-parallel`; format
`--fix`/`--lint`; `xmllint --noout` on the four new SVGs. HEADLESS ONLY —
the staged-app GUI pass (canvas eyeball, second window, keyboard
reachability, VoiceOver spot-check) happens on `main` post-merge; list it
in your report as pending coordinator verification.

## Documentation deliverables

NEW `docs/references/ensemble-graph-canvas.md` (projection contract:
inputs, state precedence reuse, node/verb table, why nodes are Buttons,
icon policy); `ensemble-manual-test-plan.md` section **K — Graph canvas**
(`| # | Do this | Expect |` rows: K1 open graph, K2 click running node →
terminal, K3 gate verbs on node, K4 attribution chip, K5 Activity feed,
K6 VoiceOver labels, K7 second window) + add K2/K3 to the ranked
priority list. Intended `docs/references/README.md` row in the report.

## Handoff report

Delivered behavior; changed paths; test evidence; screenshots N/A
(headless) — instead the exact manual checks the coordinator must run;
any WorkspaceSession merge-reconciliation note re C8-03's coordinator
sessions; branch; commit messages; `git rev-parse HEAD`.

---

## Goal-mode agent prompt (copy into the worktree agent)

```
You are a phase agent for the Rafu repository, working in a dedicated git
worktree. GOAL MODE: you own the outcome end to end; do not ask for
permission between steps; finish or report precisely why you cannot.

Branch: conductor/c8-06-graph-canvas. Preflight: run `git status --short
--branch` ONCE. On this branch + clean tree → proceed. Detached HEAD or
wrong branch + clean tree → checkout the branch if it exists, else
`git checkout -b conductor/c8-06-graph-canvas main`, then proceed and say
so. Dirty tree with edits you did not make → STOP. Then verify the
prerequisite: ConductorRunManifest has a `startedBy` property
(Sources/RafuApp/Conductor/ConductorCore.swift). Missing ⇒ STOP and
report — C8-02 has not merged.

GOAL: implement docs/plans/phases/conductor/C8-06-graph-canvas.md — the
interactive Ensemble graph canvas as a new editor-canvas mode
(ConductorGraphModel pure layout + ConductorGraphCanvas view), the
WorkspaceSession/EditorCanvasView routing seam, per-agent icons for all
seven CLIs (four new template SVGs + ConductorCLIIcons mapping + staging
asserts), the Runs panel Activity segment fed by the event center, the
startedBy attribution chip, and the menu/palette entries. The plan file
is your authoritative design contract, edit list, and test list — read
it FIRST, then AGENTS.md (interface rules), the conductor README ground
rules, C8-coordinator-ux.md's canvas sections, and copy the
CommitGraphLayout/GitCommitGraphView and WorkflowPresentationTests
patterns it names. Use swiftui-expert-skill and swiftui-patterns.

HARD CONSTRAINTS: the graph is a PROJECTION of manifests + live state —
no editing, no drag-and-drop authoring; nodes are real focusable
Buttons, never gesture-only shapes; state is glyph + text label, never
color alone; every node verb also has a menu/context path; layout math
never runs in body; no decorative motion on state changes; panels pin
top; internal symbols Conductor*, user-visible strings "Ensemble". DO
NOT touch Package.swift, ConductorCore.swift, engine files,
ConductorRunDetailCanvas.swift, Settings, or anything under
Sources/RafuApp/Conductor/Ensemble/ (C8-03 owns those this wave).
HEADLESS ONLY — never run build_and_run.sh or launch Rafu.app; list the
required GUI checks for the coordinator instead.

DEFINITION OF DONE:
1. ConductorGraphModel.build is pure, deterministic, and tested:
   startedBy trees (ended coordinators synthesized), step chains,
   artifact edges, gate nodes, unknown-input tolerance.
2. The canvas routes exactly like the run-detail precedent: show/close
   methods, peer-exclusivity with run detail and terminal reveal, the
   EditorCanvasView branch + emptiness guard, all covered by routing
   tests including a second-window test.
3. Clicking a node performs its state's primary verb (terminal reveal /
   artifact open / evidence open / gate verbs inline) through
   workflowController(forRunID:) — wired, not decorative.
4. All seven ConductorCLIID cases resolve an icon (exhaustive switch +
   test); four new monochrome template SVGs pass xmllint and are
   staged-asserted in build_and_run.sh.
5. Activity segment + attribution chips render from real data, top-
   pinned, bounded.
6. swift build 0 warnings; swift test AND swift test --no-parallel
   green; format --fix + --lint clean.
7. ensemble-graph-canvas.md written; manual-test-plan section K added;
   intended index row in the report only.
8. Work committed locally in verified stages; never push/merge/rebase/
   checkout main. Shared-file needs are a HANDOFF with a proposed diff.

FINAL REPORT (mandatory): delivered behavior; changed paths; test
evidence; the manual GUI checks the coordinator must run on main; any
WorkspaceSession reconciliation note versus C8-03; remaining risks;
branch name; every commit message; last commit id from
`git rev-parse HEAD`.
```
