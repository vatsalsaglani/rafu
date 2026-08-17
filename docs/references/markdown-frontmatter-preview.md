# Markdown metadata preview

- Applies to: Markdown preview segmentation and the native metadata card in
  `MarkdownPreviewView`.
- Last verified: Swift 6.2, macOS 15+, 2026-08-17.

## Rule or observed behavior

Markdown documents are scanned only when their first line is `---` with
optional trailing whitespace. The next line that is exactly `---` or `...`
closes the block. A UTF-8 BOM is ignored for this line-one check, and CRLF is
tolerated. A missing closer returns no scan, so the document keeps the normal
MarkdownUI path.

The scanner supports a small, dependency-free grammar:

- `key: value` scalars, including one matched pair of single or double quotes;
- flat block lists (`key:` followed by indented `- item` lines);
- flow lists (`[a, b, c]`), with trimming and one quote-pair removal;
- folded (`>`, `>-`, `>+`) and literal (`|`, `|-`, `|+`) block scalars;
- blank and `#` comment lines inside the block are skipped.

Keys must start in column zero. Tabs used for indentation, nested maps,
anchors, aliases, tags, and other unsupported shapes make the complete block
an honest raw fallback. Parsed rows are never mixed with raw lines. Empty
blocks are consumed but do not create a card. The body after the closing fence
is passed to MarkdownUI without rewriting.

The scanner records each line's separator before parsing. This is required for
CRLF input because Swift's `String` treats a CRLF pair as one grapheme cluster;
generic character splitting can therefore lose the line boundary. The line
records preserve the original separators when rebuilding the raw block and
the MarkdownUI remainder.

## Why it matters

MarkdownUI interprets the closing fence in an unprocessed metadata block as a
setext-heading underline. The native card gives the document title and
description a clear header, presents the remaining fields as a compact typed
ledger, and keeps unsupported input visibly verbatim instead of pretending to
understand it.

The card copies only the block contents, without fence lines, and has an
ephemeral per-view collapse state. Its shell follows
`RafuMarkdownCodeBlockCard`: `cardBackground`, a `borderSubtle` outline, and a
continuous `radiusPanel` clip. Card chrome and text use `theme.palette` tokens.
Color-like values add a data swatch, while their text remains visible as the
meaningful label.

User-visible help and accessibility wording calls the block “metadata”. The
implementation must not expose the internal format name in rendered UI,
tooltips, or accessibility labels.

## Reproduction or evidence

The strict scanner and segment integration are covered by
`Tests/RafuAppTests/MarkdownFrontmatterTests.swift`, including BOM/CRLF input,
thematic-break false positives, unclosed fences, list and block-scalar values,
the advisor fixture, raw fallback text, byte-identical body remainder, and
Markdown/Mermaid segment order.

## Verification

- `./script/format.sh --fix`
- `./script/format.sh --lint`
- `./script/build.sh`
- `./script/test.sh`
- `./script/build_and_run.sh --verify`

The final GUI checklist remains a manual check: expanded and collapsed card
states, mouse and Full Keyboard Access, copy behavior, independent second
window state, thematic breaks later in a document, and the split-view live
buffer update.

## Related code, ADRs, and phases

- `Sources/RafuApp/Markdown/MarkdownFrontmatter.swift`
- `Sources/RafuApp/Markdown/MarkdownFrontmatterCard.swift`
- `Sources/RafuApp/Markdown/MarkdownPreviewView.swift`
- `docs/plans/phases/markdown-frontmatter-preview.md`
- `RafuMarkdownCodeBlockCard` in
  `Sources/RafuApp/Markdown/RafuMarkdownStyling.swift`
