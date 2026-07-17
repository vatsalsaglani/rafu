# Tree-sitter full-parse syntax highlighting architecture

- Applies to: Syntax highlighting via tree-sitter grammar parsing, SyntaxParsingActor, highlight query loading, and span application
- Last verified: Swift 6.2, SwiftTreeSitter 0.8.0, Neon 0.6.0, macOS 15 deployment target, 2026-07-18

## Rule or observed behavior

Tree-sitter full-parse highlighting is wired end-to-end behind Neon's pull-model Highlighter with graceful regex fallback everywhere.

**Query loading:** All 11 vendored grammars' `highlights.scm` queries compile and load non-nil both under `swift test` and in the staged `.app` bundle (see `editor-dependencies.md` "Runtime query loading" section for the vendored/Bundle.module/top-level-bundle-staging solution).

**Router design:** `NeonSyntaxHighlightingPipeline` resolves `GrammarLanguageID` at init. When a document is non-guarded (not suppressed by `DocumentGuardPolicy`) and a grammar exists, the pipeline swaps Neon's `tokenProvider` to the tree-sitter path: off-main `SyntaxParsingActor` queries the parsed tree and returns `SyntaxSpan` value types (Sendable, not Neon.Token which lacks cross-module Sendable), mapped back to Neon.Token on the main actor. Any failure (no grammar, missing/invalid query, parser rejection, document >2 MB UTF-16) leaves the regex tokenizer active. Guarded documents (suppressesSyntax=true) run NEITHER tree-sitter NOR regex paths (plain text).

**SyntaxParsingActor:** Per-buffer first-party Swift actor with actor-confined `Parser` and `MutableTree` (not Sendable, never exposed). Receives debounced (20 ms) `DocumentEditDelta` snapshots with monotonic `snapshotVersion` staleness discard. Full off-main reparse per keystroke (8a limitation; 8b will add incremental InputEdit). Parse capped at 2 MB UTF-16; bounded (visible-range) query via `execute(startByte:endByte:)` + `highlights()`. Emits `SyntaxSpan` arrays (start/length in UTF-16, capture name, revision). Torn down (tasks cancelled, parser/tree released) in `CodeEditorView.dismantleNSView`.

**Span application:** On the main actor, Neon's `setTemporaryAttributes(captures:,range:)` applies UTF-16 NSRanges without creating undo entries (TextKit1 layout-manager level, idempotent, no re-entrant storage delegate fires).

**Observability:** os_signpost intervals on subsystem `dev.vatsalsaglani.rafu` category `syntax`, with points logged for parse/query/apply phases. Only lengths and capture counts are logged; document text, file paths, and span details are never signposted.

**Capture→theme mapping:** `CaptureTokenMap` (increment 9) replaces 8a's minimal `SyntaxCaptureMap` with the full plan §7.3 capture→token table, resolved by longest-prefix match. Predicate gates (`#match?`, `#eq?`) are still not evaluated by the plain `QueryCursor.highlights()` path used for highlighting (predicate-gated captures apply unconditionally); the increment-9 `tags.scm` symbol-extraction path uses `ResolvingQueryCursor`/`Predicate.Context` instead, which does evaluate them.

**GrammarRegistry.shared:** Single lazy actor cache for all open buffers, keyed by `GrammarLanguageID`. Initialized at first grammar request; survives for the workspace lifetime.

## Why it matters

Tree-sitter syntax highlighting provides precise structural understanding without a long-lived language server, meeting the product constraint of no always-on servers (ADR 0005). The off-main actor pattern preserves typing latency by parsing asynchronously and applying results idempotently via TextKit1 attributes rather than direct storage mutation. Graceful fallback to regex ensures no buffer becomes uneditable if parsing fails or the grammar is unavailable.

The Sendable/non-Sendable boundary (actor-confined Parser/Tree internally, Sendable SyntaxSpan published externally) and no `@unchecked Sendable` escape hatches maintain strict concurrency checking. The 2 MB parse cap and visible-range query bounding are memory-resilience gates matching the large-file guard mode threshold.

## Reproduction or evidence

**Tests (210/210 passing, increment 8a):**

- `SyntaxParsingActorTests.swift`: off-main parse and query with fresh buffers, stale-revision discard, >2 MB rejection
- `SyntaxByteOffsetTests.swift`: UTF-16 ↔ tree-sitter byte offset conversion (×2 width, row/column derivation)
- `GrammarRegistryTests.swift`: all 11 grammar ABI compatibility gates pass; hard query assertion when Bundle.main context allows (fixture assertion conditional in tests due to Bundle.main = test executable, not app)
- `NeonSyntaxHighlightingPipelineTests.swift`: router fallback to regex on missing grammar, query failure, or suppressed syntax
- Integration under app launch (`./script/build_and_run.sh --verify`): queries resolve non-nil from Rafu_RafuApp.bundle, all 11 grammars compile and apply spans without user-visible artifacts

**Measurement (staged .app, 2026-07-15):**

- Resident memory: ~104 MB with grammars linked and queries reachable (idle, no files open). Typing latency and idle RSS not yet measured in Release build (8a limitation; 8b will establish baseline).

## Verification

```bash
# Build and test
swift build
swift test
# 210/210 passing, including 13 new tests for syntax parsing

# Lint
./script/format.sh --lint

# Staged app verification
./script/build_and_run.sh --verify
# Asserts Rafu_RafuApp.bundle present at .app top level
# App launches, queries resolve, no user-visible parsing errors
```

To verify queries load in the staged app:

```bash
# Manual: open a Swift, JavaScript, Python, or other supported-grammar buffer
# in the staged .app; verify highlight spans appear with structured coloring
# (not just regex token windowing). Close and reopen the file; spans persist.
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/Syntax/SyntaxParsingActor.swift` — actor implementation
- `Sources/RafuApp/Editor/Syntax/GrammarRegistry.swift` — cache and grammar loading
- `Sources/RafuApp/Editor/Syntax/SyntaxHighlighter.swift` — router and pipeline
- `Sources/RafuApp/Editor/Syntax/SyntaxByteOffset.swift` — UTF-16 conversion helpers
- `Sources/RafuApp/Editor/Syntax/CaptureTokenMap.swift` — capture→theme adapter (increment 9; replaces 8a's `SyntaxCaptureMap`)
- `Sources/RafuApp/Resources/Grammars/` — vendored highlights.scm and provenance
- `Tests/RafuAppTests/SyntaxParsingActorTests.swift`, `SyntaxByteOffsetTests.swift`
- `docs/references/editor-dependencies.md` (runtime query loading, grammar packaging)
- `docs/decisions/ADR-0005-language-intelligence-and-lsp.md` (no always-on servers)
- `docs/plans/phases/lane-1-memory-and-syntax-plan.md` (increments 8a/8b split)
## Incremental parsing (8b)

**Incremental InputEdit reparse (2026-07-15, verified):** `SyntaxParsingActor.applyEdit(startUTF16:oldEndUTF16:newEndUTF16:newText:version:)` applies one tree-sitter `InputEdit` to the retained `MutableTree`, then reparses using the edited tree as a hint via an instrumented chunked read block. The `tree.edit()` and `parser.parse()` calls are ATOMIC — no await between — so a stale revision arriving during parse cannot interrupt and corrupt the tree state. `updateSnapshot` remains the full-parse baseline path. Both paths record `ReparseMetric` (bytesRead, docBytes, wasIncremental) and emit `os_signpost` metadata (mode, editByte, docBytes, bytesRead counts only).

**Retained text snapshot (memory tradeoff):** The actor retains a private `var text: String` snapshot of the parsed document. This is necessary because `oldEndPoint` (the endpoint of the text being replaced, needed for the InputEdit) requires the OLD replaced text's newline structure, which the post-edit document string lacks. The tradeoff is one full-document String snapshot per live grammar buffer; bounded by the 2 MB parse cap and tab hibernation (increment 4).

**Non-cancelling serial chain for in-order delivery:** `NeonSyntaxHighlightingPipeline` uses a non-cancelling serial task queue (`syntaxWorkTail` / `enqueueSyntaxWork` / `enqueueEdit` / `enqueueFullRefresh`). Each unit awaits the previous task's `.value` before calling the actor. This guarantees in-order delivery because independent Tasks do NOT enter an actor in FIFO order — they race to acquire the actor. Edits are sourced synchronously on the main actor at enqueue time (offsets + full post-edit text snapshot captured before release), so nothing is ever dropped (version is a tag, not a gate). `recordEditDelta`/`editDeltas()` (lane-2 contract) remains untouched. `applyBaseStyleAndInvalidate` no longer reparses; theme-only changes invalidate and Neon re-queries the existing tree.

**Shape-dependent incremental reuse (critical nuance):** Tree-sitter incremental reuse is SHAPE-DEPENDENT. A large flat top-level sibling list re-reads the whole document on an edit (subtree reuse defeated); nested structure reads only chunks near the edit. Verified on SwiftTreeSitter 0.8.0 via instrumented bytesRead on a ~400 KB nested-structure benchmark buffer: single-char edits read ~2 KB (ratio ~0.005; asserted bytesRead*20 < docBytes as gate). This shape-dependence means the benchmark must be representative of real-world use; flat minified files regress to full-parse cost.

**Neon pull-model already bounds queries:** Neon's Highlighter uses a pull-model that bounds each query to the expanded visible range (`visible ± requestLengthLimit=4096`). 8b did NOT add new `changedRanges` query narrowing (it would be redundant and risks stale spans). The plan's "strict visible-range query bounding" item is therefore satisfied by Neon's existing architecture, not by new code — no 8b changes were needed to queries.

**Per-keystroke full-document copy latency observation:** `enqueueEdit` captures the full document (`textView.string`) on the main actor at every keystroke, bounded by the 2 MB cap. This is correct for ordering guarantees, but at/near the cap it becomes a per-keystroke main-actor String allocation on the typing path. A latency consideration flagged by the concurrency reviewer; profile if p95 typing-frame budgets regress on large near-cap buffers in Release build.

**Concurrency review sign-off:** Advisor final review (2026-07-15) confirmed ALL SIX safety areas: in-order/no-drop edit delivery, atomic edit+parse, stale/reorder safety, cap/tree==nil transitions, no `@unchecked Sendable`/no escape, teardown. No defects.

**Owed (coordinator/manual):** Release-build p95 typing-latency (~one frame) proof, idle-RSS (should be unchanged), and interactive Instruments signpost read of mode=incremental. The deterministic data-level gate (benchmark equivalence + bytesRead instrumentation) passes.

## Capture mapping (increment 9)

**CaptureTokenMap (plan §7.3):** The full capture→theme-token table, replacing 8a's minimal `SyntaxCaptureMap`. Each grammar's highlights.scm query uses semantic capture names (e.g., `string.escape`, `comment.documentation`, `constructor`); `CaptureTokenMap` resolves these to theme.syntax keys via longest-prefix match. The resolution rule is: split the capture name on ".", probe the full name down to the root (e.g., `string.escape` → probe `string.escape`, then `string`), return the first match; exact matches beat root matches (e.g., a `string.escape` entry beats a `string` fallback). The theme-supported superset is: `comment`, `comment.documentation` → `docComment`, `string`, `string.escape` → `escape`, `keyword`, `constructor` → `type`, `variable`, `variable.member`, `variable.field` → `property`, `function`, `type`, `number`, `punctuation`. Every §7.3 capture is verified test-to-map to an existing theme.syntax key; no highlighting regression from 8a.

**SyntaxParsingActor integration:** `SyntaxParsingActor.tokens` consumes `CaptureTokenMap.token(for:)` to convert highlights.scm captures to Neon tokens on the off-main actor.

## Grammar-backed @ symbols (increment 9)

**Tags query and definitions-only extraction:** The vendored `tags.scm` file (MIT license, recorded in `Resources/Grammars/README.md`) provides semantic symbol extraction for ten code grammars (Swift, Python, JavaScript, TypeScript, TSX, Bash, Dockerfile, TOML, YAML, Markdown; TS and TSX each compile against their own Language with JS+TS or JS+JSX+TS query concatenation). Bash and Dockerfile tags were hand-authored in the symbol-coverage lane's increment A, TOML and YAML tags in increment B, and Markdown tags in increment C, all verified against tree-sitter node-types.json. `GrammarRegistry.tagsQuery(for:)` caches the compiled tags query per grammar (nil for grammars without one: JSON, markdownInline).

**Definition capture filtering and predicate honoring:** `BufferSymbolScanner.scanUsingGrammar` performs a one-shot parse and queries via `ResolvingQueryCursor` (unlike the highlights path, which uses plain `QueryCursor.highlights()` and ignores predicates). Predicates like `#not-eq?` and `#not-match?` are EVALUATED, so constructors and `require()` calls are correctly excluded. Only definitions are extracted: `@definition.function`, `@definition.method` → `BufferSymbol.Kind.function`; `@definition.class`, `@definition.interface` → `BufferSymbol.Kind.type`. References (`@reference.*`) and non-definition captures (`@definition.property`, `@definition.constant`, `@definition.module`) are SKIPPED. The outline gap is documented: properties and constants do not appear in the symbol list (BufferSymbol.Kind unchanged).

**Markdown @-mode vs #-mode divergence (increment C):** For Markdown files, the `@` buffer-symbol palette deliberately KEEPS the regex `scanMarkdownHeadings` path (which preserves heading level information → `.heading(level:)` H1–H6 display), while the `#` workspace-symbol index uses the new grammar `tags.scm` path (which returns flat `section` kind with no level discrimination). This is enforced by a guard `grammarID != .markdown` in `CommandPaletteView.scanSymbols`: without it, the grammar path would return a non-nil EMPTY array for Markdown (since `section` suffix maps to nil in `BufferSymbolScanner.kind(forDefinitionSuffix:)`), which would blank the palette. The `section` suffix intentionally maps to nil so headings never pollute grammar-backed buffer symbols, keeping Markdown content-focused in the editor outline and level-preserving in level-aware regex scanning.

**Duplicate method wart:** For Swift class-body methods, the vendored tags.scm includes a nested pattern that matches BOTH `@definition.method` (nested scope) and the generic top-level `@definition.function` pattern, yielding two symbol entries with the same range. This is documented and tested; deduplication by range is a trivial future polish deferred to increment 10's workspace symbol index.

**TOML and YAML query-authoring nuances (increment B):** Hand-authored tags.scm files introduce two durable lessons: (1) **TOML config-key pairs:** Bare-key pairs are captured only when nested directly under `document`, `table`, or `table_array_element` contexts, excluding `inline_table` pairs (which are value data). The plan's "bare keys" scope refers only to unquoted/undotted keys at the config level. (2) **YAML top-level-only symbols:** The top-level-only restriction for mapping keys is achieved **structurally** via document-anchored ancestry (a direct `document` → block_mapping_pair → flow_node chain) rather than a depth predicate; nested mapping keys have an extra block_node ancestor that breaks this chain and excludes them automatically. Accepted limitations: YAML flow-style root maps (`{a: 1}` at document root) and complex (block_node) keys are not captured.

**CommandPaletteView integration:** `CommandPaletteView.scanSymbols` tries the grammar path first (if `tagsQuery` is non-nil), falls back to the existing regex scanner for non-grammar languages, unsupported grammars, or parse failure. The 2000-symbol cap and off-main execution are preserved.

## Markdown fence code highlighting (increment 9)

**MarkdownUI CodeSyntaxHighlighter bridge:** The new `TreeSitterCodeSyntaxHighlighter` conforms to MarkdownUI 2.4.1's `CodeSyntaxHighlighter` protocol (synchronous: `func highlightCode(_ code: String, language: String?) -> Text`). Installed in `MarkdownPreviewView` via `.markdownCodeSyntaxHighlighter(TreeSitterCodeSyntaxHighlighter())`.

**Info-string to grammar language ID:** `TreeSitterCodeSyntaxHighlighter.languageID(forInfoString:)` maps Markdown fence info strings (e.g., "swift", "javascript", "bash") to `GrammarLanguageID` using the same lookup as document-based syntax highlighting. Unknown or nil info strings → plain text with theme markup.code styling.

**Synchronous + nonisolated bridge:** Because MarkdownUI calls `highlightCode` nonisolated from a SwiftUI body (module's `.defaultIsolation(MainActor.self)`), the witness is `nonisolated func highlightCode`, bridging via `MainActor.assumeIsolated` (same precedent as `WorkspaceTerminalController.DelegateProxy`). The implementation queries a small `@MainActor` grammar/query cache — NOT the off-main `GrammarRegistry` actor — to avoid awaiting async work from a synchronous protocol method.

**Capacity and fallback:** Fence code is capped at 8,000 UTF-8 bytes. Parse failure or oversized code returns plain Text styled with theme markup.code, maintaining readability. No WKWebView introduced.

**GrammarLanguageID visibility:** Increment 9 widened `GrammarLanguageID.language` and `GrammarLanguageID.configurationName` from fileprivate to internal so the fence highlighter cache can build a Parser and compile highlights.scm without duplicating the Language switch logic.

**Notes for increment 10:** The tags.scm extraction data seeded into workspace symbol queries (dedupe by range is a polish for the index phase).

## Markdown inline emphasis/strong/code highlighting (symbol-coverage lane increment D)

**Bounded lazy visible-range inline parse design:** `SyntaxParsingActor` now supports an optional `markdown_inline` injection bundle passed at init. When active (Markdown buffers only), `tokens(inUTF16:range)` runs a secondary pass after block-level tokens:
1. Locates every `(inline)` node in the block tree intersecting the requested range via the locator query `"(inline) @injection.content"` (compiled from literal UTF-8 Data).
2. Substring-parses each `(inline)` span using the `markdown_inline` grammar and highlights query.
3. Remaps resulting spans to absolute UTF-16 offsets via `nodeRange.location + localSpan.location`.
4. Caps total inline UTF-16 units per call at `maxInlineUTF16PerCall = 4096` as a secondary guard above Neon's visible-range bounding.

No persistent inline tree is retained — each `tokens` call is a stateless, synchronous, actor-confined substring reparse of small inline regions. The deferred alternative (persistent `includedRanges` injection model for perf optimization) remains documented as a fallback design if profiling later demands it.

**CaptureTokenMap text.* rows (increment D):** The `markdown_inline/highlights.scm` query uses the older nvim `text.*` capture convention (`text.emphasis`, `text.strong`, `text.literal`, `text.title`, `text.uri`, `text.reference`, `text.quote`) rather than the newer `markup.*` names. Increment D added these rows to `CaptureTokenMap`, mapping each to its corresponding `markup.*` theme key: `text.emphasis` → `markup.italic`, `text.strong` → `markup.bold`, `text.literal` → `markup.code`, `text.title` → `markup.heading`, `text.uri`/`text.reference` → `markup.link`, `text.quote` → `markup.quote`. This fixed a pre-existing coloring gap: both the vendored block-level `Markdown/highlights.scm` and the inline grammar use nvim conventions, but `CaptureTokenMap` previously had no `text.*` rows, leaving Markdown buffers nearly uncolored beyond punctuation.

**GrammarRegistry and SyntaxHighlighter integration:** `GrammarRegistry.markdownInlineInjection()` builds and caches the injection bundle lazily; failures (missing resource, query compile error) are cached and do not crash or blank the editor. `SyntaxHighlighter.activateGrammarIfPossible` passes the bundle when `grammarID == .markdown`. The `Query` locator is built via `Query(language:data:)` from a literal UTF-8 Data constant, circumventing SwiftTreeSitter's lack of a string initializer.

**UTF-16 span remapping:** Inline spans are remapped using pure addition: `NSRange(location: nodeRange.location + localSpan.location, length: localSpan.length)`. Both `nodeRange` (from `Node.range`) and `localSpan` (from `cursor.highlights()`) are already UTF-16 NSRanges. No byte-to-UTF-16 conversion (the naive `× 2` mistake) — tree-sitter's byte offsets and `SyntaxParsingActor` operate in UTF-16 units consistently.

**Owed performance evidence:** p95 typing-latency proof under fast Markdown typing via Instruments/signpost (same measurement class as the 8b latency evidence) is deferred to measurement time and not yet gathered.

## Deliberate deferrals (post-merge validation, 2026-07-15)

### MarkdownInline code injections remain deferred

Markdown fence syntax highlighting is fully implemented via `TreeSitterCodeSyntaxHighlighter`. Inline code spans (backtick-delimited text like `variable` within prose) do NOT receive tree-sitter highlighting in this phase. This is a deliberate feature deferral, not a defect: inline code often appears in comments, lists, and documentation where precise syntax coloring is less critical than rendering readability, and the scope of MarkdownUI's `CodeSyntaxHighlighter` protocol is fence-only. Adding inline-span discovery (regex or tree-sitter AST traversal) and per-span highlighting would require changes to MarkdownUI's rendering or custom prose paragraph reconstruction, both out of scope for this checkpoint. The deferral does not impair usability — users see plain-text inline code with theme markup, and fence code (the primary embedded-code surface) highlights correctly.

## Neon token-provider staleness contract (post-fan-out fix, 2026-07-18)

Neon's `Highlighter.handleTokens` unions the **requested** range into its
`validSet` on every `.success` completion — including `.noChange`, whose
`range: nil` falls back to the requested range — with no re-validation
against the current document. Any token-provider completion that lands
after subsequent edits therefore pollutes `validSet` with offsets beyond
the (shrunken) document, and the next `didChangeContent` trips
`RangeMutation.transform(location:)`'s bounds assertion
(`Rearrange/RangeMutation.swift:84`) — a debug-build crash, silent range
corruption in Release. The reliable trigger was undo of a multi-caret
backspace: two rapid shrinking edits while a full-buffer request was in
flight, then an immediate ⌘Z.

Rule: an asynchronous token provider MUST complete with `.failure` when
the document changed since the request was issued — failure is the only
outcome Neon discards without touching `validSet`, and re-request comes
free from `didChangeContent`. `NeonSyntaxHighlightingPipeline` implements
this with a `contentGeneration` counter bumped per `.editedCharacters`
pass and captured **synchronously in the provider closure** (not inside
the async Task, where a scheduled edit could make a stale request look
current). Regression: `multiCaretUndoSurvivesStaleTokenRequest`
(`Tests/RafuAppTests/MultiCaretUndoDiagnosticTests.swift`), whose potency
was verified by neutralizing the generation guard and observing the exact
`RangeMutation.swift:84` fatal error.
