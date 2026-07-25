# Mermaid native preview — `beautiful-mermaid-swift` rendering

- **Applies to:** Mermaid diagram parsing, classification, normalization, rasterization, and native rendering in `MarkdownModels.swift`, `MermaidRenderService.swift`, `MermaidTheme.swift`, and `MermaidDiagramView.swift`
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1, `beautiful-mermaid-swift` 1.0.4, `elk-swift` 1.0.2 on 2026-07-25

## Rule or observed behavior

### Classifier contract and supported types

The `MarkdownParser.parseMermaid(_:)` classifier examines the first non-blank, non-YAML-frontmatter, non-`%%` comment line and maps it to one of six **BeautifulMermaid-supported diagram types** or to unsupported/malformed:

**Six supported types:**
- `flowchart` or `graph` (both spellings, case-insensitive) → `MermaidParseResult.diagram(MermaidDiagram)` with `kind: .flowchart`
- `stateDiagram` or `stateDiagram-v2` → `kind: .stateDiagram`
- `sequenceDiagram` → `kind: .sequenceDiagram`
- `classDiagram` → `kind: .classDiagram`
- `erDiagram` → `kind: .erDiagram`
- `xychart` or `xychart-beta` → `kind: .xyChart`

**23 known-unsupported types** (Mermaid v10):
→ `MermaidParseResult.unsupported(type:raw:)`
- `gantt`, `pie`, `journey`, `gitGraph`, `mindmap`, `timeline`, `quadrantChart`, `requirement`, `requirementDiagram`, `C4Context`, `C4Container`, `C4Component`, `C4Dynamic`, `C4Deployment`, `sankey`, `sankey-beta`, `block`, `block-beta`, `packet`, `packet-beta`, `kanban`, `architecture`, `architecture-beta`

**Malformed or unknown:**
→ `MermaidParseResult.malformed(type:raw:reason:)`
- Empty header, unknown type name, or parse error.

The classifier uses the same `headerIndex` helper as the normalizer below, reusing the blank/frontmatter/`%%`-skipping logic.

### Normalization and upstream header regressions

Upstream (`beautiful-mermaid-swift` 1.0.4) has two stricter parsing requirements that Rafu compensates for via `normalizeMermaid(_:)` before passing the source to `MermaidRenderService`:

1. **Bare `flowchart` or `graph` header:** `_parseFlowchart` requires an explicit direction token (TD/LR/BT/RL). A bare `flowchart` or `graph` header (or with a trailing `;`) throws. Rafu normalizes by appending a default `TD` direction: `flowchart` → `flowchart TD`, `graph` → `graph TD`.

2. **YAML frontmatter:** `_parseMermaidEntry` does not skip YAML frontmatter (`---`…`---`). A diagram with frontmatter throws. Rafu normalizes by dropping all lines before the first significant header line (blank/frontmatter/comment-skipped).

Both rewrites preserve `MermaidDiagram.raw` (shown verbatim in the honest fallback); only `source` (the normalized version handed to the parser) changes. A critical test trap: a normalizer draft that only inspected `lines.first` (not using `headerIndex`) still threw on `"\n%% hi\nflowchart\n A --> B"` — hence the `%%`-before-bare-header test in `MermaidParserTests`.

### The macOS flip bug in `beautiful-mermaid-swift` 1.0.4

**Problem:** `MermaidImageRenderer.renderImage(from:)` in the package is broken on macOS. Its UIKit branch uses `UIGraphicsImageRenderer` (origin already top-left), but its AppKit branch builds a raw bottom-left-origin `CGContext` and never flips the CTM. Every macOS raster emerges vertically mirrored (upside-down text, TB graphs running bottom-to-top).

**Why it matters:** The package's own `MermaidView.draw` flips correctly — only the image path forgot.

**Rafu's fix:** `MermaidRenderService.raster(for:theme:scale:)` bypasses the broken `MermaidImageRenderer` entirely. It calls `MermaidParser.parse` → `GraphLayout.layout` → `DiagramRenderer.render` directly, owns the offscreen `CGContext` itself, and applies the fix before rendering:
```swift
context.translateBy(x: 0, y: bounds.height)
context.scaleBy(x: 1, y: -1)
context.translateBy(x: -bounds.minX, y: -bounds.minY)
```
This flip sequence compensates for the bottom-left-origin coordinate system. A canary test `flipPlacesContentInUpperHalf` verifies the fix by checking that the widest-label node appears in the upper half of the raster; it fails loudly if upstream ever fixes the bug (at which point the workaround must be revisited).

### `PreparedDiagram` is not `Sendable`

**The constraint:** `BeautifulMermaid.PreparedDiagram` is a `public struct` holding a `(CGContext, CGRect) -> Void` closure. It is **not** `Sendable`. Under Swift 6 language mode with strict concurrency, handing one across an actor boundary is a hard compile error, not a warning:
```
error: non-Sendable type 'PreparedDiagram?' of nonisolated property 'value' 
cannot be sent to main actor-isolated context
```

**Consequence:** Prepare and render must occur in the same isolation domain. `MermaidRenderService` is an actor; it never constructs or stores a `PreparedDiagram`. Instead, it calls the lower-level `MermaidParser.parse` → `GraphLayout.layout` → `DiagramRenderer.render` path directly, holding only the `PositionedGraph` (verified `Sendable` upstream) internally, and returning only a `CGImage` and `Raster` value type (both `Sendable`) to callers.

### The `NSGraphicsContext` hijack hazard

**The trap:** `LabelRenderer.render` (in the package, line 117–125) sets `NSGraphicsContext.current` only when it is nil. If it is already set — exactly the case when drawing inside `NSView.draw(_:)` — the package draws text through *that* ambient context with *its* flippedness, ignoring the `CGContext` passed to it. This is invisible until text appears in the wrong place or with wrong orientation.

**Why it matters:** Future maintainers might optimize by "drawing straight into the view's `NSGraphicsContext`" — this forbids that change. Rafu must rasterise **only into its own offscreen bitmap context** (via `CGContext(data:width:height:...)` with nil data), where `NSGraphicsContext.current` is nil.

**Verification:** `MermaidRenderService` is never called from inside a view's `.draw` method; it runs on its own actor and produces a raster that the view then displays as a `CGImage`. The rendering path never intersects a live view's `NSGraphicsContext`.

### Cache and theme independence

`MermaidRenderService` holds an LRU cache keyed by **normalised source alone** (`diagram.source` string). The cached entry stores a `PositionedGraph` (the result of layout, which is expensive ELK work).

**Layout is theme-independent:** A spike compared all 13 fixtures laid out with both bundled themes (Indigo and Khadi); the resulting `PositionedGraph` geometry was identical. Therefore, a theme switch or appearance toggle can re-rasterise the diagram (different colors) without re-laying-out (expensive). `DiagramTheme` is `@unchecked Sendable` upstream; Rafu never shares one across actors. Instead, callers pass a `Sendable` `MermaidThemeSpec` (hex color strings), and `MermaidRenderService` constructs the actual `DiagramTheme` inside the actor, once per render call.

**LRU cap:** 24 entries, evicting the least-recently-used on overflow. A "large-but-legal" diagram (60-node flowchart) still rasterises at reduced scale if needed (see "Raster caps" below).

### Error text is never user-visible

`BeautifulMermaid._ParserEntryError` is `private` and not `LocalizedError`. Its error descriptions are unusable:
- `String(describing:)` yields `invalidHeader("gantt")` — device-specific.
- `localizedDescription` yields `The operation couldn't be completed. (BeautifulMermaid.(unknown context at $100963d74)._ParserEntryError error 0.)` — unreadable.

**Rule:** `MermaidRenderService.reason(for:)` maps every `Failure` enum case to a Rafu-authored, user-facing reason from a fixed, tested set (e.g., "this diagram could not be parsed"). Upstream error text never reaches any user-visible string. The mapping is a nonisolated, pure function and is directly unit-testable.

### Improvements over the deleted hand-written engine

- Orthogonal ELK routing with no edge crossings and correct subgraph containment.
- Four new diagram types now supported (stateDiagram, classDiagram, erDiagram, xyChart).
- `<br/>` honoured as a line break in labels.
- `style` and `classDef` directives silently ignored instead of drawn as phantom nodes.
- Subgraph label quotes stripped correctly.
- Dotted and thick inline mid-labels now extracted (closes a known M2 limitation).

### Accepted regressions and honest fallback

These are the documented trade-offs and the reason the "Native Mermaid preview" badge remains on every render:

- **`--o`, `--x`, `o--o`, `x--x` edges silently dropped.** These are absent from the upstream arrow regex. The *entire statement* is swallowed, so the target node never appears. This sits uneasily against the honesty contract. Accepted for this landing; follow-up is to normalise these spellings to `-->` or `<-->` (bracket-aware rewriting).
- **`A[/label/]` (parallelogram) renders as a rectangle with literal `/label/`.** Upstream's spelling is `A[/label\]`.
- **No per-diagram parsed model.** Unlike the deleted hand-written engine, there is no `MermaidFlow`/`MermaidSequence` with durable edge/message `UUID` identity. `MermaidParseResult` is a routing enum only; detailed model lives inside the actor and is never exposed.
- **Visual fidelity depends on an upstream package.** If `beautiful-mermaid-swift` bugs, so does Rafu's rendering. The two-file confinement boundary (imports only in `MermaidTheme.swift` and `MermaidRenderService.swift`) makes replacement or forking tractable.
- **Cosmetic issues:** Sequence `par`/`alt` labels can overlap the nearest lifeline; `Note over` boxes can overlap an enclosing block edge; long edge labels drift from their edge in dense flowcharts. These are not data loss; diagrams remain legible.

**Unsupported and malformed diagrams never render as a blank box or silent mis-render.** They render as the raw source code in a monospaced block plus a visible notice: "diagram type not supported in native preview" or "diagram type not supported in native preview — [reason]" (e.g., "too large to render natively").

### Raster caps and scaling

Rasterisation adds memory cost (a 1258×1414 pt diagram at 2× is ~28 MB). Three caps, recorded in [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md):

| Cap | Value | Behaviour on breach |
|---|---|---|
| Raster pixels per diagram | 4 M px (~16 MB) | back off `scale` toward 1.0 |
| Diagram point area | 4 M pt² (~2000×2000 pt) | honest fallback, "too large to render natively" |
| Layout cache entries | 24, LRU | bounded `PositionedGraph` retention |

**Important caveat:** These are proposals verified against the current test suite and a manual pass of the app GUI, not a measured Release idle-memory pass. Revisit against a real Release idle pass in a later phase.

## Why it matters

A non-native diagram renderer (hand-written with bounded capability) either silently produces wrong output (dishonest, breaks user trust) or honestly falls back to something legible (source code). The honest fallback makes Rafu's feature bounds explicit and unambiguous. The "Native Mermaid preview" badge prevents users from expecting mermaid.js layout parity when they get a bounded native one. The confinement boundary — imports `BeautifulMermaid` only in two files — makes future package replacement, forking, or upstream fix adoption tractable.

## Reproduction and evidence

**Classifier and normalizer tests** (`Tests/RafuAppTests/MermaidParserTests.swift`):
- Each of the six supported types classifies to `.diagram` with the correct `MermaidDiagramKind`.
- Each of the 23 known-unsupported types classifies to `.unsupported`.
- Empty, unknown, and unparseable headers classify to `.malformed`.
- A bare `flowchart` or `graph` header is normalised to add ` TD`.
- YAML frontmatter is dropped from the normalised source but retained in `raw`.
- A `%%` comment line before a bare header still normalises correctly (the trap).
- Case-insensitive type matching.

**Rasterisation tests** (`Tests/RafuAppTests/MermaidRenderServiceTests.swift`):
- Every supported kind rasterises to a positive point size.
- Unsupported sources throw `.notRenderable`, never a partial raster.
- Layout is theme-independent: the same source yields identical point sizes across themes (Indigo/Khadi spike result).
- An oversized diagram is refused before rasterisation (`.tooLarge`).
- A large-but-legal diagram backs its effective scale off, never below 1.0.
- The failure-to-reason mapping never leaks upstream error text (no "parsererror", no "BeautifulMermaid", no "nserror").
- The macOS flip fix places the widest-label node in the upper half of the raster (canary for upstream fix).

**Verification commands:**
```bash
swift build                           # 0 warnings
swift test                            # 1518 tests pass in 62 suites
swift test --filter Mermaid           # 16 tests pass
./script/format.sh --lint             # clean
./script/build_and_run.sh --verify    # exit 0, app process confirmed live
```

**Package.resolved state:**
- `beautiful-mermaid-swift` pinned to 1.0.4 (exact).
- `elk-swift` 1.0.2 pinned by `Package.resolved` (transitive; NOT declared in `Package.swift` per the elk-swift note there).
- `import BeautifulMermaid` appears in exactly two files (`MermaidTheme.swift`, `MermaidRenderService.swift`); verified with `grep -rn "^import BeautifulMermaid"`.

## Related code, ADRs, and phases

- **Code:**
  - `Sources/RafuApp/Markdown/MarkdownModels.swift` — `MermaidDiagram`, `MermaidParseResult`, `normalizeMermaid(_:)`, classifier (`parseMermaid`)
  - `Sources/RafuApp/Markdown/MermaidRenderService.swift` — off-main actor, parse/layout/render pipeline, cache, `Raster` and `Failure` enums, `reason(for:)` mapping
  - `Sources/RafuApp/Markdown/MermaidTheme.swift` — `MermaidThemeSpec` bridge, `RafuMermaidTheme.diagramTheme(_:)` factory
  - `Sources/RafuApp/Markdown/MermaidDiagramView.swift` — routing (`MermaidDiagramView`), raster view, unsupported fallback, badge

- **Tests:**
  - `Tests/RafuAppTests/MermaidParserTests.swift` — classifier and normalizer fixtures
  - `Tests/RafuAppTests/MermaidRenderServiceTests.swift` — rasterisation, scaling, theme independence, error mapping, macOS flip canary

- **ADR:** [`0020-mermaid-rendering-via-beautiful-mermaid.md`](../decisions/0020-mermaid-rendering-via-beautiful-mermaid.md) — decision record with full context, alternatives, and compensating work

- **Dependencies:** [`editor-dependencies.md`](editor-dependencies.md)

- **Memory:** [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md)

- **Phase:** [`docs/plans/phases/mermaid-preview-honesty.md`](../plans/phases/mermaid-preview-honesty.md) (M1–M6 superseded by ADR 0020; preserved as historical record)
