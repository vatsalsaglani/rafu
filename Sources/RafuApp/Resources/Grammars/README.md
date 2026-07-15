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
| `Markdown/`   | `tree-sitter-markdown`                        | verbatim (block grammar; inline queries deferred to increment 9) |
| `Dockerfile/` | `tree-sitter-dockerfile`                      | verbatim |

`markdownInline` is not vendored here yet — the Markdown inline-injection path
remains deferred.

`#match?` / `#eq?` predicates in these `highlights.scm` files compile but are
not evaluated by the plain `QueryCursor.highlights()` path used for syntax
highlighting; captures gated only by a predicate are applied unconditionally.
This is an accepted limitation of that path (it is not shared by `tags.scm`
below).

## Symbol-extraction queries (`tags.scm`, increment 9)

`tags.scm` files back the command palette's `@` symbol mode
(`BufferSymbols.scanUsingGrammar`) and are vendored only for grammars with a
meaningful `@definition.*`/`@name` capture set. Unlike `highlights.scm`
above, these ARE evaluated with predicates: `scanUsingGrammar` uses
`ResolvingQueryCursor`/`Predicate.Context` so `#not-eq?`/`#not-match?`
directives (e.g. JavaScript/TypeScript's constructor and `require()`
exclusions) are honored, not applied unconditionally.

| Directory     | Source grammar package                                         | Notes |
| ------------- | ---------------------------------------------------------------| ----- |
| `Swift/`      | `tree-sitter-swift`                                             | verbatim |
| `Python/`     | `tree-sitter-python`                                             | verbatim |
| `JavaScript/` | `tree-sitter-javascript`                                         | verbatim |
| `TypeScript/` | `tree-sitter-javascript` + `tree-sitter-typescript`               | combined, same pattern as `highlights.scm`; compiled against the TypeScript grammar |
| `TSX/`        | `tree-sitter-javascript` + `tree-sitter-typescript`               | same combined content as `TypeScript/tags.scm`, compiled against the TSX grammar (both come from the `tree-sitter-typescript` checkout, which ships one shared `queries/tags.scm` delta for both grammars) |

JSON, YAML, TOML, Bash, Markdown, and Dockerfile have no vendored `tags.scm`
— their upstream grammar packages ship none with meaningful
`@definition.*` captures for those languages, so `@` symbol mode falls back
to the regex `BufferSymbolScanner` for files in those languages. `tagsQuery(
for:)` on `GrammarRegistry` returns `nil` for them (see
`GrammarRegistryTests`).
