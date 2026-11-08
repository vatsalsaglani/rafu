# MDX preview

- Applies to: `.mdx` routing, `MDXBlockScanner`, `MDXComponentRegistry`,
  `MDXBlockBuilder`, and `MDXComponentView` under `Sources/RafuApp/Markdown/`.
- Last verified: Swift 6.2, macOS 26, 2026-11-06. The catalog bridge section
  was added 2026-11-08 (Swift 6.4.2, macOS 27); the theme cache part describes
  branch `fix/voice-mic-allow`, not merged when written.

## Rule or observed behavior

`.mdx` is Markdown plus a component-block grammar (ADR 0034). No JavaScript
runs and no web view is created.

Routing:

- `LanguageCatalog.byExtension["mdx"]` maps to the Markdown grammar with no
  LSP id. The Markdown grammar reads `<Callout …>` lines as HTML blocks; there
  is no MDX Tree-sitter grammar.
- `EditorDocument.markdownExtensions` (and so `isMarkdown`, the default
  presentation mode, and image paste) includes `mdx`.
  `CanvasMarkdownCard.isMarkdown(path:)` includes `mdx`.

Segmenting (`MarkdownPreviewSegmentParser.parse(_:mdx:)`): front matter is
lifted first, as for Markdown. Only when `mdx` is non-nil does the MDX scanner
run on the rest; then each Markdown chunk goes through the existing Mermaid
split (`splitMermaid`). Plain Markdown output is unchanged.

Scanner grammar (`MDXBlockScanner`):

- Top-level `import …` / `export …` statements are dropped. The line must look
  like ESM (`import {`, `import X from`, `import "…"`, `export const`, …); prose
  such as "import the file" stays. A statement with an unclosed `{`, `(`, or
  `[` runs to the closing line (at most 200 lines).
- A block starts on a line that begins with `<` and an upper case letter.
  The opening tag may span lines; it is capped at 16 KB.
- `</Name>` closes it; same-name opens inside are counted. `/>` closes a
  self-closing tag. Text after the close on the same line stays Markdown.
- Fenced code (``` or ~~~, up to three spaces of indent, closing fence at
  least as long) is never scanned for tags, at the top level or while
  searching for a close tag.
- Props: `"…"` and `'…'` strings (no escapes, like JSX), bare names (`true`),
  `{…}` read as number, `true` / `false`, or JSON (`JSONSerialization`). Any
  other braced text is `.expression(raw)` and is never evaluated.
- Children are scanned again (depth cap 8). An unterminated block or a
  malformed tag stays as literal Markdown.
- Limits: a component inside a list item or block quote is not at line
  start and stays as text. A `<Name>` inside an inline code span on its own
  line can be miscounted while searching for a close tag.

Registry (`MDXComponentRegistry`):

```json
{ "components": { "Note": { "renderer": "callout" } } }
```

- Renderers: `callout`, `card`, `checklist`, `questions`, `fileTree`, `svg`.
  Built-ins: `Callout`→callout, `Phase`→card, `Checklist`→checklist,
  `Questions`→questions, `FileTree`→fileTree, `Svg`→svg.
- File location: `.rafu/mdx-components.json` in the document's directory or
  the nearest ancestor. The search stops at the first directory with `.git`,
  at the home directory, at `/`, or after 32 levels. The preview view has no
  workspace root, so the repository root is the boundary.
- Untrusted input: read with `FileHandle.read(upToCount: 256 KiB + 1)`; a
  larger file, malformed JSON, an invalid component name, a missing renderer,
  or an unknown renderer each add a warning and are skipped. At most 256
  entries. Warnings show once above the preview.
- The registry is read off the main actor with each disk read of the
  document (`.task(id: url#revision)`) and cached in view state; live
  split-view edits reuse it.

Rendering (`MDXComponentView`):

- `callout`: tone from `type` (`note`, `tip`, `info`, `warning`, `risk`,
  `decision`; aliases in `MDXCalloutTone`). Tone is shown by icon and word as
  well as color.
- `card`: `title` and a `status` badge (`in-progress` → "In progress").
- `checklist`: title, "N of M done" from `- [ ]` / `- [x]` lines; the list
  itself renders through MarkdownUI task lists.
- `questions`: top-level list items are questions, nested items are options.
- `fileTree`: `- add path -- note` rows, nested by indent (2 spaces per
  level).
- `svg`: `src` resolved against the document directory; local files load
  through `LocalFileImageProvider` (bounded decode); a remote `src` is named
  and never fetched.
- Questions and file trees whose children are not a plain list fall back to
  the children as Markdown.
- Unknown names: `MDXFallbackBlock` shows `<Name>`, the props, and the
  children. Nothing is hidden.

### Catalog bridge (2026-11-08, ADR 0034 amendment)

Rendering above now goes through the Rafu json-render catalog
([ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)). The
scanner, the builder grammar and the registry file shape are unchanged.

- `MDXCatalogBridge` (`nonisolated`, pure) turns one resolved `MDXBlock` tree
  into a `Spec`. The bridge runs off the main actor, inside
  `MarkdownPreviewSegmentParser.parse`, when the builder resolves a block.
  `build` then validates the spec against `RafuCatalog.rafu` and stores it in
  `MDXBlock.catalogSpec`. The view never builds a spec in `body`.
- `catalogSpec` is set only on a block that is drawn by itself: a top-level block,
  or a block inside an unbridged fallback. It is nil for a nested block (its
  parent's spec holds it), for a fallback block, and for a block whose spec failed
  validation (one log line with the block id; the view draws `MDXFallbackBlock`).
- New renderer kinds: `stat` and `matrix` (built-ins `Stat`, `Matrix`,
  `Compare`). `.rafu/mdx-components.json` keeps its shape and trust rules.
- `MDXCatalogBlockView` renders `catalogSpec` with `JSONRenderView`, the theme
  from `MDXCatalogTheme.current(theme)`, which reads
  `GeneratedViewThemeCache` (one mapped theme per Rafu theme; the contrast
  report is not measured per render), and `MDXCardStyle`, a `JRCardStyle`
  that keeps the document's card look.
- Unknown names still render `MDXFallbackBlock`: `<Name>`, props, children.
- `Figure` never fetches a remote `src`; it is independent of the remote image
  policy.
- Guard: `Tests/RafuAppTests/MDXWireframeTests.swift` scans, builds and bridges
  fixture copies of `canvas-plan.mdx` and `execution-plan.mdx` and compares each
  block's outline (name, body case, child count, element types) with a
  checked-in outline. It guards the data only. A changed outline needs a human
  look at the rendered preview in Indigo and Khadi and with Increase Contrast.
  `MDXCatalogBridgeTests` checks one case per body, nesting, row caps, and that
  every bridged spec validates.

## Why it matters

A real MDX runtime would need a per-document web view or an embedded
JavaScript engine running workspace code. The scanner and fixed renderer set
keep `.mdx` inside the native Markdown boundary, the memory budget, and the
"no extension host" rule.

## Reproduction or evidence

`Tests/RafuAppTests/MDXPreviewTests.swift` covers single, nested, same-name,
and self-closing blocks; every prop form; import/export stripping; fenced
tags; unterminated blocks; registry defaults, aliases, rejections, size cap,
and ancestor search; derived checklist, question, and file tree rows; `Svg`
source resolution; and routing. Existing Markdown, Mermaid, and front-matter
segment tests run unchanged.

## Verification

- `./script/format.sh --fix`
- `./script/format.sh --lint`
- `./script/build.sh`
- `./script/test.sh`
- `swift test --filter MDX`

Manual: open `docs/plans/wireframes/workspace-canvas/canvas-plan.mdx` and
`execution-plan.mdx` in Preview and Split, check a second window, VoiceOver
labels on callouts, and an invalid `.rafu/mdx-components.json`.

## Related code, ADRs, and phases

- `Sources/RafuApp/Markdown/MDXBlockScanner.swift`
- `Sources/RafuApp/Markdown/MDXComponentRegistry.swift`
- `Sources/RafuApp/Markdown/MDXComponentBlock.swift`
- `Sources/RafuApp/Markdown/MDXComponentView.swift`
- `Sources/RafuApp/Markdown/MarkdownPreviewView.swift`
- `Sources/RafuApp/Markdown/MDXCatalogBridge.swift`,
  `MDXCatalogBlockView.swift`, `Sources/RafuApp/Canvas/GeneratedView/Components/Document/`
- [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)
- [ADR 0034](../decisions/0034-mdx-native-component-rendering.md)
- [`markdown-frontmatter-preview.md`](markdown-frontmatter-preview.md)
- `docs/plans/phases/issues-2026-11-06-fanout.md` (G6)
