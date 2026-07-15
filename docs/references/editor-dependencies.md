# Editor dependencies

- Applies to: Markdown preview and syntax-highlighting dependencies
- Last verified: Swift 6.2, macOS 15 deployment target, 2026-07-13

## Rule or observed behavior

Dependencies are pinned in `Package.swift` and kept behind Rafu-owned views and
services so they can be replaced without changing workspace state.

- `swift-markdown-ui` 2.4.1 (MIT) renders GitHub-Flavored Markdown, including
  tables, without one web view per document. Rafu supplies theme colors and keeps
  Mermaid fenced blocks in its native diagram renderer.
- `Neon` 0.6.0 (MIT) is the maintained TextKit token-application boundary for
  visible/open buffers. Language grammars remain separately replaceable; do not
  preload or parse the repository.
- Pin `SwiftTreeSitter` to 0.8.0 while using Neon 0.6.0. Neon's `from: 0.8.0`
  constraint admits later API-breaking `0.x` releases; resolving 0.25.0 fails
  under Swift 6.2 because `TreeSitterClient` calls a newly main-actor-isolated
  cursor initializer from nonisolated code.
- `SwiftTerm` 1.14.0 (MIT) provides the embedded terminal (ADR 0004) through
  `LocalProcessTerminalView` (VT100/xterm emulation plus a PTY-backed login
  shell). All SwiftTerm types stay inside `Sources/RafuApp/Terminal/`; the app
  talks only to `WorkspaceTerminalController` / `WorkspaceTerminalPanel`. The
  shell spawns lazily on first panel open, scrollback stays at the bounded
  500-line default, and its delegate callbacks arrive on the main thread
  (bridged with `MainActor.assumeIsolated`).

Inspect a dependency's tag, manifest, license, deployment target, and transitive
packages before changing its pin. Never expose third-party model types through
`WorkspaceSession`.

## Why it matters

Markdown tables and incremental highlighting are deceptively large parsing and
rendering problems. A boundary gives Rafu mature behavior while retaining control
of memory, themes, TextKit ownership, and future package replacement.

## Reproduction or evidence

- MarkdownUI: <https://github.com/gonzalezreal/swift-markdown-ui/tree/2.4.1>
- Neon: <https://github.com/ChimeHQ/Neon/tree/0.6.0>
- SwiftTerm: <https://github.com/migueldeicaza/SwiftTerm/tree/v1.14.0>

## Verification

Run `swift build`, `swift test`, and `./script/build_and_run.sh --stage`. Open a
Markdown table and common source files in the manual acceptance pass, then compare
resident memory with no files and several open buffers.

To reproduce the transitive-version failure, remove Rafu's explicit
`SwiftTreeSitter` pin, run `swift package update`, and build. Restore the pin and
run `swift package resolve` before continuing.

## Related code, ADRs, and phases

- `Package.swift`
- `Sources/RafuApp/Markdown/MarkdownPreviewView.swift`
- `Sources/RafuApp/Editor/SyntaxHighlighter.swift`
- `docs/plans/phases/pre-initial-push-workbench.md`

---

# Tree-sitter grammar packaging and ABI constraints

- Applies to: Syntax highlighting with Tree-sitter parser grammars
- Last verified: Swift 6.2, SwiftTreeSitter 0.8.0, macOS 15 deployment target, 2026-07-15

## Rule or observed behavior

Tree-sitter grammars are pinned as exact SPM packages. All grammar selection, loading, and highlight-query bundling is mediated through `GrammarRegistry` (lazy actor in `Sources/RafuApp/Editor/Syntax/GrammarRegistry.swift`).

**Hard ABI constraint:** SwiftTreeSitter 0.8.0 vendors tree-sitter runtime ABI 14 (TREE_SITTER_LANGUAGE_VERSION 14, MIN_COMPATIBLE 13). Grammar parsers (C language definitions) must declare ABI 13–14 compatibility. The latest grammar tags (python/javascript/bash 0.25.x, markdown 0.5.x) are ABI 15 and will be rejected by `ts_parser_set_language()` at runtime. The pinned versions below are the newest ABI-14 releases.

**Pinned grammars (all MIT, all ABI 14, as of 2026-07-15):**

| Language | Owner/Repo | Exact tag | SPM product | C function |
|---|---|---|---|---|
| Swift | alex-pinkus/tree-sitter-swift | 0.7.3-with-generated-files | TreeSitterSwift | tree_sitter_swift() |
| Python | tree-sitter/tree-sitter-python | 0.23.6 | TreeSitterPython | tree_sitter_python() |
| JavaScript | tree-sitter/tree-sitter-javascript | 0.23.1 | TreeSitterJavaScript | tree_sitter_javascript() |
| TypeScript | tree-sitter/tree-sitter-typescript | 0.23.2 | TreeSitterTypeScript | tree_sitter_typescript() |
| TSX | (same) | 0.23.2 | TreeSitterTypeScript | tree_sitter_tsx() |
| JSON | tree-sitter/tree-sitter-json | 0.24.8 | TreeSitterJSON | tree_sitter_json() |
| YAML | tree-sitter-grammars/tree-sitter-yaml | 0.7.0 | TreeSitterYAML | tree_sitter_yaml() |
| TOML | tree-sitter-grammars/tree-sitter-toml | 0.7.0 | TreeSitterTOML | tree_sitter_toml() |
| Bash | tree-sitter/tree-sitter-bash | 0.23.3 | TreeSitterBash | tree_sitter_bash() |
| Markdown | tree-sitter-grammars/tree-sitter-markdown | 0.4.1 | TreeSitterMarkdown | tree_sitter_markdown() |
| Markdown Inline | (same) | 0.4.1 | TreeSitterMarkdown | tree_sitter_markdown_inline() |
| Dockerfile | camdencheek/tree-sitter-dockerfile | 0.2.0 | TreeSitterDockerfile | tree_sitter_dockerfile() |

**Critical notes:**

- **Swift grammar:** tag MUST be `0.7.3-with-generated-files`. Plain tags (0.7.3, etc.) omit the generated `src/parser.c` → SPM build fails.
- **YAML grammar:** pinned to 0.7.0 (depends on ChimeHQ/SwiftTreeSitter, matching our pin). Versions 0.7.1/0.7.2 switch to tree-sitter/swift-tree-sitter, causing a duplicate "SwiftTreeSitter" product in SPM resolution — avoid.
- **TSX and MarkdownInline:** these are secondary targets within the same product as TypeScript and Markdown respectively, not separate products. Their highlight query bundles require explicit `bundleName` attributes in `Package.swift` ("TreeSitterTypeScript_TreeSitterTSX", "TreeSitterMarkdown_TreeSitterMarkdownInline").
- **Dotenv gap:** no maintained SPM tree-sitter grammar exists for dotenv/`.env` files. The regex highlighter remains the active fallback for this language.

## Why it matters

Parser ABI mismatch is silent at compile time but causes runtime rejection of the language in the parser. Testing grammar availability with `Parser.setLanguage()` catches regressions, but the ABI gate test (`GrammarRegistryTests`) is the hard gatekeeper before any grammar is considered usable.

## Reproduction or evidence

**ABI constraint verification:**

Run the ABI gate in `Tests/RafuAppTests/GrammarRegistryTests.swift`. Each grammar's parser is tested with `Language.initialize(grammar: ...)` and `Parser.setLanguage()` to confirm ABI 14 compatibility before use. Reject any grammar with ABI > 14 from new pins.

**Build and binary-size deltas (clean build, Swift release mode):**

- Wall-clock build time: 52.79s (baseline, no grammars) → 75.79s (+23s, +44%, with all grammars). Measured on 8-core with warm SPM cache.
- Release binary size: RafuApp +22.9 KB (+0.2%). **CRITICAL CAVEAT:** This delta is deceptively small because the default release build applies `-dead_strip`, which removes grammar object code because `GrammarRegistry` is not yet called from any reachable app path (only tests). The debug binary is 32.6 MB larger with all grammars linked. The real ~60 MB C cost materializes once increment 8 wires highlighting through `GrammarRegistry` (see Increment 8 prerequisite below).

**Query bundle discovery:**

Under `swift test`, `Bundle.main` resolves to the test driver executable, not the app. As a result, `LanguageConfiguration.queries[.highlights]` returns nil for all grammar queries in the test environment. The ABI gate test is hard; the query assertion is conditional. This is expected and does not block further work until increment 8 wires queries into the app.

## Verification

```bash
swift build
swift test
# GrammarRegistryTests passes: 12-grammar ABI gate + cache + extension mapper + markdownInline injection-only
./script/format.sh --lint
```

Confirm all 10+ grammars resolve without duplicate products:
```bash
swift package resolve
# No "duplicate" errors in output
```

## Runtime query loading for tree-sitter highlighting (verified 2026-07-15)

**Problem:** SwiftTreeSitter's `LanguageConfiguration(_:name:)` bundle resolver cannot find SPM grammar bundles at runtime. SPM grammar products produce FLAT bundles (`.build/<config>/TreeSitterX_TreeSitterX.bundle/queries/highlights.scm`, no `Contents/Resources` wrapper) that are siblings of the executable. In test and app contexts, `Bundle.main` does not provide transparent access to these sibling bundles.

**Solution implemented in increment 8a:** Highlights are VENDORED into Rafu's own resource bundle.

1. Each grammar's `highlights.scm` is copied (MIT licensed) into `Sources/RafuApp/Resources/Grammars/<Name>/` alongside its `README.md` provenance note.
2. `Package.swift` RafuApp target declares `resources: [.copy("Resources/Grammars")]`, emitting a Swift resource accessor `Rafu_RafuApp.bundle` (the product bundle name).
3. At runtime, `Bundle.module.url(forResource:"highlights",withExtension:"scm",subdirectory:"Grammars/<Name>")` resolves the vendored query; this URL is passed to `Query(language:url:)` to load the compiled highlight query.
4. The `script/build_and_run.sh` staging script copies `$(swift build --show-bin-path)/Rafu_RafuApp.bundle` to the `.app` **top level** (sibling of `Contents`, not nested in `Contents/Resources`) and asserts its existence with `test -d/-f` checks. This placement matches where `Bundle.main.bundleURL` resolves via the app's executable context.

**UTF-16 byte offset fact:** SwiftTreeSitter parses in UTF-16. Query results (`NamedRange.range`, `Node.range`) return UTF-16 NSRanges directly. Byte offset conversion is `byte_offset = utf16_code_unit_offset × 2`; the classic UTF-8 byte-offset defect does not apply here.

**TypeScript and TSX** queries: the upstream `tree-sitter-typescript` package provides only a thin delta assuming JavaScript inheritance. Increment 8a handles this by concatenating the JavaScript and TypeScript query files for TypeScript buffers, and JavaScript + JSX + TypeScript for TSX buffers.

## Related code, ADRs, and phases

- `Package.swift`
- `Sources/RafuApp/Editor/Syntax/GrammarRegistry.swift`
- `Tests/RafuAppTests/GrammarRegistryTests.swift`
- `script/build_and_run.sh`
- `docs/plans/phases/lane-1-memory-and-syntax-plan.md` (increment 8)
