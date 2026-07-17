# Vendored tree-sitter highlight queries

These `highlights.scm` files are copied verbatim from the tree-sitter grammar
packages pinned in `Package.swift` (lane-1 increment 8a). They are vendored
into the app target so `Bundle.module` can resolve them under `swift test`,
`swift run`, and the staged `.app` — SwiftTreeSitter's
`LanguageConfiguration(_:name:)` bundle resolver looks in
`Bundle.main/<Name>.bundle/Contents/Resources/queries`, which does not exist
for SPM's flat resource bundles, so we load the query bytes directly with
`Query(language:url:)` instead.

## Provenance and licensing

Every source grammar is MIT-licensed (ADR 0005 §7.4, increment 7), which
permits redistribution with attribution. Files were copied from each grammar's
`.build/debug/TreeSitter<Name>_TreeSitter<Name>.bundle/queries/highlights.scm`.

| Directory     | Source grammar package                        | Notes |
| ------------- | --------------------------------------------- | ----- |
| `Swift/`      | `tree-sitter-swift`                           | verbatim |
| `Python/`     | `tree-sitter-python`                          | verbatim |
| `JavaScript/` | `tree-sitter-javascript`                      | `highlights.scm` (base) |
| `TypeScript/` | `tree-sitter-javascript` + `tree-sitter-typescript` | combined: the TS grammar (`inherits: ecma`) ships a thin delta that assumes concatenation with the JavaScript highlights |
| `TSX/`        | `tree-sitter-javascript` (`highlights.scm` + `highlights-jsx.scm`) + `tree-sitter-typescript` | combined, compiled against the TSX grammar |
| `JSON/`       | `tree-sitter-json`                            | verbatim |
| `YAML/`       | `tree-sitter-yaml`                            | verbatim |
| `TOML/`       | `tree-sitter-toml`                            | verbatim |
| `Bash/`       | `tree-sitter-bash`                            | verbatim |
| `Markdown/`   | `tree-sitter-markdown`                        | verbatim (block grammar) |
| `Dockerfile/` | `tree-sitter-dockerfile`                      | verbatim |
| `MarkdownInline/` | `tree-sitter-markdown` (`tree-sitter-markdown-inline` sub-package) | verbatim; injection-only — `GrammarRegistry.markdownInlineInjection()` compiles it against `markdown_inline` and pairs it with a hand-authored locator query (`(inline) @injection.content`, compiled against the block `markdown` grammar) so `SyntaxParsingActor` can substring-parse each `(inline)` node in an open Markdown buffer (symbol-coverage lane increment D) |

`#match?` / `#eq?` predicates in these `highlights.scm` files compile but are
not evaluated by the plain `QueryCursor.highlights()` path used for syntax
highlighting; captures gated only by a predicate are applied unconditionally.
This is an accepted limitation of that path (it is not shared by `tags.scm`
below).

## Symbol-extraction queries (`tags.scm`, increments 9–C)

`tags.scm` files back both the command palette's `@` buffer-symbol mode
(`BufferSymbols.scanUsingGrammar`) and the workspace symbol index's `#` mode
(`WorkspaceSymbolExtractor`). They are vendored only for grammars with a
meaningful `@definition.*`/`@name` capture set. Unlike `highlights.scm`
above, these ARE evaluated with predicates: both extraction paths use
`ResolvingQueryCursor`/`Predicate.Context` so `#not-eq?`/`#not-match?`
directives (e.g. JavaScript/TypeScript's constructor and `require()`
exclusions) are honored, not applied unconditionally.

**JSON deliberately skipped:** JSON has no vendored `tags.scm` — keys are
unbounded structural noise with no navigational payoff (documented in
`docs/references/workspace-symbol-index.md`).

| Directory     | Source grammar package                                         | Notes |
| ------------- | ---------------------------------------------------------------| ----- |
| `Swift/`      | `tree-sitter-swift`                                             | verbatim |
| `Python/`     | `tree-sitter-python`                                             | verbatim |
| `JavaScript/` | `tree-sitter-javascript`                                         | verbatim |
| `TypeScript/` | `tree-sitter-javascript` + `tree-sitter-typescript`               | combined, same pattern as `highlights.scm`; compiled against the TypeScript grammar |
| `TSX/`        | `tree-sitter-javascript` + `tree-sitter-typescript`               | same combined content as `TypeScript/tags.scm`, compiled against the TSX grammar (both come from the `tree-sitter-typescript` checkout, which ships one shared `queries/tags.scm` delta for both grammars) |
| `Bash/`       | `tree-sitter-bash`                                               | hand-authored (not upstream), verified against node-types.json |
| `Dockerfile/` | `tree-sitter-dockerfile`                                         | hand-authored (not upstream), verified against node-types.json |
| `TOML/`       | `tree-sitter-toml`                                               | hand-authored (not upstream), verified against node-types.json; tables/array-of-tables→class, bare-key config pairs under document/table/table_array_element→property, inline_table excluded |
| `YAML/`       | `tree-sitter-yaml`                                               | hand-authored (not upstream), verified against node-types.json; top-level mapping keys→property, anchors→constant; top-level-only achieved by structural document-anchoring |
| `Markdown/`   | `tree-sitter-markdown`                                           | hand-authored (not upstream), verified against node-types.json; headings (atx + setext) → `section`, `#`-index only |

Only JSON and `markdownInline` have no vendored `tags.scm`: JSON's
upstream package ships no meaningful `@definition.*` captures, and
`markdownInline` is an injection-only subgrammar (not a top-level file
format). Both fall back to the regex `BufferSymbolScanner` for `@` mode and
are excluded from the workspace index. `tagsQuery(for:)` on `GrammarRegistry`
returns `nil` for them (see `GrammarRegistryTests` pinned lists).
