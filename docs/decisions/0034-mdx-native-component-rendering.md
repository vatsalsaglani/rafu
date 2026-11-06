# 0034. MDX documents render natively through a declarative component registry

- Status: Accepted (owner direction), 2026-11-06
- Related: [ADR 0019](0019-external-file-opening-and-media-preview.md),
  [ADR 0008](0008-mermaid-native-preview.md),
  [ADR 0020](0020-mermaid-rendering-via-beautiful-mermaid.md)
- Supersedes: nothing. It narrows the "full MDX" reading of ADR 0019's media
  scope.
- Phase: [`../plans/phases/issues-2026-11-06-fanout.md`](../plans/phases/issues-2026-11-06-fanout.md) (G6)
- Reference: [`../references/mdx-preview.md`](../references/mdx-preview.md)

## Context

The owner asked for `.mdx` documents with custom components "like in VPlan".
vplan compiles MDX with `@mdx-js/mdx` and renders it with React 19. Its
components (`Callout`, `Phase`, `Checklist`, `Questions`, `FileTree`, `Svg`,
`Chart`, `Math`, `Matrix`, `Compare`, `Stat`, `DiffCues`, `Mermaid`) are a fixed
set; vplan has no mechanism for user-supplied components. Rafu's own design
documents (`docs/plans/wireframes/workspace-canvas/*.mdx`) use that
vocabulary.

Before this decision, `.mdx` had no grammar mapping and was not a Markdown
document, so it opened as plain text with no preview.

A real MDX runtime compiles JSX to JavaScript and runs it with React. That
needs a `WKWebView` per document or JavaScriptCore plus React. Both conflict
with the architecture invariants (no per-document web view, native Markdown
preview through MarkdownUI, no extension host or plugin runtime), with the
native Mermaid direction of ADR 0008/0020, and with the idle memory budget.

## Decision

`.mdx` is Markdown plus a small component-block grammar. Rafu renders it
natively and runs no JavaScript.

- **Routing.** `.mdx` uses the Markdown grammar for highlighting (component
  tags read as HTML blocks), has no language server, and uses the Markdown
  Edit / Split / Preview presentation in editor tabs and Ensemble file cards.
  No MDX Tree-sitter grammar is added.
- **Grammar.** Top-level `import` / `export` statements are dropped. A block
  starts on a line that begins with `<Name` (upper case first letter) and ends
  at the matching `</Name>` (same-name nesting is counted) or at `/>`.
  Children are Markdown and may hold nested components. Text inside fenced
  code is never scanned for tags. An unterminated or malformed tag stays as
  literal Markdown.
- **Props.** `name="…"`, `name='…'`, bare `name` (true), and `name={…}`.
  A braced value becomes a number, a boolean, or JSON data when it parses as
  such. Any other `{expression}` is kept as literal text and is never
  evaluated. `{expressions}` in body text are shown literally.
- **Components.** Names resolve through a fixed set of native renderers
  (`callout`, `card`, `checklist`, `questions`, `fileTree`, `svg`). Built-in
  entries map the vplan names `Callout`, `Phase`, `Checklist`, `Questions`,
  `FileTree`, and `Svg`. A workspace may add or override entries in
  `.rafu/mdx-components.json`; an entry can only choose a renderer from the
  fixed set. The file is untrusted input: read only, at most 256 KB, invalid
  entries are skipped with a visible warning.
- **Fallback.** An unknown component renders as a quiet bordered block that
  shows `<Name>`, its props, and its children as Markdown. Content is never
  hidden.
- **Images.** `Svg src` resolves against the document directory and loads
  through the shared local Markdown image loader. A remote `src` is named,
  never fetched.
- **No JavaScript and no web view**, ever, for MDX.

## Consequences

- vplan-style plans read well in Rafu without a JavaScript runtime and with
  no new dependency.
- A component inside a list item or a block quote is not at line start and
  renders as literal text.
- Props that need evaluation (computed values, imported data) show as text.
- Ensemble file cards treat `.mdx` as Markdown but parse it without MDX mode;
  component tags there show as text.
- Later work, out of scope for this decision: `Stat`, `Compare` / `Matrix`
  (table), `Chart`, `Math` (currently the fallback), registry prop mapping
  (`"props": { "title": "$name" }`), and MDX mode in Ensemble cards.
  `DiffCues` is not planned.

## Alternatives considered

- **`WKWebView` + `@mdx-js/mdx` + React.** Full fidelity, but a web view per
  document, a bundled JavaScript toolchain, and a code-execution surface for
  workspace content. Rejected by the invariants.
- **JavaScriptCore + React rendering to native views.** No web view, but still
  an embedded JavaScript runtime that executes workspace code. Rejected for
  the same reason as an extension host.
- **Treat `.mdx` as plain Markdown.** Cheap, but import lines and raw tags
  would fill the preview. Rejected as poor for the main use case.
