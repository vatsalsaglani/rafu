# Lane plan — Mermaid preview honesty (bounded native renderer v2)

## Status

Planned (2026-07-17). One of six post-audit lanes defined in
[`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md). Runs in a
**dedicated git worktree**. Each increment is one advisor → implementor →
verification → documentor cycle. File:line anchors reflect the tree on
2026-07-17; the advisor re-verifies at brief time and the repository wins
over this plan when they disagree.

## Problem

"Mermaid support" today is a hand-rolled approximation, not an engine, and it
is dishonest about that:

- Type detection is binary (`MarkdownModels.swift:136`): first line
  `sequenceDiagram` → `.sequence`; **everything else → `.flow`**. There is no
  unsupported branch and no fallback.
- Flowchart parsing (`MarkdownModels.swift:167–190`) handles only four arrow
  spellings and `|label|` labels; direction (`LR`/`TD`) is parsed then
  ignored; no subgraphs, shapes, chained edges, or `&` grouping.
- Sequence parsing (`MarkdownModels.swift:136–165`) handles participants and
  one message per line; no activations, `alt`/`opt`/`loop`/`par`, or notes.
- Rendering (`MarkdownPreviewView.swift:139–196`) draws flowcharts as a
  **flat vertical list** of `node → label → node` rows — topology is lost —
  and sequence diagrams as flat rows without lifelines.
- Unsupported types (`classDiagram`, `pie`, `gantt`, `stateDiagram`, ER,
  gitGraph, …) fall into the `.flow` branch and render a blank or garbage
  box, silently.

## Decision (records as ADR 0008 in increment M1)

Adopt a **bounded native renderer v2 with honest fallback**:

- A well-defined supported subset — flowchart + sequence, done properly —
  with a real native 2D layout.
- Everything outside the subset (or malformed) renders as the **source code
  block plus a visible "diagram type not supported in native preview"
  notice** — never a blank or wrong diagram.
- Every native diagram render carries a persistent **"Simplified native
  preview" badge**.
- No JS engine, no WKWebView, no new package dependency. A single shared
  lazy WKWebView rendering mermaid.js to images was considered (precedent:
  ADR 0004's lazy/bounded terminal), conflicts with the spirit of the
  native-preview invariant and the idle-memory budget, and is **deferred** —
  reopening it requires its own ADR, a measured lazy-webview memory pass,
  and explicit user product direction. The ADR records this.

The increment order is deliberate: M1 alone already makes the feature honest
(detection + fallback + badge), so the lane is shippable after any increment.

## Global rules for this lane

- **Owned paths:** `Sources/RafuApp/Markdown/**` (including new
  `MermaidLayout.swift` and extracted `MermaidDiagramView.swift`),
  `Tests/RafuAppTests/MarkdownParserTests.swift`,
  `Tests/RafuAppTests/MermaidParserTests.swift` (new),
  `Tests/RafuAppTests/MermaidLayoutTests.swift` (new),
  `docs/decisions/0008-mermaid-native-preview.md` (new — the number is
  reserved by the fan-out plan),
  `docs/references/mermaid-native-preview.md` (new), the Mermaid sentence in
  `docs/references/local-editor-vertical-slice.md` (lines 25–27 area only),
  and this plan document.
- **Forbidden paths:** `Package.swift`, `Package.resolved` (no new
  dependencies — this is what keeps the lane conflict-free),
  `Sources/RafuApp/LanguageIntelligence/**`, `Sources/RafuApp/Editor/**`
  (incl. `Editor/Syntax/**`; `TreeSitterCodeSyntaxHighlighter` is a
  read-only dependency), `Sources/RafuApp/Services/**`,
  `Sources/RafuApp/Models/WorkspaceSession.swift`,
  `Sources/RafuApp/Support/RafuTheme.swift` (**no new theme tokens** — use
  existing `warning`/`info` with `textSecondary` fallback), other
  `Sources/RafuApp/Views/**`, `Sources/RafuCLI/**`, `AGENTS.md`, and shared
  doc indexes except single appends to `docs/references/README.md` and
  `docs/decisions/README.md` at merge time (see fan-out plan for
  index-conflict protocol). If work appears to require a forbidden path,
  stop and escalate.
- **Preserved contracts:** the MarkdownUI boundary and
  `TreeSitterCodeSyntaxHighlighter` routing in `MarkdownPreviewView`; the
  `MarkdownPreviewSegmentParser` segmentation regex/contract
  (`MarkdownPreviewView.swift:91–137`); durable UUID identity on every
  repeated row (edges, messages, subgraph children, block-nested messages) —
  never array offsets or content hashes.
- All new model/layout types are `nonisolated`, `Sendable` value types.
  Layout is computed outside `body` (parser/segment stage or cached
  `@State`), never per-frame in a `Canvas` closure.
- Verification per increment: `swift build`, `swift test`,
  `./script/format.sh --fix` then `--lint`;
  `./script/build_and_run.sh --verify` for increments that change rendering
  (M1, M4, M6) — never while another lane is running it (the script kills
  any staged Rafu.app).
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.

## M1 — Contract, detection, honest fallback, badge

**Status: Complete (2026-07-17)**

### Implementation

- `Sources/RafuApp/Markdown/MarkdownModels.swift`: added `MermaidParseResult`
  (`.flow(…)`, `.sequence(…)`, `.unsupported(type:raw:)`,
  `.malformed(type:raw:reason:)`). Chose **option (a): one result enum** — this
  keeps the enum and its call sites frozen for M2–M6 while the payload structs
  grow new fields. Replaced the binary detection in `parseMermaid` with a
  first-token classifier: `flowchart`/`graph` → flow, `sequenceDiagram` →
  sequence, known-types list (29 types from Mermaid v10) → `.unsupported`;
  unknown/empty → `.malformed`. Classifier skips leading blanks, YAML
  frontmatter (`---`…`---`), and `%%` comment lines. Current flow/sequence
  parsing bodies wired unchanged (M2/M5 rewrite them).
- New `MermaidUnsupportedView` styled as a code block plus notice line
  (`theme.ui.warning ?? theme.ui.textSecondary`). "Simplified native preview"
  badge added to every native render.
- Updated `MarkdownPreviewSegmentParser.parse` and `MarkdownPreviewView` routing
  for the new result cases. Segmentation regex preserved.
- Tests: new `MermaidParserTests.swift` with fixtures for each unsupported type,
  malformed cases, legacy spellings, and fallback rendering. Existing
  `parsesMarkdownAndMermaid`, `parsesSequenceDiagram`,
  `richPreviewSegmentation`, `repeatedBlocksHaveUniqueIdentity` tests updated
  for result shape only.
- Documented: ADR 0008 (status Proposed, recorded option (a) choice and deferred
  WKWebView alternative), `docs/references/mermaid-native-preview.md` started
  (M1 classifier, fallback, and known limitation sections; layout/fixture
  sections stub for M3/M7).

### Verification

- `swift build` — clean, no new dependency.
- `swift test` — 510 tests pass.
- `./script/format.sh --lint` — clean.
- `./script/build_and_run.sh --verify` — **deferred** to the consolidated GUI
  pass at M6/M7 (other lanes share the staged app). The M1 badge/fallback
  rendering is covered there.

### Known M1 limitation

The classifier correctly identifies diagram types even with frontmatter/comments,
but the body parsers still assume line 0 is the header (unchanged from prior
behavior). M2/M5 rewrite body parsers to skip frontmatter in context. Not a
regression.

Gate: unsupported/malformed input can no longer silently mis-render; badge
visible; build/tests/lint green ✓; `--verify` preview pass deferred to the
consolidated M6/M7 GUI pass.

## M2 — Flow model + parser upgrade

**Status: Complete (2026-07-17)**

### Implementation

- `Sources/RafuApp/Markdown/MarkdownModels.swift` extended `MermaidFlow`:
  - `Direction` enum (TD/LR/BT/RL; default TD if header line omitted).
  - `nodesByID: [UUID: Node]` replacing the old flat `nodes: [String: String]`; 
    `Node` holds ID, text label, and `NodeShape` (rectangle, round, diamond, circle,
    subroutine, parallelogram, flag). Shape detection by bracket syntax 
    (`[]`, `()`, `{}`, `(())`, `[[]]`, `[/ /]`, `>]`).
  - `Edge` enriched with `EdgeLine` (solid/dotted/thick) and `EdgeHead` 
    (none/arrow/circle/cross) on both start and end; bidirectional edges represented
    as start + end arrows. Preserved `Edge.label` field for M4 renderer compat.
  - `Subgraph` as a nested tree: `subgraphsByID: [UUID: Subgraph]`, each carrying 
    ID, label, child node/edge UUIDs, and durable identity across parses.
- `parseFlow` rewritten as a **bracket/quote-depth-aware tokenizer**:
  - Shape detection using double-before-single delimiter heuristic (`--` before `-`,
    `---` before `--` before `-`, etc.).
  - Connector parsing: solid `-->`, dotted `-.-`, thick `===`, etc., mapped to
    `EdgeLine`/`EdgeHead` tuples; bidirectional `<-->` and variants parsed as
    start+end arrows.
  - Label precedence: `|piped label|` wins over inline solid `-- label --` (both
    parsed; pipe takes priority). Dotted/thick inline mid-labels (`-. label .-`,
    `== label ==`) are recognized but not parsed into labels (M7 enhancement).
  - Chained-edge expansion (`A-->B-->C` becomes two edges, each with a fresh UUID)
    and `&` cross-product expansion (each product edge gets a fresh UUID).
  - Nested `subgraph`/`end` membership and scope nesting.
  - Header-line direction capture (LR/TD/etc.) and fallback to TD.
  - **Frontmatter-aware**: YAML frontmatter and comment lines now skipped in body
    parsing (M1 limitation fixed).
- M4 compatibility preserved: `raw`, `nodes: [String:String]`, and `edges` fields
  still populated from the new model, ensuring the M1 renderer compiles unchanged.
- Tests: `Tests/RafuAppTests/MermaidParserTests.swift` extended with fixtures
  asserting exact node/edge/subgraph structure (order-independent where appropriate);
  distinct UUID identity for repeated edges and cross-product expansions.

### Verification

- `swift build` — clean, no new dependency.
- `swift test` — 523 tests pass (new M2 fixtures included).
- `./script/format.sh --lint` — clean.
- `./script/build_and_run.sh --verify` — **deferred** to M4/M6/M7 (no rendering
  change in M2; layout and render arrive in M4/M6).
- Diff limited to `MarkdownModels.swift` + `MermaidParserTests.swift`.

### Known M2 limitations

1. **Per-subgraph direction lines:** recognized and skipped (e.g. `subgraph x LR`),
   but no per-scope direction modeled — all edges within subgraphs use the
   root-level direction. Full per-subgraph direction support deferred.

2. **Dotted/thick inline mid-labels:** `A-. label .--> B` and `A== label ==> B`
   are tokenized correctly but the label is not extracted — only solid ` -- label -- `
   inline and `|piped|` labels are captured. Mid-label full support deferred.

Gate: parser fixtures green ✓; no rendering change yet; M4-compat preserved.
  Branch-clean for M3 layout work.

## M3 — Flow layout (pure)

**Status: Complete (2026-07-17)**

### Implementation

- New `Sources/RafuApp/Markdown/MermaidLayout.swift`: pure CoreGraphics-domain
  layout engine (imports only Foundation + CoreGraphics; all types nonisolated
  `Sendable` value types). `MermaidLayoutEngine.layout(_ flow:)` → `MermaidFlowLayout`
  (NodeFrame with rank/order, EdgeGeometry with endpoints/arrowAnchor/
  arrowDirection/isFeedback, SubgraphFrame with depth, canvasSize). Rank
  assignment = longest-path DAG with iterative-DFS back-edge detection (cycles
  broken and marked `isFeedback`, kept for routing); self-loops excluded from
  ranking adjacency (no infinite loop) routed as right-side bulge, never
  `isFeedback`; isolated/multi-component nodes ranked default 0. Deterministic
  in-rank ordering (barycenter-lite, first-seen tiebreak — never iterates raw
  Dictionary for order). Direction-aware coordinates (TD/BT/LR/RL). Bottom-up
  subgraph bounds (children recursed first, parent unions child frames + member
  rects — because parser lists node only in innermost subgraph; parents emitted
  pre-order). Edge routing = generic rect-boundary intersection toward opposite
  node center. Also `layout(_ sequence:)` → `MermaidSequenceLayout` (lifelines +
  message rows keyed by durable Message.id; empty activations/blocks scaffold
  for M5/M6).
- Tests (`MermaidLayoutTests.swift`): ranks, in-rank ordering, subgraph
  containment + nesting, node no-overlap, cyclic-terminates-with-feedback,
  self-loop, direction-axis, empty graph, disconnected components, sequence
  ordering/identity. **No pixel snapshots** — assert topology/frame invariants only.

### Verification

- `swift build` — clean, no new dependency.
- `swift test` — 535 tests pass (12 new layout tests).
- `./script/format.sh --lint` — clean.
- `./script/build_and_run.sh --verify` — **deferred** to M6/M7 (no rendering
  change in M3; layout is cached, never computed per-frame in Canvas closure).
- Diff limited to the two new files.

### Known M3 limitation

Sibling subgraph boxes are not guaranteed disjoint — only "member node frame ⊆
own subgraph frame" and "child frame ⊆ parent frame" hold. `canvasSize` is
intentionally unbounded for dense/wide diagrams. This is a design choice, not
a defect.

Gate: layout tests green ✓.

## M4 — Flow renderer

**Status: Complete (2026-07-17)**

### Implementation

- Extracted `MermaidDiagramView` and `MermaidUnsupportedView` into new
  `Sources/RafuApp/Markdown/MermaidDiagramView.swift` (pure file split from
  `MarkdownPreviewView.swift`; top-level view, segment types, segmentation
  regex, MarkdownUI boundary, and TreeSitter routing remain byte-identical;
  call site `MermaidDiagramView(result:)` unchanged).
- Replaced the flat-list flow branch with a real 2D `Canvas` render via new
  `MermaidFlowCanvas` child view:
  - **Node rendering:** all seven shapes supported (rectangle, round, diamond,
    circle, subroutine, parallelogram, flag) with labels centered.
  - **Edge rendering:** styled by `EdgeLine` (solid/dotted/thick) with
    direction-aware arrowheads (`EdgeHead`: arrow/circle/cross,
    bidirectional). Edge labels positioned at segment midpoints.
  - **Subgraph boxes:** depth-based dashing (outer → inner, dashed borders),
    membership via child UUIDs.
  - **Direction:** TD/BT/LR/RL fully direction-aware (coordinates from layout);
    no scaling or blur.
  - **Layout:** fixed-size `Canvas` (via `layout.canvasSize` from `MermaidFlowLayout`)
    inside a horizontal `ScrollView` for honest sizing (user sees real 2D graph,
    scrolls if needed; no auto-scaling).
- Badge retained ("Simplified native preview"). `.sequence` unchanged (M6
  renders it); `.unsupported`/`.malformed` fallback unchanged.
- **Styling:** only existing theme tokens used (`accent`, `textPrimary`,
  `textSecondary`, `borderSubtle`, `selection`, `elevatedBackground`);
  no new tokens.
- **Accessibility:** `.accessibilityElement(children:.ignore)` on Canvas +
  accessibility label with node/edge counts + individual node labels. Canvas
  is opaque to VoiceOver; explicit label makes diagram presence/type clear.
  No animations; Reduce Motion trivially satisfied.

### Verification

- `swift build` — clean, no new dependency.
- `swift test` — 535 tests pass (M3 layout + parser tests cover geometry;
  Canvas is not pixel-testable; pixel snapshots forbidden per policy).
- `./script/format.sh --lint` — clean.
- Diff limited to `MermaidDiagramView.swift` (new), `MarkdownPreviewView.swift`
  (extraction only), and `MarkdownPreviewSegmentParser.swift` (routing update).
- `./script/build_and_run.sh --verify` — **deferred** to consolidated M6/M7
  GUI pass per coordinator direction (other lanes share staged app). Manual
  gate checks (directional flowchart with subgraphs + edge labels renders as
  real 2D graph; second window; keyboard reachability of horizontal scroll)
  are deferred to that consolidated pass.

### Known M4 limitation

Canvas visual quality is bounded native, not mermaid.js parity — the badge and
ADR 0008 say so explicitly. Sibling subgraph boxes not guaranteed disjoint
(M3 design choice; see layout notes).

Gate: build/tests/lint green ✓; `--verify` manual pass deferred to M6/M7.

## M5 — Sequence model + parser upgrade

- Activations (`activate`/`deactivate`, `+`/`-` suffixes), `alt`/`opt`/
  `loop`/`par`/`else` blocks with nested messages, `Note over/left of/right
  of`, `actor` vs `participant`, self-messages.
- Tests: nested-block fixtures; durable identity for block-nested messages.

## M6 — Sequence renderer

- Lifelines, activation bars, block frames, time-ordered messages via the
  M3 geometry helper.

Gate: `--verify` manual pass — sequence diagram with `alt`/`loop` +
activations renders with lifelines and frames; unsupported type still falls
back; badge everywhere.

## M7 — Documentation close-out

- Finalize `docs/references/mermaid-native-preview.md` (subset contract,
  layout algorithm, fixture policy, verified toolchain), update the Mermaid
  sentence in `local-editor-vertical-slice.md`, mark this plan's increments
  complete, prepare the merge handoff (delivered behavior, changed paths,
  evidence, risks). Index appends happen at merge per the fan-out plan.

## Risks

- Layout quality is "good for common diagrams," not mermaid.js parity — the
  badge and ADR say so explicitly; tests assert topology, not pixels.
- Cyclic flowcharts: handled via back-edge breaking (M3); fixture required.
- Legacy behavior: `graph`/`flowchart` inputs that partly rendered before
  must still route to flow (M1 fixture).
- Segmentation regex interaction: parser must tolerate leading/trailing
  whitespace and empty fence bodies.

## Exit

- Classifier + typed models for flowchart/graph/sequenceDiagram; everything
  else `.unsupported` with code-block + notice.
- Real direction-aware flow layout (shapes, labels, subgraphs); sequence
  lifelines/activations/blocks.
- Badge on every native render; no new dependency; no WKWebView;
  segmentation and MarkdownUI boundaries unchanged.
- ADR 0008 accepted + reference note indexed at merge; all verification
  gates green.
