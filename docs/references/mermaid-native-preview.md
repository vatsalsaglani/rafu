# Mermaid native preview — honest detection and fallback

- **Applies to:** Mermaid diagram parsing, classification, and rendering in
  `MarkdownModels.swift`, `MarkdownPreviewView.swift`, and `MarkdownPreviewSegmentParser`
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
    `MermaidUnsupportedView`, badge rendering
  - `Sources/RafuApp/Markdown/MarkdownPreviewSegmentParser.swift` — segment parsing

- **Tests:**
  - `Tests/RafuAppTests/MermaidParserTests.swift` — classifier and fallback fixtures
  - `Tests/RafuAppTests/MarkdownParserTests.swift` — existing smoke tests (updated for result shape)

- **ADR:** [`0008-mermaid-native-preview.md`](../decisions/0008-mermaid-native-preview.md)

- **Phase:** [`docs/plans/phases/mermaid-preview-honesty.md`](../plans/phases/mermaid-preview-honesty.md)
  (M1 complete; M2–M6 add flow layout and sequence lifelines; M7 finalizes)

**Sections to be filled in M3/M7:**
- Layout algorithm and frame-invariant testing (M3).
- Fixture policy (M7 close-out).
