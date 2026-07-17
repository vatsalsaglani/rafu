# Mermaid native preview — honest detection and fallback

- **Applies to:** Mermaid diagram parsing, classification, and rendering in
  `MarkdownModels.swift` and `MarkdownPreviewView.swift` (which also owns the
  in-file `MarkdownPreviewSegmentParser`)
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-17

## Rule or observed behavior

### Classification contract (M1)

The `MermaidParseResult` enum replaces the old binary flow/sequence detection.
A first-token classifier examines the first non-blank, non-comment,
non-frontmatter line:

1. **Frontmatter and comment skipping:** skip leading blank lines, YAML
   frontmatter blocks (`---`…`---`), and Markdown comment lines (`%%`…) to find
   the classifying header. This applies to classification only; body parsing
   still assumes line 0 is the header (M2/M5 fix this).

2. **Supported types:**
   - `flowchart` or `graph` (both spellings, case-insensitive) → `MermaidParseResult.flow(MermaidFlow)`
   - `sequenceDiagram` (case-insensitive) → `MermaidParseResult.sequence(MermaidSequence)`

3. **Unsupported known types** (case-insensitive, 29 types from Mermaid v10 docs):
   → `MermaidParseResult.unsupported(type:raw:)`
   - `classDiagram`, `stateDiagram`, `stateDiagram-v2`, `erDiagram`, `gantt`,
     `pie`, `journey`, `gitGraph`, `mindmap`, `timeline`, `quadrantChart`,
     `requirement`, `C4Context`, `C4Container`, `C4Component`, `C4Dynamic`,
     `C4Deployment`, `sankey`, `xychart`, `block`, `packet`, `kanban`,
     `architecture`

4. **Malformed or unknown:**
   → `MermaidParseResult.malformed(type:raw:reason:)`
   - Empty header, unknown type name, or parse error.

### Result-shape model (M1 landed option a)

- `MermaidFlow` and `MermaidSequence` are nonisolated `Sendable` value types
  holding the parsed structure.
- Every `Edge` (in flow) and `Message` (in sequence) carries a durable
  `UUID` identity assigned at parse time — never derived from content,
  offsets, or hashes. Repeated rows must use this identity as `ForEach` key.

### Fallback and honesty (M1)

- Unsupported and malformed diagrams render as a monospaced code block (the
  raw source) plus a notice line. The notice text is "diagram type not
  supported in native preview" (colored `theme.ui.warning ?? theme.ui.textSecondary`).
  Malformed appends the parse reason.
- **"Simplified native preview" badge** appears on every native flow or sequence
  render, making clear that layout is native and bounded, not mermaid.js
  parity.

### Known M1 limitation: header-line parsing

The M1 classifier correctly identifies the diagram type even with frontmatter/comments.
However, the body parsers (`parseFlow`, `parseSequence`) still have their original
implementation, which assumes the header is at line 0. A diagram with YAML
frontmatter classifies correctly but its body parse treats the first line of
source (line 0 of the raw input) as the header.

This is **not a regression** — it matches prior behavior. M2/M5 rewrite the body
parsers and will handle frontmatter/comment-skipping in the body parse too.

### Flow model contract and parsing (M2)

**Model shape:** `MermaidFlow` now carries:
- `Direction` enum: TD (default), LR, BT, RL; extracted from the header line or 
  defaulted if omitted.
- `nodesByID: [UUID: Node]` replacing flat `nodes: [String: String]`. Each `Node` 
  holds a durable UUID, text label, and `NodeShape`: rectangle (`[]`), round (`()`), 
  diamond (`{}`), circle (`(())`), subroutine (`[[]]`), parallelogram (`[/ /]`), 
  flag (`>]`).
- `Edge` with `EdgeLine` (solid/dotted/thick) and `EdgeHead` (none/arrow/circle/cross) 
  on start and end; bidirectional edges as start + end arrows. `Edge.label` preserved 
  for M4 compat.
- `subgraphsByID: [UUID: Subgraph]` tree; each `Subgraph` carries ID, label, child 
  node/edge UUIDs, durable identity.

**Tokenizing rule:** `parseFlow` is now **bracket/quote-depth-aware**: in-bracket 
or in-quoted strings, characters like `-->`, `&`, `|` do not split tokens. Example: 
`A[x --> y] --> B` is one node (text `x --> y`) plus one edge. Double-before-single 
delimiter heuristic detects shapes (`--` before `-`, `---` before `--`, etc.).

**Connector parsing table:**

| Spelling | EdgeLine | EdgeHead start | EdgeHead end |
|----------|----------|----------------|--------------|
| `-->` | solid | none | arrow |
| `--->` | solid | none | arrow |
| `--` | solid | none | none |
| `-.-` or `-...-` | dotted | none | none |
| `-.->` or `-...->` | dotted | none | arrow |
| `===` | thick | none | none |
| `===>` | thick | none | arrow |
| `--o` | solid | none | circle |
| `--x` | solid | none | cross |
| `<-->` | solid | arrow | arrow |
| `o--o` | solid | circle | circle |
| `x--x` | solid | cross | cross |

**Label precedence:** `|piped label|` wins over inline solid `-- label --`. Both are parsed; 
if both appear on one edge, the pipe label is used. Dotted (`-. label .-`) and thick 
(`== label ==`) inline mid-labels are tokenized but not extracted into labels (known 
limitation).

**Chained-edge expansion:** `A --> B --> C` expands to two edges (`A → B` and `B → C`), 
each assigned a fresh UUID (not derived from content). Cross-product `&` expansion 
(`{A,B} & {X,Y}` shorthand) similarly assigns fresh UUIDs to each product edge.

**Frontmatter and nested scopes:** YAML frontmatter (`---...---`) and comment lines 
(`%%...`) are now skipped during parsing (M1 limitation fixed). Nested `subgraph`/`end` 
blocks establish scope; membership is tracked by child UUIDs.

**Two known limitations:**
1. Per-subgraph `direction` lines (e.g. `subgraph x LR ... end`) are recognized but 
   direction is not modeled per scope — all edges use root direction.
2. Dotted and thick inline mid-labels (`-. label .-`, `== label ==`) are not extracted 
   into `Edge.label`.

### Swift Testing and enum comparison (M2 nuance)

In Swift Testing (and Swift generally), when an optional enum type is unwrapped and 
compared against a bare `.none`, the comparison resolves to `Optional.none` (nil), 
**not** the specific enum's `.none` case (if it has one).

**Why it matters:** If `EdgeHead` defines a `.none` case and a test unwraps 
`edgeHead?` then asserts `XCTAssertEqual(edgeHead, .none)`, the comparison silently 
matches `Optional.none` instead of `EdgeHead.none`, masking type confusion or 
incomplete unwrapping.

**Workaround:** Always fully qualify the enum case (`EdgeHead.none`) or unwrap the 
optional explicitly before comparison.

**Evidence:** Hit during M2 edge-head fixture tests; subsequent assertions using 
`EdgeHead.none` passed cleanly after qualification.

## Why it matters

Dishonest type detection silently produces broken diagrams, confusing users about
Rafu's capability and making it impossible to distinguish a limitation from a bug.
The honest fallback (code block + notice) makes the feature's bounds explicit and
unambiguous. The "Simplified native preview" badge prevents users from expecting
mermaid.js layout quality (parity) when they get a bounded native 2D layout.

## Evidence and verification

**Classifier tests** (`Tests/RafuAppTests/MermaidParserTests.swift`):
- Each of the 29 known-unsupported types classifies to `.unsupported`.
- Malformed headers (empty, unknown, parse error) classify to `.malformed`.
- Legacy header spellings (`graph LR`, `flowchart TD`, bare `flowchart`) still
  route to `.flow`.
- YAML frontmatter and comment lines are skipped; the classifying header is
  found.
- Case-insensitive matching for type names.

**Fallback rendering:**
- A flowchart with no parseable edges renders the unsupported code fallback,
  not a blank box.
- A malformed header renders the fallback with the parse reason included.

**Verification commands:**
```bash
swift build                    # No new dependency, no build errors
swift test                     # 510 tests pass (all existing + new fixtures)
./script/format.sh --lint      # No format warnings
./script/build_and_run.sh --verify   # Badge visible on native renders
```

## Related code, ADRs, and phases

- **Code:**
  - `Sources/RafuApp/Markdown/MarkdownModels.swift` — `MermaidParseResult` enum,
    `parseMermaid`, `firstHeaderLine` helper, `parseFlow`/`parseSequence`
    (bodies unchanged in M1)
  - `Sources/RafuApp/Markdown/MarkdownPreviewView.swift` — routing for result cases,
    `MermaidUnsupportedView`, badge rendering, and the in-file
    `MarkdownPreviewSegmentParser` segment parsing

- **Tests:**
  - `Tests/RafuAppTests/MermaidParserTests.swift` — classifier and fallback fixtures
  - `Tests/RafuAppTests/MarkdownParserTests.swift` — existing smoke tests (updated for result shape)

- **ADR:** [`0008-mermaid-native-preview.md`](../decisions/0008-mermaid-native-preview.md)

- **Phase:** [`docs/plans/phases/mermaid-preview-honesty.md`](../plans/phases/mermaid-preview-honesty.md)
  (M1 complete; M2–M6 add flow layout and sequence lifelines; M7 finalizes)

### Layout engine (M3)

**Purity rule:** `MermaidLayout.swift` imports only Foundation and CoreGraphics.
CoreGraphics is a system framework with no SwiftUI dependency, and its types
(CGRect, CGPoint, CGSize) are already `Sendable`. This purity rule ensures domain
layout code is reusable and testable away from UI, and M4's SwiftUI Canvas consumes
`MermaidFlowLayout`/`MermaidSequenceLayout` with zero conversion overhead.

**Algorithm summary:** Flow layout is rank-based (longest-path DAG + iterative-DFS
back-edge detection). Cycles are broken for ranking; back edges are marked
`isFeedback` and kept for routing. Self-loops are excluded from ranking adjacency
(preventing infinite loop) and routed as a right-side bulge. Isolated and
multi-component nodes default to rank 0. In-rank ordering uses barycenter-lite
heuristics with first-seen tiebreak. Coordinates are assigned direction-aware
(TD/BT/LR/RL). Subgraph bounds are computed bottom-up (children recursed first,
parent unions child frames + member rects, respecting the fact that the parser
lists each node only in its innermost subgraph; parents are emitted pre-order).
Edge routing uses generic rect-boundary intersection toward the opposite node center.

**Determinism rule:** Node ordering is never derived from raw Dictionary iteration.
Seed order for in-rank barycenter is first-appearance order across edges, then
remaining node IDs sorted lexicographically. This ensures identical layout output
for identical input across runs and platforms.

**Caching and lifecycle:** Layout is a pure, one-shot function (`layout(_:)` → 
`MermaidFlowLayout` or `MermaidSequenceLayout`) that M4 caches at the segment level.
It is never computed per-frame inside a SwiftUI Canvas closure; recomputation happens
only when the parsed model changes. This preserves the typing-path frame budget and
decouples layout cost from rendering frequency.

**Testing policy:** `MermaidLayoutTests.swift` asserts topology and frame invariants
(ranks, ordering determinism/contiguity, subgraph containment + nesting, node
no-overlap, cyclic-terminates-with-feedback, self-loop routing, direction-axis
correctness, empty graph, disconnected components, sequence ordering/identity).
**No pixel snapshots** — visual quality is asserted at M4/M6 render time via
`--verify`, not at layout time.

**Known limitation (intentional):** Sibling subgraph boxes are not guaranteed
disjoint; only "member node frame ⊆ own subgraph frame" and "child frame ⊆ parent
frame" hold. `canvasSize` is intentionally unbounded to support dense and wide
diagrams without forced scaling.

### Flow renderer (M4)

**Canvas layout computation pattern:** A `Canvas`-based diagram must compute
its layout **outside `body` and outside the `Canvas` draw closure**. The pattern
used in `MermaidFlowCanvas` is a child view holding `@State private var layout: MermaidFlowLayout?`,
populated via `.task(id: flow.raw)`. The diagram's stable `raw` string (not
`Equatable` itself on `MermaidFlow`) is the cache key. This ensures the pure
one-shot layout computation runs once per unique diagram source and never
per-frame or per-view-init.

**Why it matters:** Ties to AGENTS invariant: layout is computed outside body,
never per-frame in a Canvas closure. An init-computed `let` would recompute
on every SwiftUI view re-initialization even with stable input. A `.task`-driven
`@State` decouples layout cost from render frequency and satisfies the
typing-path frame budget.

**Accessibility and motion:** The `Canvas` is opaque to VoiceOver, so it
carries an explicit accessibility label (e.g., node/edge counts). The render
is static (no animation), trivially satisfying Reduce Motion.

### Sequence model contract (M5)

**Events-stream design:** `MermaidSequence.events` is an ordered `[Event]` stream where
each `Event` is tagged (`.message`, `.note`, `.blockStart`, `.blockDivider`, `.blockEnd`,
`.activate`, `.deactivate`). Block frames must span the contiguous range of their nested
content in this stream — a multi-line `alt` block's start, its dividers, and its end are
adjacent in sequence order. This ordered stream walked with a block-id stack is the natural
input to M6 geometry (lifelines, block boxes, time-ordering). `messages: [String]` is
**derived** from the events stream in document order (including block-nested messages),
preserving a single source of truth for order and identity.

**Activation semantics:** Activations are modeled as separate `.activate(from:UUID)` and
`.deactivate(to:UUID)` events. When a message carries a `+` suffix, `message.activatesTarget`
is `True`, and a corresponding `.activate(to:)` event is added to the stream. When a message
carries a `-` suffix, `message.deactivatesSource` is `True`, and a corresponding
`.deactivate(from:)` event is added. Semantics: `+` activates the receiver; `-` deactivates
the sender. Durable `UUID` on each message ensures unique identity for repeated/similar messages.

**Participant identity and aliases:** In `participant X as Y` or `actor X as Y`, the LEFT token
`X` is the canonical identity and appears in `participants: [String]` and all message `from`/`to`
fields. The RIGHT token `Y` (alias) is stored in `participantDisplay: [String: String]`
where `participantDisplay[X] == Y`. M6 rendering uses `participantDisplay` for the human-readable
name while using `X` (the identity) for lifeline layout and event routing. This matches Mermaid
semantics and is a reusable rule for any diagram type with named participants. `participantKinds:
[String: ParticipantKind]` (participant vs actor) is keyed by the same identity `X`.

**Block balancing and nesting:** `alt`/`opt`/`loop`/`par` blocks establish nested scope via
a block-id stack during parsing. The parser emits `.blockStart(Block)`, then child events,
then `.blockDivider(Block, kind)` for each `else`/`and` divider, then `.blockEnd(UUID)`.
If an `end` is missing, the parser synthesizes a `.blockEnd` before EOF or when closing the
next scope. Stray `end` lines (closing a non-open block) are ignored. This ensures well-formed
block nesting in the event stream, required for M6 geometry.

**M3 layout compatibility:** `participants` (identity list, document order) and `messages`
(flat derived list, document order including nested) are kept populated so the M3 helper
`MermaidLayoutEngine.layout(_ sequence:)` and its tests remain byte-compatible. No changes
to `MermaidLayout.swift` or `MermaidLayoutTests.swift` are needed for M5.

**Known M5 limitation:** Non-`>` message arrows (`-x`, `--x`, `-)`) are not yet modeled;
these parse as notes or edge cases and are ignored. Only solid (`-->`), dotted (`-.->`,
`-..->`, `-.-`), and identity arrows are supported. Full arrow support deferred.

### Sequence renderer and geometry (M6)

**Event stream geometry coupling:** `MermaidSequenceLayout.layout(_ sequence:)` walks
`sequence.events` (the ordered `[Event]` stream from M5) rather than the flat
`messages` list. Block frame y-range, activation nesting, and note placement are
derived from the event stream's ordering. This couples geometry to the M5 parser's
decisions about where `.activate`/`.deactivate` synthetic events sit relative to
their triggering `.message`. A future change to M5's event ordering will change
geometry directly — the layout engine has no independent ordering logic.

**Actor glyph determinism:** Actors are rendered using a deterministic hand-drawn
stick-figure `Path` (traced in `textSecondary` color), not `Image(systemName:)`.
This choice avoids SF-Symbol-in-`Canvas` rendering uncertainty (alignment, scaling,
antialiasing variance across runs). Actors are distinguished by glyph + label;
color is never used alone to distinguish participant kind (no-color-alone invariant).

**Shared layout engine instance:** `MermaidSequenceCanvas` holds a single `@State`
cache of `MermaidLayoutEngine.layout(_ sequence:)` result, keyed by `sequence.raw`.
Both the `.task` (which computes and caches the layout) and the render closure (which
reads `metrics` for activation-bar x-offsets and self-loop geometry) share this
instance. The drawn geometry can never drift from the metrics because there is
exactly one engine instance and one layout compute per unique diagram source.

**Additive extension rule:** `MermaidSequenceLayout` was extended additively
(new fields added to existing types; old initializers not called). This preserved
byte-compatibility with M3 test fixtures: they only read the model, never call
initializers, and their empty-event fixtures yield empty activations/blocks/notes
arrays without needing new initialization code.

**Canvas layout pattern (M6 reaffirms M4 rule):** Layout is computed **outside
`body` and outside the `Canvas` draw closure**, cached at the segment level via
`.task(id: seq.raw)`, and never recomputed per-frame or on SwiftUI re-initialization.
This satisfies the typing-path frame budget (AGENTS invariant).

**Fixture policy (M6 reaffirms M3 rule):** `MermaidLayoutTests.swift` asserts
topology and frame invariants only — activation ordering, block containment,
note placement, arrow fidelity. **No pixel snapshots** — visual quality is asserted
at render time via `./script/build_and_run.sh --verify`, not at layout time.

### Supported-subset contract (M1–M6 closed)

The native Mermaid preview renders a **bounded supported subset**, making its
bounds explicit and testable:

- **Flowchart/Graph:** Both `flowchart` and `graph` syntaxes; all seven node
  shapes; edge line styles (solid/dotted/thick) and heads (arrow/circle/cross,
  bidirectional); inline and piped labels; chained-edge expansion; nested
  subgraph nesting/containment; `TD`/`LR`/`BT`/`RL` direction; frontmatter/
  comment skipping; real 2D rank-based layout; direction-aware coordinates;
  edge routing with back-edge detection for cycles.
- **Sequence Diagram:** Participants and actors; time-ordered messages with
  styled arrows (solid/dotted) and activations; `+`/`-` activation semantics
  on messages; `alt`/`opt`/`loop`/`par` control-flow blocks with `else`/`and`
  dividers; notes (`over`/`leftOf`/`rightOf`); participant aliases; real 2D
  lifeline geometry with activation bars, block frames, and time-ordered event
  stream.

Everything outside this subset — `classDiagram`, `pie`, `gantt`, `stateDiagram`,
`erDiagram`, `gitGraph`, `mindmap`, `timeline`, and 21 others — renders as the
**source code block plus a "diagram type not supported in native preview" notice**,
never a web view, never a blank box, never a broken diagram. Malformed Mermaid
(empty header, parse error) likewise falls back, with the parse reason appended
to the notice.

Every native flow or sequence render carries a **"Simplified native preview"
badge**, communicating that layout is native and bounded, not mermaid.js parity.

### Known limitations (M1–M6)

1. **Per-subgraph direction:** Recognized in parse but not modeled per scope —
   all edges within subgraphs use the root-level direction (M2 limitation).
2. **Dotted/thick inline mid-labels:** `A-. label .--> B` and `A== label ==> B`
   tokenized correctly but the label is not extracted; only solid `-- label --`
   inline and `|piped|` labels captured (M2 limitation).
3. **Non-`>` sequence arrows:** `-x`, `--x`, `-)`, and non-arrow endings still
   ignored; only `>` arrows (`-->`, dotted/dashed) and identity modeled (M5
   limitation).
4. **Sibling subgraph overlap:** Sibling subgraph boxes not guaranteed disjoint;
   only "member node frame ⊆ own subgraph frame" and "child frame ⊆ parent
   frame" hold (M3 design choice, not a defect).
5. **Unbounded canvas:** `canvasSize` intentionally unbounded to support dense/
   wide diagrams; horizontal scroll for diagrams exceeding viewport (M3 design
   choice).
6. **Note over undeclared participant:** Renders at left margin without crash
   (M6 known condition).
7. **Layout parity:** Layout quality is "good for common diagrams," not
   mermaid.js parity. Tests assert topology/frame invariants only, not pixels.
   The badge and ADR 0008 say so explicitly.

### Fixture policy (M1–M6)

`MermaidLayoutTests.swift` and `MermaidParserTests.swift` assert **topology
and frame invariants only**:

- **Parser fixtures:** Classifier routes (supported/unsupported/malformed);
  header detection with frontmatter/comments; node/edge/subgraph structure
  (order-independent where determinism allows); durable `UUID` identity on
  repeated rows; nested block balancing; participant aliasing; message
  activation semantics.
- **Layout fixtures:** Rank assignment and determinism; in-rank ordering
  contiguity; subgraph containment/nesting; node no-overlap; cyclic-terminates-
  with-feedback; self-loop routing; direction-axis correctness; empty graph;
  disconnected components; sequence lifeline ordering; activation depth/nesting;
  block frame containment; note placement; edge routing bounds.

**No pixel snapshots.** Visual rendering quality is asserted at segment/render
time via `./script/build_and_run.sh --verify` (process-level app launch + deep
GUI inspection), not at layout-unit time. This preserves test determinism and
decouples rendering quality from test brittleness.
