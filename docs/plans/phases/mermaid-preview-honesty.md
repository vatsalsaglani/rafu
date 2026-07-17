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

## M1 — Contract, detection, honest fallback, badge (option (b), landed first)

- `Sources/RafuApp/Markdown/MarkdownModels.swift`: add `MermaidParseResult`
  (`.flow(…)`, `.sequence(…)`, `.unsupported(type:raw:)`,
  `.malformed(type:raw:reason:)`; the implementor chooses between one result
  enum vs extending `MermaidDiagram.Kind` — decide in this increment, record
  the choice). Replace the binary detection in `parseMermaid`
  (`MarkdownModels.swift:132`) with a first-token classifier:
  `flowchart`/`graph` → flow, `sequenceDiagram` → sequence, a known-types
  list (taken from current Mermaid docs at implementation time:
  classDiagram, stateDiagram/v2, erDiagram, gantt, pie, journey, gitGraph,
  mindmap, timeline, quadrantChart, requirement, C4*, sankey, xychart,
  block, packet, kanban, architecture) → `.unsupported`; unknown/empty →
  `.malformed`. Current flow/sequence parsing stays wired temporarily.
- New `MermaidUnsupportedView` (styled like the existing `.code` block +
  notice line via `theme.ui.warning ?? theme.ui.textSecondary`) and the
  "Simplified native preview" badge on every native render.
- Update `MarkdownPreviewSegmentParser.parse`
  (`MarkdownPreviewView.swift:121`) and `MarkdownPreviewView` routing for
  the new cases. Keep the segmentation regex (`:94`) intact.
- Tests (new `MermaidParserTests.swift`): each unsupported type →
  `.unsupported`; malformed → `.malformed`; legacy header spellings
  (`graph LR`, `flowchart TD`, bare `flowchart`) still route to flow; a
  `flowchart` with no parseable edges → fallback, not a blank box; existing
  `parsesMarkdownAndMermaid`, `parsesSequenceDiagram`,
  `richPreviewSegmentation`, `repeatedBlocksHaveUniqueIdentity` pass
  (updated only for model shape).
- Documentor: write ADR 0008 from the skeleton in this plan's Decision
  section (status Accepted once the user approves in-lane), start
  `docs/references/mermaid-native-preview.md`.

Gate: unsupported/malformed input can no longer silently mis-render; badge
visible; build/tests/lint green; `--verify` preview pass.

## M2 — Flow model + parser upgrade

- Extend the flow model: node-shape enum (`[]` rect, `()` round, `{}`
  diamond, `(())` circle, `[[]]` subroutine, `[/ /]` parallelogram, `>]`
  flag), edge kind (solid/dotted/thick; arrow-head variants `-->`, `--o`,
  `--x`, `<-->`), edge labels, chained-edge expansion (`A-->B-->C`), `&`
  grouping, `subgraph`/`end` nesting, direction capture (LR/RL/TD/BT).
- Tests: fixtures asserting exact node/edge/subgraph graphs
  (order-independent where appropriate); distinct identity for repeated
  edges.

Gate: parser fixtures green; no rendering change yet.

## M3 — Flow layout (pure)

- New `Sources/RafuApp/Markdown/MermaidLayout.swift`: layered (rank-based)
  layout — rank assignment via longest-path with back-edge detection
  (cycles broken for ranking, marked as feedback edges), in-rank ordering,
  coordinate assignment, subgraph bounds, edge routing. Pure `Sendable`, no
  SwiftUI import. Sequence-geometry helper (lifeline x-positions, message
  y-positions, activation-bar spans, block frames) lands here too, unused
  until M6.
- Tests (`MermaidLayoutTests.swift`): ranks, in-rank ordering, subgraph
  containment, no-overlap invariant on computed frames, cyclic fixture.
  **No pixel snapshots** — assert topology/frame invariants only.

Gate: layout tests green.

## M4 — Flow renderer

- Extract `MermaidDiagramView` into its own file; replace the flat-list flow
  branch with a `Canvas`/`GeometryReader` render driven by `MermaidLayout`:
  nodes by shape, directed edges with arrowheads and labels, subgraph boxes,
  LR/TD respected. Badge retained. Accessibility label/description on the
  drawn diagram; no decorative motion (Reduce Motion respected trivially).

Gate: `--verify` manual pass — a directional flowchart with subgraphs and
edge labels renders as a real 2D graph; second window checked.

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
