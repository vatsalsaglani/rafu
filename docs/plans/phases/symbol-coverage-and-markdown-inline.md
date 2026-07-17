# Lane plan — Symbol coverage (tags.scm × 5) + markdownInline injection

## Status

**Implemented and verified (2026-07-18).** All increments A–E landed on
`lane/symbol-coverage`: five hand-authored `tags.scm` (Bash, Dockerfile,
TOML, YAML, Markdown), JSON deliberately skipped, the go-to-definition
kind-filter decision resolved (`navigableKinds` excludes `section`), and
markdownInline injection wired as a bounded lazy visible-range inline
parse. `swift build` + `swift test` green (519 tests; one pre-existing
`JSONRPCConnectionTests` ordering flake, out of lane scope). Docs closed
out. `./script/build_and_run.sh --verify` passed (exit 0): the staged
`.app` launches and stays up with the new grammar resources
(`MarkdownInline/highlights.scm` + five `tags.scm`) packaged where
`Bundle.module` resolves them. **Owed:** a human-eyeball confirmation of
on-screen Markdown inline coloring (the `--verify` gate proves launch, not
rendering) and p95 Markdown-typing latency evidence (measurement-time,
same class as 8b). Not committed — awaiting the user.

Planned (2026-07-17). One of six post-audit lanes defined in
[`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md). Runs in a
**dedicated git worktree**. Extends lane-1 increments 9–10: grammar-backed
symbols currently cover 5 of 11 grammars; YAML/TOML/JSON/Bash/Dockerfile/
Markdown fall to the text tier, and the packaged `markdown_inline` grammar
is unwired. Each increment is one advisor → implementor → verification →
documentor cycle. File:line anchors reflect the tree on 2026-07-17; the
repository wins when they disagree.

## Verified baseline

- Vendored queries (`Sources/RafuApp/Resources/Grammars/`): all 11
  primary grammars have `highlights.scm`; **tags.scm exists only for
  JavaScript, Python, Swift, TSX, TypeScript**; no `MarkdownInline/`
  directory at all (`README.md:32`).
- **Upstream ships no usable tags.scm for any missing grammar** (verified
  in `.build/checkouts/` — bash/dockerfile/toml/yaml/json/markdown ship
  only highlights, markdown sub-grammars also injections). Every new
  query is **hand-authored**.
- Loading is automatic: `GrammarRegistry.tagsQuery(for:)`
  (`GrammarRegistry.swift:149–164`) auto-loads any
  `Grammars/<Name>/tags.scm` — dropping the file in suffices; only doc
  comments (:99–103, :180) need updating.
- The **file-skip gate** is `WorkspaceSymbolExtractor.grammarsWithTags`
  (`WorkspaceSymbolExtractor.swift:38–40`), consumed by
  `WorkspaceSymbolIndex.swift:370`. Captures require `@name` + any
  `@definition.*` (:109–125); buffer kinds map via
  `BufferSymbolScanner.kind(forDefinitionSuffix:)`
  (`BufferSymbols.swift:84–97`).
- Markdown `@`-mode currently uses regex `scanMarkdownHeadings`
  (`BufferSymbols.swift:184–211`) which preserves **heading level** —
  a tags.scm path would lose it (drives the C3 divergence guard).
- **Load-bearing companion finding:** `CaptureTokenMap`
  (`CaptureTokenMap.swift:39–112`) has **no `text.*` rows**, and both
  vendored `Markdown/highlights.scm` and upstream
  `markdown_inline/highlights.scm` use the old nvim `text.*` convention —
  so Markdown editor buffers today get almost no coloring beyond
  punctuation. Injection wiring without the `text.*` rows is pointless.
- `markdown_inline` is packaged and registered (`GrammarRegistry.swift:8,
  38, 207, 227`) but injection-only and unwired; `SyntaxParsingActor` has
  one parser/query/tree and no injection concept
  (`SyntaxParsingActor.swift`, `tokens(inUTF16:)` :179–197).
- Pinned tests that must flip in lockstep:
  `GrammarRegistryTests.swift:133–135` (has-tags list) and :147–152
  (without-tags list); `WorkspaceSymbolIndexTests.swift:39` (yaml nil)
  and :48–50 (json/Dockerfile/notes.md nil).

## Per-grammar decisions

| Grammar | Decision | Query → suffix → buffer kind |
|---|---|---|
| Bash | hand-author | `function_definition name:(word)` → `definition.function` → `.function` |
| Dockerfile | hand-author | `from_instruction as:(image_alias)` → `definition.class` → `.type` (stage-as-type, documented) |
| TOML | hand-author | tables/array-tables → `definition.class`; top-level `pair` keys → `definition.property` |
| YAML | hand-author | anchors → `definition.constant`; top-level mapping keys → `definition.property` |
| Markdown | hand-author, **`#` index only** | headings → `definition.section` (new suffix; buffer `@`-mode keeps the regex path for heading levels) |
| JSON | **deliberately skip** | keys are unbounded noise with no navigational payoff — documented in the Grammars README |

**Open product decision (resolve before merging C into navigation, or
explicitly defer):** `SyntacticNavigationProvider` `.definition` lookup
has no kind filter, so YAML keys / Markdown headings could answer ⌃⌘J on
a same-named code identifier. Option: restrict `.definition` matching to
code-declaration kinds and let sections/keys surface only in `#` search.
Record the choice in the workspace-symbol-index reference note.

## Global rules for this lane

- **Owned paths:** `Sources/RafuApp/Resources/Grammars/**` (new query
  files + README), `Sources/RafuApp/Editor/Syntax/GrammarRegistry.swift`,
  `SyntaxParsingActor.swift`, `CaptureTokenMap.swift`,
  `Sources/RafuApp/Editor/SyntaxHighlighter.swift`,
  `Sources/RafuApp/Editor/BufferSymbols.swift`,
  `Sources/RafuApp/Services/WorkspaceSymbolExtractor.swift`, the five
  test files (`GrammarRegistryTests`, `WorkspaceSymbolIndexTests`,
  `BufferSymbolScannerTests`, `SyntaxParsingActorTests`,
  `CaptureTokenMapTests`) + new fixtures,
  `docs/references/tree-sitter-highlighting.md`,
  `docs/references/workspace-symbol-index.md`, and this plan document.
- **Shared:** `Sources/RafuApp/Views/CommandPaletteView.swift` — one-line
  guard in increment C; do not land concurrently with another lane's
  palette edit (fan-out protocol sequences it).
- **Forbidden paths:** `Sources/RafuApp/LanguageIntelligence/**`,
  `Settings/LanguageServersSettingsSection.swift`, `Package.swift`/
  `Package.resolved` (**no new dependency — both grammars are already
  packaged**), Git services, `Sources/RafuApp/Markdown/**` (preview is
  the Mermaid lane; this lane is the *editor buffer* path),
  `Sources/RafuCLI/**`, `AGENTS.md`, shared doc indexes (appends at
  merge).
- **Run increments serially within this one worktree** — each mutates the
  two pinned negative-test files.
- Before finalizing any query, verify node/field names against the
  grammar's `src/node-types.json` in `.build/checkouts/` (TOML top-level
  `pair` anchoring and YAML anchor nesting are the two flagged
  uncertainties). Every new grammar gets a `tagsQuery != nil` +
  `patternCount > 0` assertion **and** a real-extraction fixture test —
  a wrong node name fails silently otherwise (`tagsQuery` caches nil).
- Increment D touches `SyntaxParsingActor` → `swift-concurrency-pro`
  review path (inline parser/tree actor-confined, nothing non-Sendable
  crosses await, teardown releases the inline parser).
- Verification per increment: `swift build`, `swift test`, format
  fix+lint; `./script/build_and_run.sh --verify` only for D (visible
  rendering change) — never while another lane runs it.
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.

## A — Bash + Dockerfile tags

1. `Bash/tags.scm`: `(function_definition name: (word) @name)
   @definition.function`.
2. `Dockerfile/tags.scm`: `(from_instruction as: (image_alias) @name)
   @definition.class`.
3. `grammarsWithTags` += `.bash, .dockerfile`.
4. Flip pinned lists (`GrammarRegistryTests:133–135, 147–152`;
   `WorkspaceSymbolIndexTests:49`).
5. Fixtures: `foo() { :; }` / `function bar { :; }` → functions;
   `FROM node AS builder` → `builder` as type.

## B — TOML + YAML tags

1. `TOML/tags.scm`: `table`/`table_array_element` bare/dotted keys →
   `definition.class`; top-level `pair` bare keys →
   `definition.property` (confirm the document-level anchor node first).
2. `YAML/tags.scm`: `(anchor (anchor_name) @name) @definition.constant`;
   `(block_mapping_pair key: (flow_node) @name) @definition.property`
   restricted to top level (confirm nesting against node-types.json).
3. `grammarsWithTags` += `.toml, .yaml`; flip
   `WorkspaceSymbolIndexTests:39` + registry lists.
4. Fixtures: `[server]\nport = 8080` → `server`(type)/`port`(property);
   `anchor: &base` → `base`(constant) + top-level key(property).

## C — Markdown headings in the `#` index (with buffer divergence guard)

1. `Markdown/tags.scm`: `(atx_heading (inline) @name)
   @definition.section`; `(setext_heading (paragraph) @name)
   @definition.section`.
2. `grammarsWithTags` += `.markdown`; flip
   `WorkspaceSymbolIndexTests:50` + registry lists.
3. **Divergence guard:** `CommandPaletteView.scanSymbols` (:452–460)
   gains `guard grammarID != .markdown` before `scanUsingGrammar`, so
   `@`-mode keeps regex heading **levels**. Regression test: Markdown
   `@`-mode still returns `.heading(level:)`.
4. `kind(forDefinitionSuffix:)`: `"section"` falls through to nil
   (already default — assert it).
5. Index fixture: headings of a `.md` file appear in `#` search with
   kind `section`.
6. Resolve or explicitly defer the go-to-definition kind-filter decision
   (above) before merge.

## D — markdownInline injection (editor buffer highlighting)

Design: **bounded, lazy, visible-range inline parse** — no persistent
inline tree (the persistent `includedRanges` injection model is
documented as the deferred alternative if profiling demands it).

1. Vendor `MarkdownInline/highlights.scm` verbatim from
   `.build/checkouts/tree-sitter-markdown/tree-sitter-markdown-inline/
   queries/highlights.scm`.
2. `CaptureTokenMap` += `text.*` rows (existing token targets, no theme
   change): `text.emphasis`→italic, `text.strong`→bold,
   `text.literal`→code, `text.title`→heading, `text.uri`/`text.reference`
   →link, `text.quote`→quote. **Also fixes the pre-existing
   block-Markdown coloring gap** — visible appearance change, called out
   in the launch pass.
3. `GrammarRegistry`: cached accessor returning, for `.markdown` only, an
   inline-injection bundle — `markdown_inline` Language + compiled inline
   highlights Query + locator `Query(language: markdown,
   "(inline) @injection.content")`.
4. `SyntaxParsingActor.init?` accepts the optional bundle. In
   `tokens(inUTF16:)`: after block spans, run the locator on the block
   tree bounded to the requested range; per intersecting `(inline)` node,
   parse its substring with the inline parser, query, remap spans by the
   node's absolute UTF-16 start (byte = utf16 × 2 per `SyntaxByteOffset`),
   map via `CaptureTokenMap`, append. Total-inline-bytes cap per call
   (skip beyond a few KB). Synchronous, actor-confined, no `@unchecked
   Sendable`.
5. `SyntaxHighlighter.activateGrammarIfPossible` (:478–501): pass the
   bundle when `grammarID == .markdown`.
6. Tests: exact-UTF-16-range span assertions for `*em*`, `` `code` ``,
   `[t](u)` in a markdown buffer; `CaptureTokenMapTests` rows; Neon's
   visible ± 4096 bounding keeps per-call work small — the p95 typing
   proof under fast Markdown typing is owed at measurement time (same
   class as the 8b owed latency evidence).

## E — Documentation close-out

Update `tree-sitter-highlighting.md` (markdownInline no longer deferred;
lazy visible-range design; the `text.*` CaptureTokenMap gap it fixed),
`workspace-symbol-index.md` (new coverage, JSON skip, kind-filter
decision), `Grammars/README.md` (provenance rows marked "hand-authored,
not upstream" + JSON-skip rationale + MarkdownInline row), registry doc
comments (:99–103, :180). Manual pass: `@`-mode on `.sh`/`Dockerfile`/
`.toml`/`.yaml`/`.md`; `#`-mode cross-file; staged-app Markdown inline
coloring + second window.

## Exit

- Five hand-authored tags.scm live; JSON skip documented; `#` and
  `@`-mode surface the new symbols; Markdown `@`-mode heading levels
  preserved.
- Markdown buffers show inline emphasis/strong/code/link coloring;
  `text.*` rows fix block coloring too.
- All pinned negative tests flipped in lockstep; fixture tests assert
  exact symbols and exact UTF-16 ranges; concurrency review done for D;
  no `Package.swift` diff; kind-filter decision recorded.
