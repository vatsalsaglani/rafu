# ADR 0008: Bounded native Mermaid preview with honest fallback

- **Status:** Proposed
- **Date:** 2026-07-17

## Context

Mermaid support today is a hand-rolled approximation, not an engine, and it is
dishonest about that:

- Type detection is binary (`MarkdownModels.swift:136`): first line
  `sequenceDiagram` → `.sequence`; **everything else → `.flow`**. There is no
  unsupported branch and no fallback.
- Flowchart parsing handles only four arrow spellings and `|label|` labels;
  direction is parsed then ignored; no subgraphs, shapes, chained edges, or
  grouping.
- Sequence parsing handles participants and one message per line; no
  activations, control-flow blocks, or notes.
- Rendering draws flowcharts as a flat vertical list (topology lost) and
  sequence diagrams as flat rows without lifelines.
- Unsupported types (`classDiagram`, `pie`, `gantt`, `stateDiagram`, ER,
  gitGraph, and others) fall into the `.flow` branch and render blank or
  garbage, silently.

This violates the transparency and predictability principles. Users cannot
distinguish between "Rafu's native Mermaid is narrow but honest" and "something
is broken."

## Decision

Adopt a **bounded native renderer v2 with honest fallback**:

- A well-defined supported subset — `flowchart`, `graph`, and `sequenceDiagram`,
  done properly — with a real native 2D layout.
- Everything outside the subset (or malformed input) renders as the **source
  code block plus a visible "diagram type not supported in native preview"
  notice** — never a blank or wrong diagram.
- Every native diagram render carries a persistent **"Simplified native
  preview" badge**.
- No JavaScript engine, no WKWebView, no new package dependency.

### Result model (option a — one enum)

A new `MermaidParseResult` enum replaces the old combined `MermaidDiagram`/`Kind`:

```
.flow(MermaidFlow)           // typesafe flowchart structure
.sequence(MermaidSequence)   // typesafe sequence structure
.unsupported(type:raw:)      // named unsupported type + source
.malformed(type:raw:reason:) // parse error + source + reason
```

`MermaidFlow` and `MermaidSequence` are nonisolated Sendable value types.
Edges and messages preserve durable per-instance `UUID` identity, never content
hashes or array offsets.

This choice (option a) keeps the enum and its call sites frozen across M2–M6
while the payload structs grow new fields for layout and rendering.

### Deferred alternative: lazy shared WKWebView

A single shared lazy `WKWebView` rendering `mermaid.js` to images was
considered (precedent: ADR 0004's lazy/bounded terminal). It conflicts with
the spirit of the native-preview invariant (native interaction, predictable
memory, explicit user control) and would pressure the idle-memory budget.
It is **deferred**. Reopening it requires:

- Its own ADR decision (this one closes the question for M1–M7).
- A measured lazy-webview memory pass (cold start, idle, with multiple
  diagrams).
- Explicit user product direction that the mermaid.js rendering quality is worth
  the memory and complexity trade-off.

## Consequences

- The `MermaidParseResult` enum and the first-token classifier become
  permanent interfaces. The classifier recognizes:
  - `flowchart` and `graph` (both syntaxes) → flow
  - `sequenceDiagram` → sequence
  - A known-unsupported set (29 types from current Mermaid docs) → unsupported
  - Unknown or empty headers → malformed
  - Case-insensitive matching for the header key.
- Type detection is now honest: unsupported types do not render as broken
  flow diagrams; malformed input shows the reason, not a blank box.
- Layout quality is "good for common diagrams," not mermaid.js parity. The
  badge and this ADR say so explicitly. Tests assert topology/frame invariants,
  not pixels.
- The frontmatter/comment-skipping logic in M1 applies only to the classifier.
  Body parsing is not yet upgraded; M2–M5 rewrite the body parsers and will
  handle nested comments/frontmatter in context. This is not a regression — the
  prior behavior matched it.
- Memory budget is preserved: no resident web process, no image caching, no
  new dependency.

## Related

- Plan: [`docs/plans/phases/mermaid-preview-honesty.md`](../plans/phases/mermaid-preview-honesty.md)
- Reference: [`docs/references/mermaid-native-preview.md`](../references/mermaid-native-preview.md)
- ADR 0004: [`0004-embedded-terminal.md`](0004-embedded-terminal.md) (precedent for lazy/bounded approach)
