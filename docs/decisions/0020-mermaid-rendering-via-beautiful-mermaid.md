# ADR 0020: Mermaid rendering via `beautiful-mermaid-swift`, superseding the hand-written engine

- **Status:** Accepted
- **Date:** 2026-07-25
- **Supersedes:** [ADR 0008](0008-mermaid-native-preview.md)

## Context

ADR 0008 committed Rafu to a **hand-written** bounded Mermaid renderer with an
honest fallback, explicitly ruling out a JavaScript engine, a `WKWebView`, and
**any new package dependency**. Milestones M1–M6 delivered that: a first-token
classifier, flow and sequence parsers, a rank-based layout engine, and two
SwiftUI `Canvas` painters — roughly 2,150 lines across
`MarkdownModels.swift`, `MermaidLayout.swift`, and `MermaidDiagramView.swift`.

In use, the result did not hold up. Reported from the app, with screenshots:

1. `style` directives were parsed as **phantom nodes** and drawn as boxes
   containing the literal text `style G6 fill:#fef9c3,...`.
2. Subgraph labels kept their surrounding quotes (`"Human"`).
3. `<br/>` and `<i>` were printed literally inside node labels.
4. Real diagrams produced heavily crossing edges — the rank-based
   longest-path plus barycentre-lite ordering is not competitive with a proper
   layout engine on graphs with subgraphs and back edges.
5. `stateDiagram` and 28 other types fell to the code-block fallback. The
   fallback was honest, but the supported set (2 types) was too narrow to be
   useful for architecture documentation — the primary in-repo use case.

Items 1–3 are cheap parser bugs. Item 4 is not: competitive graph layout is a
research-grade problem and was never in scope for a repository companion.

`lukilabs/beautiful-mermaid-swift` (MIT) renders Mermaid natively — no
`WKWebView`, no JavaScriptCore — using `lukilabs/elk-swift`, a Swift port of
the Eclipse Layout Kernel. It supports six diagram types.

A spike (`swift build` + 13 fixtures × both bundled themes, plus two targeted
probes against the 1.0.4 checkout) established the facts this decision rests
on. They are recorded in
[`mermaid-native-preview.md`](../references/mermaid-native-preview.md).

## Decision

**Adopt `beautiful-mermaid-swift` 1.0.4 and `elk-swift` 1.0.2 (both MIT, both
pinned `exact:`) for Mermaid parsing, layout, and rasterisation. Delete the
first-party parser, layout engine, and Canvas painters.**

This **reverses ADR 0008's "no new package dependency" clause**. Everything
else in ADR 0008 survives and is restated below as a binding constraint.

### What survives from ADR 0008

- **The honest-fallback contract.** Unsupported or unrenderable Mermaid shows
  the raw source in a monospaced block plus a reason notice. Never a blank box,
  never a wrong diagram.
- **Rafu owns classification and every user-facing string.** The dependency's
  error text is never reachable from the UI (see "Error text" below).
- **No JavaScript engine and no `WKWebView`.** ADR 0008's deferral of a lazy
  shared web view stands, and is now less likely to be reopened.
- **A badge on every native render**, so output is never mistaken for
  mermaid.js parity.
- **No pixel snapshots in tests.**

### What changes

- Supported types: **2 → 6** — `flowchart`/`graph`, `sequenceDiagram`,
  `stateDiagram(-v2)`, `classDiagram`, `erDiagram`, `xychart(-beta)`. All four
  new types are enabled immediately; the fallback still catches throws, so
  gating them would add a settings surface for no safety gain.
- `MermaidParseResult` becomes a **routing enum with no per-diagram model**.
  `MermaidFlow`, `MermaidSequence`, and their durable edge/message `UUID`
  identity are deleted. Nothing outside the Markdown preview consumed them.
- Layout and rendering are third-party, confined behind a **two-file
  boundary**: `import BeautifulMermaid` may appear only in
  `Sources/RafuApp/Markdown/MermaidTheme.swift` and
  `Sources/RafuApp/Markdown/MermaidRenderService.swift`. No package type may
  appear in `MarkdownModels.swift`, `MermaidDiagramView.swift`, or any test
  signature. This, not a separate SwiftPM target, is the replaceability
  guarantee — consistent with how `SwiftTerm` and `MarkdownUI` are confined.
- The badge reads **"Native Mermaid preview"** (was "Simplified native
  preview"), with help text naming the bounded subset. ELK output is close
  enough to parity that "simplified" now understates it, but the accepted
  regressions below are real and a badge must keep saying so.

### Isolation — forced by two upstream facts

Neither of these is a preference; both were established by compiling and
reading the 1.0.4 source.

1. **`PreparedDiagram` is not `Sendable`** — a `public struct` holding a
   `(CGContext, CGRect) -> Void`. Handing it across an actor boundary is a
   **hard compile error** under `swiftLanguageModes: [.v6]`, not a warning.
   Therefore prepare and render must occur in the same isolation domain, and
   an `actor` owns them. Only a `CGImage` (verified `Sendable`) crosses back.
2. **`LabelRenderer` hijacks the ambient `NSGraphicsContext`.** If
   `NSGraphicsContext.current` is already set — exactly the case inside
   `NSView.draw(_:)` — it draws text through *that* context with *its*
   flippedness, ignoring the `CGContext` passed to it. Therefore Rafu
   rasterises **only into its own offscreen bitmap context**, where `current`
   is nil, and never draws into a view-owned context. This forbids a future
   "optimise by drawing straight into the view" change.

Consequently `MermaidRenderService` is an actor, with a layout cache keyed by
**normalised source alone** — layout is theme-independent (verified: identical
geometry across both bundled themes for all 13 fixtures), so a theme or
appearance switch re-rasterises without re-laying-out. `DiagramTheme` is
`@unchecked Sendable` upstream; Rafu never shares one, crossing a `Sendable`
`MermaidThemeSpec` and constructing `DiagramTheme` inside the actor.

**The actor does not use `prepare(from:)` or hold a `PreparedDiagram` at all.**
It calls the lower-level `MermaidParser.parse` → `GraphLayout.layout` →
`DiagramRenderer.render` path directly and caches only the resulting
`PositionedGraph`, which the package declares `Sendable`. This was found during
implementation and is a correctness fix, not a style preference: a
`PreparedDiagram` captures its `DiagramRenderer` — and therefore the
`DiagramTheme` live at prepare time — inside its render closure. Caching one
keyed by source would have made theme switches silently fail to restyle,
defeating the theme-independent cache this design exists to enable. A fresh
`DiagramRenderer` is constructed per render instead.

### Rejected: the package's own SwiftUI view

`MermaidDiagramView` / `MermaidView` / `MermaidLayer` are not used, because
`MermaidLayer` runs parse **and layout synchronously inside a property
`didSet`** — main-thread CPU work on the SwiftUI path, violating the
typing-path frame budget and the "CPU-heavy work isolated away from the main
actor" invariant. It also aspect-fit-scales the diagram to the view bounds
(wrong for a Markdown preview, which wants natural size plus horizontal
scroll) and paints an opaque background.

### The macOS flip bug

`MermaidImageRenderer.renderImage(from:)` is **broken on macOS in 1.0.4**. Its
UIKit branch uses `UIGraphicsImageRenderer` (origin already top-left); its
AppKit branch builds a raw bottom-left-origin `CGContext` and never flips the
CTM. Every macOS raster comes out vertically mirrored. Their `MermaidView.draw`
flips correctly — only the image path forgot.

Rafu carries a local workaround (`translateBy(x: 0, y: bounds.height)` then
`scaleBy(x: 1, y: -1)`) pending an upstream fix, and a canary test that fails
loudly if upstream fixes it — which is precisely when the workaround must be
revisited.

### Error text

`_ParserEntryError` is `private` and not `LocalizedError`.
`String(describing:)` yields `invalidHeader("gantt")`;
`localizedDescription` yields
`The operation couldn't be completed. (BeautifulMermaid.(unknown context at $100963d74)._ParserEntryError error 0.)`.
**Neither may ever reach a user-visible string.** Rafu authors every reason
from a fixed, tested set.

### Memory caps

Rasters are a new resident cost — one 1258×1414 pt diagram at 2× is ~28 MB
against a ~150 MB idle target. Caps, recorded in
[`memory-caps-and-pressure.md`](../references/memory-caps-and-pressure.md):

| Cap | Value | Behaviour on breach |
|---|---|---|
| Raster pixels per diagram | 4 M px (~16 MB) | back off `scale` toward 1.0 |
| Diagram point area | 4 M pt² (~2000×2000 pt) | honest fallback, "too large to render natively" |
| Layout cache entries | 24, LRU | bounded `PreparedDiagram` retention |

These are **proposals, not measurements.** Revisit against a Release idle pass.

## Alternatives considered

- **Fix our own parser bugs, keep our layout.** Cheap for items 1–3 and
  useless for item 4, which is the one that made diagrams unreadable. It also
  leaves the supported set at 2 types.
- **`swift-mermaid`** (Australware) — pure Swift, no WebKit, but far less
  established. Not evaluated in depth.
- **A lazy shared `WKWebView` running mermaid.js.** Full parity, but ADR 0008
  deferred it on memory and native-interaction grounds and that reasoning is
  unchanged. Adopting a native package makes reopening it unlikely.
- **A separate `RafuMermaid` SwiftPM target.** Would need `RafuTheme`, which
  lives in `RafuApp/Support/`, forcing a type move or a duplicated spec for no
  isolation gain over the two-file rule.

## Consequences

### Gains

- Orthogonal ELK routing with no crossings and correct subgraph containment.
- Four new diagram types.
- `<br/>` honoured; `style`/`classDef` silently ignored instead of drawn as
  phantom nodes; subgraph label quotes stripped; dotted and thick inline
  mid-labels now extracted, closing a known M2 limitation.
- ~2,150 lines of first-party parser, layout, and renderer deleted.

### Accepted regressions

These are the price of the trade and must stay documented:

- **`--o`, `--x`, `o--o`, `x--x` edges are silently dropped.** They are absent
  from the upstream arrow regex, and the *entire statement* is swallowed — the
  target node never appears. This is the one regression that sits uneasily
  against the honesty contract; it is accepted for this landing and recorded as
  a follow-up (normalising these spellings to `-->`/`<-->` would trade
  arrowhead shape for edge existence, but needs bracket-aware rewriting).
- `A[/label/]` (parallelogram) renders as a rectangle with a literal
  `/label/`. Upstream's spelling is `A[/label\]`.
- No per-diagram parsed model, hence no unit-testable edge or message identity.
- Visual fidelity now depends on an upstream we do not control.
- Cosmetic: sequence `par`/`alt` block labels can overlap the nearest lifeline;
  `Note over` boxes can overlap an enclosing block edge; long edge labels drift
  from their edge in dense flowcharts.

### Compensating work Rafu must carry

Upstream requires `flowchart TD`-style headers with an explicit direction and
does not skip YAML frontmatter — bare `flowchart`, bare `graph`, and
frontmatter diagrams all **throw**, and all three work today. Rafu normalises
the source before handing it over, reusing the existing header-locating logic
that skips blank lines, frontmatter, and `%%` comments.

### Revisit trigger

- Upstream fixes the macOS flip bug (the canary test fails) — remove the
  workaround.
- Upstream adds `--o`/`--x` arrow support — drop that regression from the docs.
- A measured Release idle pass contradicts the proposed caps.
- The package goes unmaintained: the two-file boundary is what makes a swap or
  a fork tractable.

## Related

- Supersedes: [ADR 0008](0008-mermaid-native-preview.md)
- Reference: [`mermaid-native-preview.md`](../references/mermaid-native-preview.md)
- Reference: [`editor-dependencies.md`](../references/editor-dependencies.md)
- Reference: [`memory-caps-and-pressure.md`](../references/memory-caps-and-pressure.md)
- Plan: [`mermaid-preview-honesty.md`](../plans/phases/mermaid-preview-honesty.md)
  (M1–M6 superseded by this ADR)
- Precedent for file-level dependency confinement: ADR 0004 (SwiftTerm)
