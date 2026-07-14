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

- New `Sources/RafuApp/Editor/DocumentGuardPolicy.swift` (pure): thresholds
  (proposed: > 8 MB file, or any line > 10,000 UTF-16 units — advisor
  finalizes) → `.guarded(reason:)`.
- Edits: document-open path sets guard metadata; `SyntaxHighlighter.swift`
  and `BufferSymbols.swift` skip guarded documents; banner with one-click
  override in the editor container (`EditorCanvasView` area; advisor
  confirms the host view); guarded files are also skipped by the symbol
  index later (increment 10 reads the same policy).
- Tests: policy tests incl. the one-line-minified case.

## Increment 3 — FSEvents storm circuit breaker

- Edits: `Sources/RafuApp/Services/WorkspaceLivenessService.swift` /
  `WorkspaceChangeClassifier` — pure storm rule (proposed: > 1,000 surviving
  paths or > 200 changed directories ⇒ single coalesced `treeChanged`);
  `WorkspaceSession.handleExternalChanges` honors it with one refresh.
- Tests: extend `Tests/RafuAppTests/WorkspaceChangeClassifierTests.swift`.
- Gate: re-run the 2,000-file `touch` scenario; peak RSS recorded.

## Increment 4 — Tab hibernation + undo caps

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

- Edits: the restoration path (`WorkspaceSceneRoot` / session restore)
  materializes non-visible tabs directly in the hibernated state from
  increment 4; only visible editors load content at launch.
- Tests: extend existing restoration tests.

## Increment 6 — Caps, audits, memory pressure

- Search caps + cancel-releases-buffers verification on
  `WorkspaceSearchService`; polling audit (no repeating timers outside the
  approved status item); new app-level memory-pressure source
  (`DispatchSource.makeMemoryPressureSource` — event-driven, allowed) that
  triggers hibernation sweep + index snapshot shedding on warn/critical.
- Documentor lands the fsmonitor/untracked-cache monorepo note and the caps
  table (terminal scrollback, git output, AI streams) in
  `docs/references/`.

## Increment 7 — Stage A: grammar packaging

- Edits: `Package.swift` — add pinned-exact SPM tree-sitter grammar packages
  for the §7.4 set (swift, python, javascript, typescript, json, yaml,
  toml, bash, markdown; advisor verifies maintained SPM availability for
  dockerfile and dotenv — where absent, the regex path remains for that
  language and the gap is documented).
- New `Sources/RafuApp/Editor/Syntax/GrammarRegistry.swift` — languageID →
  lazily-loaded `Language` + highlight query; queries loaded from the
  grammar packages' bundled `highlights.scm` resources.
- Licenses + binary-size delta recorded in
  `docs/references/editor-dependencies.md`. Gate: clean build; size noted.

## Increment 8 — Stage A: incremental syntax actor

- New `Sources/RafuApp/Editor/Syntax/SyntaxParsingActor.swift` — per-buffer
  actor consuming `DocumentEditDelta`: incremental `InputEdit`, reparse,
  query changed + visible ranges, emit revision-tagged spans; stale
  revisions discarded.
- Edits: `SyntaxHighlighter.swift` becomes a router — tree-sitter path when
  a grammar exists, existing regex windows otherwise; span application on
  the main actor through the existing Neon token path without creating undo
  entries (guard against re-entrant highlight-on-attribute-edit loops).
- Nuances: UTF-16 ↔ byte offset conversion for tree-sitter is the classic
  defect site — pure conversion helpers with dedicated tests; `os_signpost`
  on parse and apply for the gate evidence. Concurrency review required.
  This is the hardest increment in the lane — consider an Opus-model
  implementor override for it.
- Gate: signpost proof of changed/visible-range-only work; typing latency
  and idle RSS unchanged; visual parity spot-check.

## Increment 9 — Stage A: capture mapping, fences, `@` symbols

- New `Sources/RafuApp/Editor/Syntax/CaptureTokenMap.swift` (plan §7.3
  table). Edits: `BufferSymbols.swift` — captures-based extraction for
  grammar languages (regex fallback stays); Markdown fenced blocks route
  through `GrammarRegistry` (§7.7) in the preview path.
- Tests: mapping table; per-language symbol fixtures.

## Increment 10 — Stage B: workspace symbol index + navigation UI

- New `Sources/RafuApp/Services/WorkspaceSymbolIndex.swift` — actor
  mirroring `WorkspaceFileNameIndex`: `git ls-files` feed (non-git
  fallback), parse grammar-covered files, extract declaration captures into
  (name, kind, path, range); caps (512 KB file skip, 2,000 symbols/file,
  500,000 global with truncation disclosure); incremental updates from
  `WorkspaceChangeSet.changedDirectoryRelativePaths`; storm signal ⇒ full
  rebuild; generation counter + per-keystroke query cancellation like ⌘P.
- New `Sources/RafuApp/Navigation/SyntacticNavigationProvider.swift` —
  implements `NavigationTierProvider` over the index (definition: exact-name
  declarations ranked same-file → proximity; references: identifier
  occurrences, bounded).
- New `Sources/RafuApp/Views/NavigationPeekView.swift` — candidate list UI
  consuming `NavigationAnswer` (tier label shown; works for lane 2's answers
  unchanged).
- Edits: `WorkspaceSession` owns the index (rebuild triggers alongside the
  filename index); `CommandPaletteView.swift` workspace-symbol mode (advisor
  decides the prefix with `PaletteQueryParser`, without breaking the pinned
  `rank` tests); menu commands from `NavigationCommandIDs`; ladder
  registration: syntactic above text.
- Tests: index build/caps/incremental/ranking; provider fallthrough.
- Gate: synthetic 100k-file measurement — index build time and RSS recorded
  in `docs/references/memory-and-file-indexing.md`.

## Exit

All memory-resilience acceptance items measurable at this point are
recorded; Stages A/B gates hold; lane is merge-ready. Remaining
memory-resilience items that depend on lane 2 (server attribution rows in
Resources) complete at integration.
