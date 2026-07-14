# Language intelligence: Tree-sitter engine, workspace symbols, opt-in LSP

## Status

Planned; governed by
[ADR 0005](../../decisions/0005-language-intelligence-and-lsp.md).
Post-initial-push. Three stages, each independently shippable and gated.
Stage A implements what plan v0.4 §7.4–7.5 already promised — the current
highlighter is a regex window scanner, with SwiftTreeSitter 0.8.0 pinned but
unwired. This brief supersedes Phase 2's "optional Tree-sitter outline" item
and Phase 6's "a few opt-in bundled language servers" line.

## Product outcome

Go to Definition, Go to Declaration, Find References, and symbol search that
work on any repository the moment it opens — syntactically, from bundled
grammars, with zero configuration — and upgrade to server-grade semantic
precision when the user explicitly installs or points Rafu at a language
server. Precision tiers are labeled, servers are transparent (what runs,
from where, using how much memory), and nothing runs that the user did not
start.

## The navigation ladder

Every navigation command resolves down this ladder and labels its answer:

1. **LSP tier** — a configured, trusted, running server for the language
   answers definition/declaration/references/hover/symbols
   ("via rust-analyzer").
2. **Syntactic tier** — the workspace symbol index (Tree-sitter declaration
   captures) answers by name resolution: same-file declarations first, then
   ranked workspace candidates in a peek list. Labeled "syntactic match."
3. **Text tier** — bounded workspace text search as the floor for languages
   with neither grammar nor server.

## Stage A — Tree-sitter syntax engine

- Replace the regex window scanner with the plan §7.5 pipeline: a per-buffer
  syntax actor, incremental tree edits from UTF-16 deltas, reparse and query
  of changed and visible ranges only, revision-tagged spans, stale-result
  discard, attribute application on the main actor without undo entries.
- Wire the already-pinned Neon 0.6.0 / SwiftTreeSitter 0.8.0 stack. Grammars
  for the §7.4 language set are compiled into the bundle and lazy-loaded per
  language on first open buffer. No user-supplied grammar dylibs (dynamic
  code loading is an open decision needing its own ADR).
- Capture→theme-token mapping per plan §7.3; Markdown fenced blocks route
  through the same registry (§7.7).
- Palette `@` symbols move from `BufferSymbolScanner` regex to captures for
  bundled languages (same cap, better accuracy); regex stays as the fallback
  for grammar-less files.
- Memory: syntax trees exist for open, non-hibernated buffers only and are
  discarded on close or hibernation; measured before/after with the standard
  procedure.

Stage gate: highlight parity or better across the bundled set; incremental
behavior proven with signposts (no full-document reparse on keystroke); no
regression in idle or typing budgets.

## Stage B — Workspace symbol index (zero-config navigation)

- A bounded background actor in the mold of `WorkspaceFileNameIndex`: walk
  `git ls-files` output (gitignore-aware, with the non-git fallback), parse
  files that have bundled grammars, and extract declaration captures into
  (name, kind, path, range) tuples — names and locations only, no retained
  trees.
- Caps: per-file size skip, per-file symbol cap, global symbol cap with
  truncation disclosure. Incremental updates ride the existing FSEvents
  change batches; builds and queries are cancellable and off-main with
  per-keystroke cancellation like the ⌘P index.
- Powers: workspace symbol search in the palette, Go to
  Definition/Declaration with a peek list when multiple candidates exist,
  and Find References as ranked same-identifier occurrences (current file
  first, then proximity). Honestly labeled as syntactic answers.
- This stage is what makes navigation work "regardless of language" from day
  one: any bundled grammar, no server, no download, no configuration.

Stage gate: index build and query costs measured on the synthetic 100k-file
monorepo; RSS recorded; storm behavior verified against the memory-resilience
circuit breaker.

## Stage C — Opt-in LSP client

- A thin native client: JSON-RPC framing over stdio, child processes spawned
  with executable plus argument array, capability negotiation, incremental
  `didChange` sync. Feature set for this stage: initialize/shutdown,
  didOpen/didChange/didClose, definition, declaration, references, hover,
  documentSymbol. Diagnostics, rename, and code actions are an explicitly
  separate later slice.
- **Server variance.** The JSON-RPC core is shared, but servers differ at
  the edges; the client must absorb this rather than assume uniformity:
  - *Capability subsets*: the `initialize` response's `ServerCapabilities`
    decides feature routing **per feature, not per language** — a server
    without `referencesProvider` drops Find References to the syntactic
    tier while Go to Definition stays on the LSP tier.
  - *Sync and encoding*: honor the server's declared sync kind (full vs
    incremental `didChange`) and negotiate `positionEncoding` (the UTF-16
    default matches TextKit natively; UTF-8-only servers need conversion).
  - *Initialization options*: many servers require server-specific
    `initializationOptions`/settings JSON; the registry entry carries it.
  - *Warm-up*: indexing servers (rust-analyzer, gopls) answer poorly until
    initial analysis completes; surface `$/progress` state in the UI
    instead of failing silently or blocking.
- **The "Language Servers" catalog (working name: LSPs).** A dedicated,
  browsable surface in Settings — the user never searches the web for a
  server. It lists every curated server with its language, a one-line
  description, and status (not installed / installed vX / running with
  RSS), and an Install button that runs the consent → download → trust
  flow entirely in-app; installed entries offer update and uninstall.
  Opening a file whose language has an available-but-uninstalled curated
  server may show one quiet, dismissible hint linking to the catalog —
  never a modal, never repeated after dismissal. Each entry carries
  display name, executable and arguments, install source, version,
  checksum when published upstream, license, optional server-specific
  `initializationOptions` JSON, and runtime/project prerequisites (a Node
  runtime, `compile_commands.json` for clangd). Two entry kinds:
  - *Curated suggestions*, maintained in-app for common languages, inert
    until installed. Before any download the UI discloses "Rafu will
    download <server> <version> from <exact URL>" and requires consent;
    checksums are verified when upstream publishes them; binaries install
    into `Application Support/Rafu/LanguageServers/` with quarantine handled
    deliberately. Prefer single-binary servers (rust-analyzer, gopls,
    clangd, marksman); discover toolchain-provided servers locally instead
    of downloading (sourcekit-lsp via the installed Xcode toolchain).
    Node-hosted servers (typescript-language-server, Pyright) declare a
    runtime dependency satisfied by the shared managed Node runtime below —
    never a runtime copy per server.
  - *User-supplied entries*: a GitHub release asset URL or a local binary
    path plus arguments, configurable end-to-end in Settings. Stored in
    settings (they are not secrets), never shell-interpolated.
- **Language packs and managed runtimes** (2026-07-14 user direction). A
  pack is a curated manifest that batches several registry entries behind
  one consent — e.g. a Python pack (Pyright), a TypeScript/JavaScript pack
  (typescript-language-server, which also serves plain JS/Node projects), a
  Go pack (gopls) — with every server, version, source URL, checksum,
  license, and download size disclosed in the single confirmation.
  Installing a pack installs binaries only; lazy start is unchanged, so
  idle memory is unchanged.
  - *Shared managed Node runtime*: node-hosted servers (Pyright,
    typescript-language-server, the extracted JSON/YAML/CSS/HTML servers)
    run on one pinned Node runtime that Rafu downloads once, on first
    need, with the same consent and checksum treatment — never a runtime
    per server, and never the user's global Node. Disk layout:
    `Application Support/Rafu/LanguageServers/<server>/` plus
    `Application Support/Rafu/Runtimes/node-<version>/`. Precedent: Zed
    manages its own Node runtime for node-based servers; VS Code ships one
    inside Electron.
  - *Single-binary packs* (gopls, rust-analyzer, clangd, marksman) need no
    runtime and stay the preferred default.
  - *JVM pack* (Eclipse JDT Language Server plus a jlink-trimmed JRE) is
    the heaviest by far (hundreds of MB) and is deferred until demand
    justifies it; if added it is its own pack, never part of any default
    bundle.
  - First cut: packs are manifest-driven multi-downloads from upstream
    releases (no redistribution by Rafu). Rafu-republished offline pack
    artifacts built from Rafu's own release pipeline are a later option
    gated on license and notarization review — see open decisions.
  - Settings shows installed servers, runtimes, and packs with on-disk
    sizes and per-item uninstall.
- **Trust and privacy.** First launch of any server per workspace asks for
  explicit trust (the workspace-trust lesson); the consent copy says plainly
  that a server is arbitrary code running as the user. Document text flows
  to the local server process but never into Rafu logs (standing invariant).
- **Lifecycle bounds (ADR 0005).** Lazy start on first request; idle
  shutdown (default on, configurable interval); restart with backoff; hard
  per-server RSS ceiling that kills, notifies, and offers restart. All
  servers appear with live RSS in the Resources surface from
  [`memory-resilience.md`](memory-resilience.md).
- **Explicit non-scope:** no LSP over SSH, no semantic-token highlighting
  from LSP (Tree-sitter owns color — one tokenizer, not two), no auto-start
  on workspace open, no marketplace, no extension host.

Stage gate: the ladder demonstrably degrades — killing a server mid-session
drops navigation to the syntactic tier with correct labeling and no error
dialogs; a misbehaving server hits its ceiling and dies without touching
typing latency.

## Acceptance contract

1. Bundled-language highlighting is incremental Tree-sitter, with signpost
   evidence of changed/visible-range-only work.
2. Palette `@` symbols come from captures for bundled languages, regex
   fallback otherwise.
3. Workspace symbol search, Go to Definition/Declaration, and Find
   References work with zero configuration on all bundled grammars, labeled
   syntactic, with peek-list disambiguation.
4. From the Language Servers catalog, discovery to working navigation
   completes entirely in-app — browse, explicit consent naming the exact
   source URL and version, download, per-workspace trust — with no web
   browser involved. A pack batches several servers (and at most one
   shared runtime) into one confirmation that lists every component and
   its size; binaries land in Application Support.
5. A user-supplied server (GitHub release asset or local path) is
   configurable end-to-end without hand-editing files.
6. LSP-tier navigation answers definition, declaration, references, and
   hover, labeled with the server name.
7. Server lifecycle is bounded: lazy start, idle shutdown, ceiling
   kill-and-notify, restart affordance; visible in Resources with RSS.
8. Killing a server degrades navigation to the syntactic tier without error
   dialogs or typing impact.
9. No document text, diffs, or request bodies appear in logs, re-verified
   against the LSP path.
10. Memory: an idle workspace with no servers running matches the pre-phase
    baseline; each running server is attributed in Resources, never absorbed
    into Rafu's own number.

## Architecture locks

- All process spawning uses executable plus argument arrays; server
  arguments from settings pass as array elements, never through a shell.
- LSP client code sits behind a replaceable boundary (a dedicated
  `LanguageIntelligence/` module path chosen by the integration owner), the
  way SwiftTerm stays inside `Terminal/`.
- The syntax actor, symbol index, and LSP client are cancellable, off-main,
  and `Sendable`-reviewed; the `swift-concurrency-pro` review path is
  mandatory for each stage.
- Views never speak JSON-RPC; they consume small observable metadata (tier,
  server state, result lists) per the observation invariant.

## Verification

- Stage-scoped Swift Testing: JSON-RPC framing and parsing (pure),
  capture→token mapping, index caps and incremental updates, ladder
  resolution policy (pure), registry validation.
- The synthetic 100k-file monorepo procedure for index costs; Release-build
  RSS per acceptance item 10.
- Manual pass per stage: second window, keyboard reachability for every new
  command (menu plus palette), VoiceOver labels on peek, consent, and trust
  UI.

## Parallel worktree split (contract-first)

Two lanes may run concurrently after the initial commit (worktrees cannot
exist before it) — lane 1: memory resilience plus Stages A and B; lane 2:
Stage C alone.

**Contract commit** — integration-owned, lands on main before fan-out; both
lanes build against it and neither edits it afterward:

1. Navigation types and ladder: `NavigationRequest` (kind: definition /
   declaration / references / hover; document URL; UTF-16 position;
   language ID), `SymbolCandidate`, `NavigationAnswer` (tier label,
   candidates, state) — all `Sendable` — plus a `NavigationTierProvider`
   protocol and the `NavigationLadder` resolver, shipping with the text
   tier as its only default provider.
2. `ProcessResourceRegistry` actor: register/unregister of (name, kind,
   pid) plus RSS sampling. Lane 1's Resources surface reads it; lane 2's
   servers register into it; terminal shells and git adopt it opportunely.
3. `DocumentEditDelta` publisher seam on the editor document (edited UTF-16
   range, replacement length, revision — the plan §7.5 step-2 shape).
   Stage A's syntax actor parses from it; Stage C feeds incremental
   `didChange` from the same stream.
4. A `LanguageIntelligenceCoordinator` stub (type owned by lane 2) wired
   into `WorkspaceSession` as exactly one property plus lifecycle call
   sites — lane 2 never edits `WorkspaceSession.swift` beyond this seam.
5. An empty "Language Servers" settings pane file (lane 2 owns its
   contents) and reserved command IDs/names for all new commands.

**Ownership rules:**

- Lane 1 owns `Package.swift`/`Package.resolved` (grammar targets),
  `WorkspaceSession.swift`, editor and syntax paths, the navigation UI
  (commands, peek list — it consumes `NavigationAnswer` regardless of
  tier), and the Resources surface.
- Lane 2 owns `Sources/RafuApp/LanguageIntelligence/` (client, registry,
  catalog pane, packs, runtime manager) and its tests. Constraints: no new
  package dependencies (hand-rolled JSON-RPC keeps it out of
  `Package.swift`, consistent with the Foundation-first rule), no
  navigation UI (it supplies a provider only), verification by tests and a
  debug harness until integration.

**Merge policy:** increments merge to main when green — no long-lived
mega-branches; lane 2 rebases after each lane-1 landing. One final
integration round registers the LSP provider in the ladder (one call) and
runs the ladder-degradation end-to-end checks.

## Open decisions

- User-supplied Tree-sitter grammars (dynamic code loading) — deferred;
  needs its own ADR.
- Diagnostics/rename/code-actions slice — scoped only after Stage C ships
  and holds its budgets.
- LSP over SSH — out of scope; a new ADR if demanded.
- Rafu-republished offline language packs (redistributing third-party
  server binaries and runtimes as Rafu release artifacts) — needs license
  review per component (EPL for JDT LS, runtime licenses) and a
  signing/notarization story for shipped third-party binaries before
  adoption.
- The JVM pack (Java via JDT LS + trimmed JRE) — deferred until demand;
  size and JRE servicing burden must be weighed explicitly.
