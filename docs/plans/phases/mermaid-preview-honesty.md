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

**Status: Complete (2026-07-17)**

### Implementation

- `Sources/RafuApp/Markdown/MarkdownModels.swift` extended `MermaidSequence`:
  - `Event` enum: `.message(Message)`, `.note(Note)`, `.blockStart(Block)`,
    `.blockDivider(Block, kind)`, `.blockEnd(UUID)`, `.activate(from:UUID)`,
    `.deactivate(to:UUID)`. Single ordered `events: [Event]` stream forms the
    canonical parse representation — block frames must span their contiguous
    nested-content range, so the stream + block-id stack naturally feeds M6 geometry.
  - `Message` enriched: `arrow: Arrow` (solid/solidArrow/dotted/dottedArrow;
    non-`>` arrows like `-x`, `--x`, `-)` still ignored), `activatesTarget`
    (Boolean; `True` iff message `+` suffix), `deactivatesSource` (Boolean; `True`
    iff message `-` suffix), computed `isSelfMessage` (from == to). Durable `UUID`
    per instance.
  - `Note` + `NotePlacement` enum (over, leftOf, rightOf).
  - `Block` + `BlockKind` (alt/opt/loop/par); each block carries durable `UUID` and
    child block/message UUIDs.
  - `participantKinds: [String: ParticipantKind]` (participant/actor) and
    `participantDisplay: [String: String]` (left token → right alias). Canonical
    participant list derived from event order.
  - **Behavior change (correctness fix):** `participant X as Y` and `actor X as Y`
    now resolve identity to the LEFT token `X`. The RIGHT token `Y` (alias) is stored
    in `participantDisplay[X]` for display only. `participants` list and message
    `from`/`to` fields carry the identity `X`. This matches Mermaid semantics; prior
    code incorrectly used the alias `Y` for identity. No prior test covered aliasing.
    M6 rendering must use `participantDisplay[id]` for human-readable names while
    using `id` (the left token) for lookups and identity.
  - `participants: [String]` (participant identities in document order) and
    `messages: [Message]` (flat derived list, document order including block-nested)
    remain populated to preserve M3 `layout(_ sequence:)` helper byte-compatibility.
- `parseSequence` rewritten as a **block-aware state machine**:
  - YAML frontmatter skip; `participant`/`actor` + `as` alias capture;
    `activate`/`deactivate` parsed into Event enum; `+`/`-` message suffixes
    parsed with correct semantics (`+` activates receiver `to`, `-` deactivates
    sender `from`).
  - `alt`/`opt`/`loop`/`par` blocks with `else`/`and` dividers and `end`
    (nesting via block-id stack; unclosed blocks flushed with synthesized
    `blockEnd` at EOF; stray `end` ignored).
  - `Note over/left of/right of` parsed; `Note` placed in event stream.
  - Self-messages (from == to) handled; all message types wired to events.
  - Frontmatter-aware parsing.
- M3 compat preserved: `participants` and `messages` derived from `events` so
  `MermaidLayout.swift` and its tests remain untouched.
- Tests: new `MermaidParserTests.swift` fixtures for nested blocks (alt/opt/loop/par with dividers),
  `activate`/`deactivate` events, notes, actor/participant aliasing, self-messages,
  empty blocks; durable UUID identity verified; existing `parsesSequenceDiagram`,
  `sequenceDiagramClassifiesAsSequence`, and M3 sequence-layout tests still pass.

### Verification

- `swift build` — clean, no new dependency.
- `swift test` — 546 tests pass (11 new M5 fixtures; existing parser and M3 layout tests green).
- `./script/format.sh --lint` — clean.
- Diff limited to `MarkdownModels.swift` + `MermaidParserTests.swift`.
- `./script/build_and_run.sh --verify` — **deferred** to M6 (no rendering change in M5;
  lifelines and block frames arrive in M6).

### Known M5 limitations

1. **Non-`>` message arrows:** `-x`, `--x`, `-)` and other non-arrow endings are still
   ignored (parsed as notes or edge cases). Only `>` arrows (`-->`, `-.->`/dotted,
   `..>`) are modeled. Full support deferred.

2. **Empty block branches:** A branch with no messages (e.g., `alt` with an empty
   `else`) is a degenerate geometry concern for M6 y-range calculation. Parsed
   and preserved in the event stream; M6 will handle the rendering.

Gate: parser fixtures green ✓; M3-compat verified; no rendering change yet. Branch-clean for M6 rendering.

### Related learning

**Participant identity semantics:** The fix to use the LEFT token (not alias) for identity is
a reusable Mermaid-syntax fact recorded in the reference note. Future diagram types (flowchart
subgraph ownership, actor naming) can refer to it.

## M6 — Sequence renderer

**Status: Complete (2026-07-17)**

### Implementation

- Extended `MermaidSequenceLayout` additively: `Lifeline` (+displayName, +kind
  actor/participant), `MessageRow` (+arrow style enum), `ActivationSpan` (+depth,
  nested offset), `BlockFrame` (+depth, +dividers with labels), new `NoteBox` type,
  and 13 new `Metrics` fields (lifeline x-positions, message y-positions, box
  bounds). Schema preserved; M3 test fixtures (only read, no initializer calls)
  remain green unedited.
- `MermaidLayoutEngine.layout(_ sequence:)` rewritten: walks `sequence.events`
  (not flat messages) maintaining y-cursor, per-participant activation stack
  (nesting → depth/x-offset), and block-id stack that accumulates each open
  block's x-range so frames enclose exactly their nested content. Notes placed
  by `over`/`leftOf`/`rightOf` geometry. Unclosed activations flushed to bottomY.
  Layout pure (Foundation + CoreGraphics only).
- New `MermaidSequenceCanvas`: mirrors `MermaidFlowCanvas` pattern (@State layout
  via `.task(id: seq.raw)`, Canvas in horizontal ScrollView, colors resolved outside
  closure, accessibility label, no animation). Renders back→front: block frames
  (dashed, kind+title, divider lines/labels) → lifelines (vertical line + head box;
  actor drawn with hand-drawn stick-figure glyph, not color) → activation bars
  (nested offset) → notes → time-ordered messages (solid/dotted lines, filled vs
  open arrowheads). Only existing theme tokens; dead `node(_:)` helper removed.
- Tests: 9 new M6 invariant tests (activation ordering/nesting/unclosed, block
  containment/nesting/dividers, note placement, arrow fidelity, empty-stream
  regression) confirm lifelines/frames/activations/notes geometry; M3 sequence
  tests (12 existing) stay green.

### Verification

- `swift build` — clean, no warnings.
- `swift test` — 555 tests pass (12 M3 + 9 M6 + 534 prior).
- `./script/format.sh --lint` — clean.
- `./script/build_and_run.sh --verify` — process-level pass succeeded twice
  (implementor + coordinator): `.app` staged, Rafu process launched, exit 0.
- Diff limited to three owned files (`MarkdownLayout.swift`, `MarkdownDiagramView.swift`,
  `MermaidLayoutTests.swift`).
- **Deep visual inspection (directional flowchart with subgraphs/edge labels;
  sequence with alt/loop/activations showing lifelines/frames/bars; actor glyph;
  unsupported pie/classDiagram fallback + notice; "Simplified native preview"
  badge; second window; Reduce Motion):** driven from non-GUI environment —
  NOT OBSERVED. Deferred to human/coordinator GUI pass. Verification saved at
  `scratchpad/mermaid-verify.md`.

### Known M6 limitation

Note over an undeclared participant renders at left margin (no crash). `canvasSize`
intentionally unbounded (horizontal scroll for dense diagrams). These are design
choices, not defects.

Gate: build/tests/lint green ✓; process-level `--verify` launch ✓; deep-visual
`--verify` inspection OWED to human GUI pass.

## M7 — Documentation close-out

**Status: Complete (2026-07-17)**

### Implementation

- Finalized `docs/references/mermaid-native-preview.md` (M1–M6 closed):
  - Added supported-subset contract (flowchart/graph + sequenceDiagram natively
    supported; 29 known types + malformed → honest fallback).
  - Gathered all known limitations in one place (per-subgraph direction,
    dotted/thick mid-labels, non-`>` arrows, sibling subgraph overlap,
    unbounded canvas, note over undeclared, layout parity).
  - Stated fixture policy: topology/frame invariants only, no pixel snapshots.
  - Confirmed verified toolchain (Swift 6.2.4, Xcode 26.3, macOS 26.1 on
    2026-07-17).
- Updated the Mermaid sentence in `docs/references/local-editor-vertical-slice.md`
  (lines ~25–27 only): replaced binary "supports/degrades" language with precise
  supported subset + fallback contract; added references to ADR 0008 and
  `mermaid-native-preview.md`.
- Marked this plan's increments M1–M6 complete; prepared the merge handoff
  (delivered behavior per increment, changed paths, verification evidence,
  remaining risks, next dependency). Index appends happen at merge per the
  fan-out plan.

### Verification

Documentation notes are checked into the repository and human-reviewed; no
verification build step. Internal consistency verified: no stale guidance,
no inaccurate toolchain versions, no broken links.

Gate: documentation complete and internally consistent ✓.

## Risks

- Layout quality is "good for common diagrams," not mermaid.js parity — the
  badge and ADR say so explicitly; tests assert topology, not pixels.
- Cyclic flowcharts: handled via back-edge breaking (M3); fixture required.
- Legacy behavior: `graph`/`flowchart` inputs that partly rendered before
  must still route to flow (M1 fixture).
- Segmentation regex interaction: parser must tolerate leading/trailing
  whitespace and empty fence bodies.

## Merge handoff

### Delivered behavior (M1–M6, one line each)

1. **M1:** First-token classifier (flowchart/graph/sequenceDiagram supported,
   29 known types unsupported, unknown/malformed detected); honest code-block +
   notice fallback; "Simplified native preview" badge on all native renders.
2. **M2:** Rich flow model (Direction, NodeShape, 7 node types, EdgeLine/EdgeHead,
   subgraph nesting); bracket/quote-aware parser (chained edges, `&` expansion,
   nested scope); frontmatter/comment skip in body parse.
3. **M3:** Pure CoreGraphics layout engine (longest-path DAG + back-edge detection,
   deterministic in-rank barycenter, direction-aware coordinates, subgraph
   containment, edge routing).
4. **M4:** Canvas flow renderer (all 7 node shapes, edge styles/heads, subgraph
   depth-based dashing, direction-aware arrows, horizontal scroll for unbounded
   canvas).
5. **M5:** Rich sequence model (Event stream: message/note/block/activate/
   deactivate; participant identity semantics fix; activation `+`/`-` semantics;
   block nesting/dividers; actor vs participant).
6. **M6:** Canvas sequence renderer (lifelines, activation bars with nesting,
   alt/opt/loop/par block frames, notes, actor stick-figure glyph, time-ordered
   messages, shared layout cache).

### Changed paths

- `Sources/RafuApp/Markdown/MarkdownModels.swift` (MermaidParseResult enum,
  MermaidFlow/MermaidSequence models, parser implementations)
- `Sources/RafuApp/Markdown/MarkdownPreviewView.swift` (routing for result
  cases, badge rendering)
- `Sources/RafuApp/Markdown/MermaidDiagramView.swift` (new file: Canvas
  renderers for flow and sequence)
- `Sources/RafuApp/Markdown/MermaidLayout.swift` (new file: pure layout engine)
- `Sources/RafuApp/Markdown/MarkdownPreviewSegmentParser.swift` (segmentation
  routing)
- `Tests/RafuAppTests/MarkdownParserTests.swift` (updated for new result shape)
- `Tests/RafuAppTests/MermaidParserTests.swift` (new file: M1–M5 parser fixtures)
- `Tests/RafuAppTests/MermaidLayoutTests.swift` (new file: M3–M6 layout
  invariant fixtures)
- `docs/decisions/0008-mermaid-native-preview.md` (new file: ADR Proposed)
- `docs/references/mermaid-native-preview.md` (new file: finalized reference note)
- `docs/references/local-editor-vertical-slice.md` (3-line Mermaid sentence update)
- `docs/plans/phases/mermaid-preview-honesty.md` (this file: M1–M7 completed)

### Verification evidence

- `swift build` — clean (no new dependency).
- `swift test` — 555 tests pass (12 M3 layout + 9 M6 geometry + parser fixtures).
- `./script/format.sh --lint` — clean.
- `./script/build_and_run.sh --verify` — process-level launch confirmed twice
  (implementor + coordinator); Rafu.app staged and running, exit 0.
- Deep visual GUI inspection (directional flowchart with subgraphs/edge labels;
  sequence with alt/loop/activations/lifelines/frames; actor glyph; unsupported
  type + notice; "Simplified native preview" badge; second window; Reduce
  Motion; accessibility) — **OWED** to human/coordinator GUI pass (deferred
  per coordination model). Scope documented in `scratchpad/mermaid-verify.md`.

### Remaining risks

- Deep visual inspection not yet observed (deferred to human GUI pass per
  coordination model).
- Layout quality is "good for common diagrams," not mermaid.js parity — the
  badge and ADR 0008 make this explicit; topology/frame fixtures assert
  correctness, not visual beauty.
- Sibling subgraph overlap permitted; note over undeclared participant at
  margin (design choices, not defects).
- Cyclic flowcharts handled via back-edge marking; fixture verified; no known
  regression.

### Next integration dependency

This lane integrates at merge with **L1 LSP (language-intelligence-honesty)** per
the post-audit fan-out plan. The Mermaid lane closure does not block L1; they
are independent. Shared index appends (docs/decisions/README.md + docs/references/README.md)
happen at coordinator merge, not before.

### Intended shared-index rows (coordinator must append at merge)

The rows below match the existing index column schemas exactly (verified
2026-07-17): `docs/decisions/README.md` uses `| ADR | Status | Decision |`
and `docs/references/README.md` uses `| Reference | Read when |`. Paste as-is.

**For `docs/decisions/README.md`** (append under the last ADR row):

| [0008](0008-mermaid-native-preview.md) | Accepted | Bounded native Mermaid renderer with honest fallback; supported subset flowchart + sequenceDiagram, everything else falls back to code block + notice; shared-WKWebView option deferred |

(ADR 0008's own file is currently **Proposed**; the user flips it to
**Accepted** in-lane at merge, at which point this `Accepted` row is correct.
If the flip has not happened when the row is appended, use `Proposed`.)

**For `docs/references/README.md`** (append under the last reference row):

| [`mermaid-native-preview.md`](mermaid-native-preview.md) | Changing Mermaid parsing, classification, layout, fallback rendering, or diagram-type detection |

## Exit

- ✓ Classifier + typed models for flowchart/graph/sequenceDiagram; everything
  else `.unsupported` with code-block + notice.
- ✓ Real direction-aware flow layout (shapes, labels, subgraphs); sequence
  lifelines/activations/blocks.
- ✓ Badge on every native render; no new dependency; no WKWebView;
  segmentation and MarkdownUI boundaries unchanged.
- → ADR 0008 status: Proposed (user flips to Accepted at merge); reference
  note indexed at merge by coordinator; all build/test/lint verification gates
  green ✓; process-level `--verify` launch confirmed ✓; deep-visual `--verify`
  GUI inspection OWED (deferred to human pass).
