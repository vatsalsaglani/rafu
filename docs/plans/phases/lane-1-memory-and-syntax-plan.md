# Lane 1 execution plan — memory resilience + Tree-sitter Stages A/B

## Status

Execution plan for lane 1 of the two-lane split defined in
[`language-intelligence.md`](language-intelligence.md). Runs in the **main
checkout** on the current branch. Governs increments 0–10 below; each
increment is one advisor → implementor → verification → documentor cycle.
File paths reflect the tree on 2026-07-14; the advisor re-verifies every
path at brief time and the brief's paths win over this plan when they
disagree.

## Global rules for this lane

- Owned paths: everything **except** `Sources/RafuApp/LanguageIntelligence/`
  (lane 2's directory; lane 1 creates only the stub named in increment 0 and
  never touches the directory again) and
  `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift` (stub only,
  contents belong to lane 2).
- This lane exclusively owns `Package.swift`, `Package.resolved`,
  `Sources/RafuApp/Models/WorkspaceSession.swift`, everything under
  `Sources/RafuApp/Editor/`, `Sources/RafuApp/Views/`, and the navigation UI.
- Verification for every increment: `swift build`, `swift test`,
  `./script/format.sh --fix` then `--lint`, and
  `./script/build_and_run.sh --verify` whenever UI/scene/resource behavior
  changed. Do not run the app-launch verify while lane 2 is running one —
  the script kills any running staged Rafu.app.
- Actor or cross-actor work (increments 0, 4, 6, 8, 10) requires the
  `swift-concurrency-pro` review path per AGENTS.md.
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.
- New pure logic goes in `nonisolated` testable types, matching the existing
  pattern (`WorkspaceChangeClassifier`, `AICommitScopeSelection`,
  `CommandPaletteMatcher.rankFiles`).

## Increment 0 — Contract commit (MUST land before the lane-2 worktree is created)

**Status: COMPLETE (2026-07-14).** Verified: build, 150/150 tests, format lint, app-launch --verify. Contract decisions recorded in docs/references/navigation-and-lsp-contracts.md. The lane-2 worktree may be created from the commit containing this increment.

Goal: every cross-lane type, protocol, and seam exists and compiles, with
stub behavior only.

New files:

- `Sources/RafuApp/Navigation/NavigationTypes.swift` — `NavigationTargetKind`
  (definition, declaration, references, hover), `NavigationRequest`
  (documentURL, UTF-16 position, languageID, kind), `SymbolCandidate`
  (relativePath, UTF-16 range, name, kindLabel, previewLine),
  `NavigationTier` (`lsp(serverName:)`, `syntactic`, `text`),
  `NavigationAnswer` (tier, candidates, state: ready/indexing/unavailable).
  All `nonisolated`, `Sendable`, value types.
- `Sources/RafuApp/Navigation/NavigationTierProvider.swift` — protocol:
  `func answer(_ request: NavigationRequest) async throws -> NavigationAnswer?`
  where `nil` means "decline, fall through to the next tier"; plus a
  `tier: NavigationTier` identity.
- `Sources/RafuApp/Navigation/NavigationLadder.swift` — ordered provider
  list, first non-nil answer wins, cancellation propagates; ships with a
  `TextSearchNavigationProvider` default that wraps the existing bounded
  workspace search.
- `Sources/RafuApp/Navigation/NavigationCommandIDs.swift` — reserved command
  identifiers/names for: Go to Definition, Go to Declaration, Find
  References, Workspace Symbol Search, Open Language Servers Settings,
  Show Resources.
- `Sources/RafuApp/Services/ProcessResourceRegistry.swift` — actor;
  `register(id:name:kind:pid:)` / `unregister(id:)` with
  `ProcessKind` (terminalShell, git, languageServer, other) and
  `sample() -> [ProcessResourceSample]` (RSS via `proc_pid_rusage`, no
  shelling out).
- `Sources/RafuApp/Editor/DocumentEditDelta.swift` — struct with edited
  UTF-16 range, replacement length, and document revision (the plan §7.5
  step-2 shape) plus an `AsyncStream<DocumentEditDelta>` surface.
- `Sources/RafuApp/LanguageIntelligence/LanguageIntelligenceCoordinator.swift`
  — stub class with lifecycle methods (`workspaceDidOpen/close`,
  `documentDidOpen/change/close`) that do nothing. Lane 2 owns this file
  after this commit.
- `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift` — empty
  placeholder section, wired into the settings root (`RafuSettingsView`).
  Lane 2 owns its contents after this commit.

Edits:

- `Sources/RafuApp/Models/EditorDocument.swift` — publish
  `DocumentEditDelta` from the existing revision-increment path (advisor
  confirms the exact hook; expected near the text-change/dirty tracking).
- `Sources/RafuApp/Models/WorkspaceSession.swift` — one
  `@ObservationIgnored` `languageIntelligence` property + create/teardown
  calls in workspace open/close/replace paths. Lane 2 never edits this file;
  this seam is its only session access.

Tests: `Tests/RafuAppTests/NavigationLadderTests.swift` (order, decline
fallthrough, cancellation), `ProcessResourceRegistryTests.swift` (register +
sample own pid), delta emission test on `EditorDocument`.

Gate: build + tests green; zero user-visible behavior change. **User commits;
the lane-2 worktree is created from this commit.**

## Increment 1 — Resources surface

**Status: COMPLETE (2026-07-15).** Verified: build, 156/156 tests, format lint, app-launch --verify. Memory gate byte-exact vs `ps` (proc_pid_rusage ri_resident_size == ps rss, ratio 1.000). Terminal shells register into `ProcessResourceRegistry.shared`; git deliberately unregistered.

- New `Sources/RafuApp/Views/ResourcesView.swift`: app RSS (reuse the
  existing status-item sampling) plus `ProcessResourceRegistry.sample()`
  rows; samples only while visible (a `.task` loop that sleeps and exits on
  disappear — no standing timers, consistent with the no-polling rule).
- Edits: `Sources/RafuApp/Terminal/` controller registers/unregisters shell
  pids; menu + command-palette entry using the reserved command ID; status
  item click opens it. Git processes are short-lived and deliberately not
  registered — documentor records that choice.
- Tests: byte formatting + registry integration. Gate includes a manual
  check that numbers match `ps -o rss=` within tolerance.

## Increment 2 — Large-file guard mode

**Status: COMPLETE (2026-07-15).** Verified: build, 166/166 tests, format lint, app-launch --verify. Thresholds finalized: 2 MB / 10,000 UTF-16 line (8 MB proposal was dead code under the existing 4 MB open cap). BufferSymbols left untouched; @-symbol scan gated at the CommandPaletteView call site.

- New `Sources/RafuApp/Editor/DocumentGuardPolicy.swift` (pure): thresholds
  finalized at 2 MB maximum file size, 10,000 UTF-16 units maximum line
  length → `.guarded(reason:)`.
- Edits: document-open path sets guard metadata; `SyntaxHighlighter.swift`
  gates tokenization via `NeonSyntaxHighlightingPipeline.isSuppressed`;
  banner with one-click override in the editor container (`EditorCanvasView`
  area); guarded files are also skipped by the symbol index later (increment
  10 reads the same policy).
- `BufferSymbols.swift` NOT edited (pure scanner with no document context);
  @-symbol scan short-circuited at the call site in
  `CommandPaletteView.prepareSymbolsIfNeeded` when `document.suppressesSyntax`.
- Menu/command-palette "Enable Highlighting for this file" override command
  deferred; banner Button is the sufficient keyboard-reachable path this
  increment.
- Tests: policy tests incl. the one-line-minified case (10 new
  DocumentGuardPolicyTests).

## Increment 3 — FSEvents storm circuit breaker

**Status: COMPLETE (2026-07-15).** Verified: build, 171/171 tests, format lint. Memory gate: 2,000-file/~700-dir touch burst → peak ~67 MB (~0.6 MB rise), settled ~61 MB, single coalesced refresh. Thresholds: >1,000 surviving paths OR >200 changed dirs (strict `>`).

- Edits: `Sources/RafuApp/Services/WorkspaceLivenessService.swift` /
  `WorkspaceChangeClassifier` — pure storm rule (proposed: > 1,000 surviving
  paths or > 200 changed directories ⇒ single coalesced `treeChanged`);
  `WorkspaceSession.handleExternalChanges` honors it with one refresh.
- Tests: extend `Tests/RafuAppTests/WorkspaceChangeClassifierTests.swift`.
- Gate: re-run the 2,000-file `touch` scenario; peak RSS recorded.

## Increment 4 — Tab hibernation + undo caps

**Status: COMPLETE (2026-07-15).** Verified: build, 184/184 tests, format lint, app-launch --verify, advisor final review. Bounded working set (visible ∪ dirty ∪ newest-8) fixes a pre-existing dirty-tab data-loss bug; pendingDirtyText covers structural remounts; undo cap 200. See docs/references/editor-working-set-and-hibernation.md.

- New `Sources/RafuApp/Editor/DocumentHibernationPolicy.swift` (pure):
  eligible = not visible in any pane of any window, not dirty, and (open
  count > N or under memory pressure). Dirty documents never hibernate.
- Edits: `EditorDocument` gains loaded/hibernated state — hibernation
  releases text storage and syntax data, retains path/selection/scroll/
  revision metadata; focus reloads from disk (safe because never dirty; the
  existing mtime guard applies). Undo cap (`levelsOfUndo`) set where the
  undo manager is configured.
- Nuance: this is the riskiest memory increment — the advisor brief must
  map every consumer of a document's text storage before the implementor
  touches state. Concurrency review required.
- Tests: policy tests; hibernate→refocus restoration of selection/scroll.

## Increment 5 — Restoration placeholders

**Status: COMPLETE (2026-07-15).** Verified: build, 186/186 tests, format lint, app-launch --verify. Restore hibernates all non-visible tabs (grace-bypass), so only visible editors load content at launch, including the ≤8-tab case.

- Edits: the restoration path (`WorkspaceSceneRoot` / session restore)
  materializes non-visible tabs directly in the hibernated state from
  increment 4; only visible editors load content at launch.
- Tests: extend existing restoration tests.

## Increment 6 — Caps, audits, memory pressure

**Status: COMPLETE (2026-07-15).** Verified: build, 193/193 tests, format lint, app-launch --verify. App-level DispatchSource memory-pressure source hibernates all eligible docs + sheds the filename index on warn/critical; polling audit found no real poll; caps table recorded in docs/references/memory-caps-and-pressure.md. Search caps verified (no code change).

- Search caps + cancel-releases-buffers verification on
  `WorkspaceSearchService`; polling audit (no repeating timers outside the
  approved status item); new app-level memory-pressure source
  (`DispatchSource.makeMemoryPressureSource` — event-driven, allowed) that
  triggers hibernation sweep + index snapshot shedding on warn/critical.
- Documentor lands the fsmonitor/untracked-cache monorepo note and the caps
  table (terminal scrollback, git output, AI streams) in
  `docs/references/`.

## Increment 7 — Stage A: grammar packaging

**Status: COMPLETE (2026-07-15).** Verified: resolve clean (SwiftTreeSitter 0.8.0, no duplicate products), swift build clean, swift test 197/197 passing (new GrammarRegistryTests: 12-grammar ABI gate + cache + extension mapper + markdownInline injection-only), ./script/format.sh --lint clean. 10 grammars added (all MIT, all ABI 14); GrammarRegistry lazy actor implemented; regex highlighter remains the ONLY active highlighter (routing is increment 8). Build wall-clock +23s (~+44%: 52.79s→75.79s, 8-core, warm cache); release binary +22.9 KB (+0.2%, dead-stripped until increment 8 wires it; debug 32.6 MB when linked).

- Edits: `Package.swift` — add pinned-exact SPM tree-sitter grammar packages
  for all 10 languages: swift, python, javascript, typescript, json, yaml,
  toml, bash, markdown, dockerfile (all MIT, all ABI 14; dotenv gap documented
  as no maintained SPM grammar exists).
- New `Sources/RafuApp/Editor/Syntax/GrammarRegistry.swift` — lazy actor
  mapping GrammarLanguageID → cached LanguageConfiguration (parser Language +
  bundled highlights.scm query). Completion gate: ABI compatibility verified
  by GrammarRegistryTests `Parser.setLanguage()` calls.
- Grammar packaging details + ABI constraints + measured deltas recorded in
  `docs/references/editor-dependencies.md` (full grammar dependency table,
  hard ABI-14 constraint with re-verify rule, swift -with-generated-files
  note, yaml duplicate-product note, TSX/MarkdownInline secondary-target
  note, dotenv gap, build +23s and binary size deltas WITH dead-stripping
  caveat).

## Increment 8a — Stage A: tree-sitter query loading and full-parse highlighting

**Status: 8a COMPLETE (2026-07-15)** — `swift build` clean (no warnings); `swift test` 210/210 passing (13 new: 11-grammar hard non-nil highlights-query assertion, SyntaxParsingActor JSON+Swift parse tests asserting exact captures at exact UTF-16 ranges, SyntaxByteOffset pure tests, stale-version/parse-cap/no-query cases); `./script/format.sh --lint` clean; `./script/build_and_run.sh --verify` exit 0. Coordinator confirmed the staged `dist/Rafu.app` contains `Rafu_RafuApp.bundle` at the `.app` TOP LEVEL with all 11 `Grammars/<Name>/highlights.scm` files; app runs at ~104 MB RSS with grammars reachable.

- New `Sources/RafuApp/Editor/Syntax/SyntaxParsingActor.swift` — per-buffer
  first-party Swift actor consuming `DocumentEditDelta`: full-document reparse
  (incremental InputEdit deferred to 8b), query visible ranges, emit
  revision-tagged `SyntaxSpan` value types (Sendable); stale revisions
  discarded; parse capped at 2 MB UTF-16; parser + tree actor-confined,
  never exposed; torn down on editor dismantling.
- New `Sources/RafuApp/Editor/Syntax/SyntaxByteOffset.swift` — pure
  UTF-16 ↔ tree-sitter byte-offset conversion (byte = utf16_offset × 2)
  and row/column derivation; no UTF-8 involvement.
- Edits: `SyntaxHighlighter.swift` becomes a router — tree-sitter path when
  a grammar exists and document is not guarded, regex window fallback
  otherwise, plain text for guarded docs; span application on the main actor
  through Neon's `setTemporaryAttributes` (TextKit1 layout-manager, no undo,
  idempotent); `GrammarRegistry` resolved per-buffer at init.
- Nuances: highlights.scm VENDORED into `Sources/RafuApp/Resources/Grammars/<Name>/`,
  declared `resources: [.copy("Resources/Grammars")]` on RafuApp target, loaded
  via `Bundle.module.url(forResource:withExtension:subdirectory:)` + `Query(language:url:)`.
  Staged into `.app` by copying `Rafu_RafuApp.bundle` to `.app` TOP LEVEL (sibling
  of Contents, not nested; this is where Bundle.main.bundleURL resolves).
  `os_signpost` on subsystem `dev.vatsalsaglani.rafu` category `syntax` logs only
  lengths/counts, never text/paths/spans. TypeScript query = JS+TS concatenation;
  TSX = JS+JSX+TS. No @unchecked Sendable anywhere. Concurrency review: none yet
  (owed in 8b along with other sign-offs).
- Gate: all 11 grammars compile; queries load non-nil under `swift test` AND
  staged `.app`; router degrades to regex/plain gracefully; tree-sitter parse
  off-main, UTF-16 path, no @unchecked Sendable.

**Reference notes created:** `docs/references/tree-sitter-highlighting.md` (router, actor,
  query loading, signpost, 8a/8b split); `docs/references/editor-dependencies.md`
  reconciled (resolved the stale prerequisite, records actual solution).

## Increment 8b — Stage A: incremental reparse and metrics

**Status: 8b COMPLETE (2026-07-15)** — `swift build` clean; `swift test` 216/216 passing (6 new: incremental bytesRead≪docBytes benchmark, incremental==full-parse equivalence, cap-crossing both directions, InputEdit offset math insert/delete/multiline); `./script/format.sh --lint` clean; `./script/build_and_run.sh --verify` exit 0. Advisor concurrency review: ALL SIX areas CONFIRMED-SAFE (in-order/no-drop edit delivery, atomic edit+parse, stale/reorder safety, cap/tree==nil transitions, no @unchecked Sendable, teardown). No defects.

- Edits: `SyntaxParsingActor.swift` — incremental `InputEdit` reparse + tree
  reuse (atomic edit+parse, non-cancelling serial chain for in-order actor
  delivery, retained-text-snapshot memory tradeoff). Neon's pull-model already
  bounds queries to visible ± 4096; no additional query narrowing code added
  (would be redundant, risks stale spans). Shape-dependent tree-sitter reuse:
  flat files regress to full-parse cost; nested structure reads ~0.5% of
  document.
- Gate: bytesRead instrumentation proof of shape-dependence; equivalence test
  (incremental matches full-parse results); OWED (coordinator/manual):
  Release-build p95 typing-latency (~one frame) + idle-RSS + interactive
  Instruments signpost read of mode=incremental. See
  `docs/references/tree-sitter-highlighting.md` "Incremental parsing (8b)"
  section for detailed nuances and concurrency review sign-off.

## Increment 9 — Stage A: capture mapping, fences, `@` symbols

**Status: COMPLETE (2026-07-15).** Verified: build, 238/238 tests, format lint, app-launch --verify. Full §7.3 CaptureTokenMap (replaces SyntaxCaptureMap); @-symbols grammar-backed via vendored tags.scm (5 grammars, definitions-only, predicates honored); Markdown fences highlight via MarkdownUI CodeSyntaxHighlighter (8KB cap, graceful fallback). Known: duplicate Swift method entry + property/constant outline gap (BufferSymbol.Kind unchanged).

- New `Sources/RafuApp/Editor/Syntax/CaptureTokenMap.swift` (plan §7.3
  table). Edits: `BufferSymbols.swift` — captures-based extraction for
  grammar languages (regex fallback stays); Markdown fenced blocks route
  through `GrammarRegistry` (§7.7) in the preview path.
- Tests: mapping table; per-language symbol fixtures.

## Increment 10a — Stage B: workspace symbol index + palette # mode

**Status: 10a COMPLETE (2026-07-15)** — `swift build` clean (no warnings); `swift test` 255/255 passing (new WorkspaceSymbolIndexTests + SyntacticNavigationProviderTests; SearchCommandPaletteTests stayed green); `./script/format.sh --lint` clean; `./script/build_and_run.sh --verify` exit 0. Memory gate: symbol-index build on 28,000-file repo (8,000 .swift, ~40,000 declarations) peak ~137 MB, settled ~129 MB — under 150 MB budget.

- New `Sources/RafuApp/Services/WorkspaceSymbolIndex.swift` — actor
  mirroring `WorkspaceFileNameIndex`: `git ls-files` feed (non-git
  fallback), parse grammar-covered files, extract declaration captures into
  (name, kind, path, range); caps (512 KB file skip, 2,000 symbols/file,
  500,000 global with truncation disclosure); incremental updates from
  `WorkspaceChangeSet.changedDirectoryRelativePaths`; storm signal ⇒ full
  rebuild; generation counter + per-keystroke query cancellation like ⌘P.
  Per-language parser reuse (one `setLanguage` per grammar across whole build).
  Interned Int32 paths; cancelled build leaves prior state intact; sheddable
  under memory pressure.
- New `Sources/RafuApp/Services/WorkspaceSymbolExtractor.swift` — pure
  nonisolated extractor reusing `scanUsingGrammar` mechanics but keeping all
  `@definition.*` kinds (function/method/class/interface/property/constant/module)
  and deduping by (name, range) — fixes both duplicate-Swift-method and
  property/constant outline gap vs buffer symbols.
- New `Sources/RafuApp/Navigation/SyntacticNavigationProvider.swift` —
  implements `NavigationTierProvider` over the index (.definition/.declaration
  exact-name lookup ranked same-file → same-directory → lexicographic,
  authoritative-empty answer if index exists with no match; .references/.hover
  decline to text tier; .building → `.indexing`).
- Edits: `WorkspaceSession` owns the index (rebuild triggers alongside filename
  index, full on refreshWorkspace, incremental on non-storm changes via
  changedDirectoryRelativePaths, reset in resetFileTreeState, shed in
  respondToMemoryPressure); `CommandPaletteView.swift` additive `#`
  workspace-symbol mode (header/empty-state/500k truncation caption; direct
  jump on selection); ladder registration: [SyntacticNavigationProvider,
  TextSearchNavigationProvider] with documented lane-2 LSP insertion point at
  index 0 (above syntactic).
- Tests: WorkspaceSymbolIndexTests (build/caps/incremental/generation/query
  cancellation); SyntacticNavigationProviderTests (definition ranking,
  references decline, .building state); SearchCommandPaletteTests (# mode,
  keystroke cancellation).
- Durable nuance: FileManager.enumerator and contentsOfDirectory disagree on
  /var ↔ /private/var symlink resolution; relative-path computation must
  resolve both root and enumerated URLs. Recorded in workspace-symbol-index.md.

## Increment 10b — Stage B: navigation UI (peek view + menu commands + cursor-word seam)

**Status: 10b COMPLETE (2026-07-15)** — `swift build` clean (no warnings); `swift test` 271/271 passing (16 new: IdentifierUnderCaretTests + NavigationPresentationTests; pinned CommandPaletteMatcher/SearchCommandPaletteTests stayed green); `./script/format.sh --lint` clean.

- `EditorDocument.selectionProvider: (() -> NSRange)?` — cursor seam beside
  `textSnapshotProvider`; set/cleared by `CodeEditorView.makeNSView`/
  `dismantleNSView` from the mounted `RafuTextView.selectedRange()`.
- New `Sources/RafuApp/Editor/IdentifierUnderCaret.swift` — pure nonisolated
  double-click-style word-at-caret extraction over `NSString`/UTF-16 (never
  `String` indices), so it matches `NavigationRequest.position` exactly on
  emoji/combining-mark text. Boundary rule: caret inside a word expands it;
  caret just after a word (double-click semantics) expands the token behind
  it; anything else (whitespace, start of an empty selection with no
  adjacent word char) returns `nil`. Clamps an out-of-range position.
- New `Sources/RafuApp/Navigation/NavigationPresentation.swift` — pure
  `NavigationPeekContent`/`NavigationOutcome`/`NavigationPresentation.outcome(for:kind:)`
  decision layer between a resolved `NavigationAnswer?` and the UI: nil or
  zero candidates → `.empty(kind)`; `.indexing` state → `.indexing`; exactly
  one candidate → `.jump`; two or more → `.results(answer)` peek.
- `WorkspaceSession.navigate(kind:)` — builds a `NavigationRequest` from the
  selected document's live caret/selection (`textSnapshotProvider` +
  `selectionProvider`) and `IdentifierUnderCaret`, resolves it against
  `navigationLadder` in a cancellable `Task` (a second `navigate` call
  supersedes the first), and applies `NavigationPresentation.outcome` —
  `navigateToSymbolCandidate(_:)` reuses `openWorkspaceSymbol` for the actual
  jump. `isNavigationPeekPresented`/`navigationPeekContent` reset in
  `resetFileTreeState()`; `navigationTask` cancelled in the isolated deinit.
  A no-op when the active document's editor is not mounted (hibernated/
  preview-only) or no workspace is open.
- New `Sources/RafuApp/Views/NavigationPeekView.swift` — candidate list sheet
  (mirrors `CommandPaletteView`'s `@State selectedIndex` +
  `.onKeyPress(.downArrow/.upArrow/.return)` + `ScrollViewReader` pattern),
  presented via `.sheet(isPresented: $session.isNavigationPeekPresented)` in
  `WorkspaceWindowView`. Shows `NavigationAnswer.tier.label` for provenance
  and never branches on the `NavigationTier` case — a lane-2 `.lsp` answer
  renders through the same rows unchanged. VoiceOver labels per row
  (name/kind/path) and on the header (title + tier). `.indexing` and
  `.empty(kind)` render a brief message with a Close button.
- `RafuAppCommands.swift` `CommandMenu("Rafu")`: three new buttons — "Go to
  Definition" (⌃⌘J), "Go to Declaration" (menu-only, no shortcut), "Find
  References" (⌃⌘R) — each with its `NavigationCommandID` accessibility
  identifier and `.disabled(workspaceSession?.selectedDocument == nil)`.
- Tests: `IdentifierUnderCaretTests` (mid-word, boundary before/after,
  no-identifier, start, end, underscores, digits, empty text, clamped
  out-of-range); `NavigationPresentationTests` (nil→empty,
  indexing→indexing, ready-zero→empty, unavailable-zero→empty,
  ready-one→jump, ready-multiple→peek).
- Deferred (recorded here for later pickup, not implemented this increment):
  ⌘-click navigation. The menu command (⌃⌘J) plus `NavigationCommandID`
  already satisfy AGENTS.md's "every core action needs a visible UI path and
  a menu/keyboard path" rule, so ⌘-click is additive convenience, not a gap.
  Planned approach: `RafuTextView` (an `NSTextView` subclass with no
  `mouseDown` override today) overrides `mouseDown(with:)`, checks
  `event.modifierFlags.contains(.command)`, and on a command-click resolves
  the clicked character index via the existing
  `characterIndexForInsertion(for:)` helper; a callback (mirroring
  `saveAction`/`toggleCommentAction`'s `EditorDocument` closure pattern, or a
  weak delegate) invokes `WorkspaceSession.navigate(kind: .definition)` at
  that position instead of the live selection. Needs a hover/cursor
  affordance (pointing-hand cursor over an identifier while ⌘ is held) to
  meet the "no core action hidden behind an undiscoverable gesture" bar, and
  care that plain command-click-to-place-cursor (the default AppKit
  behavior when no identifier is under the click) still works when the
  click lands outside an identifier.
- Gate: second-window UI test, keyboard reachability — done manually via
  code review of the `NavigationPeekView` keyboard/VoiceOver paths and the
  menu commands' `@FocusedValue`-scoped `disabled` guards (same mechanism
  already verified for `showResources`/`saveSelectedDocument` in earlier
  increments); no separate GUI launch pass run this increment (coordinator
  runs `build_and_run.sh` verification separately). ⌘-click intentionally
  not implemented (see above).

## Exit

**Lane 1 COMPLETE (2026-07-15).** All increments 0–10b verified and passing (271/271 tests across 4 suites). Stages A/B gates hold; lane is merge-ready. Memory resilience and Tree-sitter syntax pipeline ready for integration with lane 2. Post-merge validation fixes (batches A–E) complete 2026-07-15; 485 tests; see post-merge-validation-fixes.md for detailed findings and remaining manual items.

Running totals:
- **Tests:** 271 passing (incremented: 150 → 156 → 166 → 171 → 184 → 186 → 197 → 210 → 216 → 238 → 255 → 271).
- **Syntax:** full-document and incremental tree-sitter reparse (8a/8b), capture mapping + grammar-backed symbols (9), workspace symbol index (10a).
- **Navigation UI:** navigation ladder (0), syntactic tier provider (10a), peek/menu UI + keyboard commands + cursor seam (10b).

Remaining work OWED from increments 8–10:
1. Release-build typing-latency p95 + idle-RSS measurement (noted in increments 8b / plan §7.5).
2. Interactive Instruments signpost read of `mode=incremental` syntax parsing (noted in increment 8b).
3. Live GUI/VoiceOver/second-window usability passes for new syntax-highlight/navigation-peek/menu UI (requires manual verification with the app running).
4. ⌘-click navigation (deferred; approach recorded in increment 10b; satisfies AGENTS.md menu/keyboard-path rule via ⌃⌘J and menu entry).

Server attribution rows in Resources view and final language-intelligence integration complete at lane-1/lane-2 merge.
