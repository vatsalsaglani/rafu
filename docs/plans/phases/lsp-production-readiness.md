# Lane plan — LSP production readiness

## Status

Planned (2026-07-17). One of six post-audit lanes defined in
[`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md). Runs in a
**dedicated git worktree**. Successor to
[`lane-2-lsp-plan.md`](lane-2-lsp-plan.md): Stage C shipped and is fully
integrated; this lane takes it from "installs and navigates in the happy
path" to "production-usable for the curated set." Governed by
[ADR 0005](../../decisions/0005-language-intelligence-and-lsp.md). Each
increment is one advisor → implementor → verification → documentor cycle.
File:line anchors reflect the tree on 2026-07-17; the repository wins when
they disagree.

## Verified baseline (corrects stale assumptions)

Already DONE — do not re-do, do not re-touch:

- Provider registered in `NavigationLadder`
  (`WorkspaceSession.swift:731–740`).
- Trust prompt mounted (`WorkspaceWindowView.swift:87,122–134`).
- `ProcessResourceRegistry.shared` shared between the manager
  (`LanguageIntelligenceCoordinator.swift:197`) and `ResourcesView.swift:124`.
- Null-result decline resolved (`LSPTypes.swift:283–288`,
  `JSONRPCMessage.swift:229,241`, `JSONRPCConnection.swift:80`).
- Node runtime checksum is REAL and verified
  (`NodeRuntimeManager.swift:13,22–23`, pinned in commit `57a8dbc`) — the
  "all-zero placeholder" note in older docs is stale.

Real gaps:

- **G1 — npm:** no npm dependency step anywhere in
  `ServerInstaller.install` (`ServerInstaller.swift:374–411`);
  typescript-language-server installs but cannot launch (its descriptor
  notes this, `CuratedCatalog.swift:210–215`). Pyright is the
  self-contained counter-example.
- **G2 — catalog trust:** all downloadable entries carry unverified
  versions/URLs and `checksum: nil` (rust-analyzer `:96–99` — the
  `2024-01-01` tag is almost certainly wrong; clangd `:117–121`; marksman
  `:141–145`, license GPL-3.0-only flagged; typescript-language-server
  `:198–202`; pyright `:227–233`). gopls and sourcekit-lsp are
  localDiscovery — nothing to verify.
- **G3 — warm-up:** `ClientCapabilities` has no `window` capability
  (`LSPTypes.swift:27–35`) and `JSONRPCConnection.handleIncomingRequest`
  (`JSONRPCConnection.swift:180–191`) replies `-32601` to
  `window/workDoneProgress/create`, so real-server indexing never surfaces
  as `.indexing`; `LanguageServerStatus.Phase.warmingUp` is never driven.
- **G4 — sourcekit-lsp references:** `sourceKitLSP.initializationOptions:
  nil` (`CuratedCatalog.swift:182`) → no background indexing → cross-file
  references empty. The plumbing exists end-to-end
  (`ServerRegistry.swift:76` → `LanguageServerDependencies.swift:16` →
  `LanguageServerSession.swift:44,95` → `LSPTypes.swift:43`).
- **G5 — validation:** no repeatable live gopls/rust-analyzer checklist.

## Global rules for this lane

- **Owned paths:** `Sources/RafuApp/LanguageIntelligence/**` (entire
  subsystem), the matching test files under `Tests/RafuAppTests/`
  (NodeDependencyResolver [new], ServerInstaller, CuratedCatalog,
  NodeRuntimeManager, InstalledServerResolver, JSONRPCConnection,
  LanguageServerSession, LSPNavigationProvider,
  LanguageServersCatalogModel, trust-flow tests + fixtures), and this plan
  document.
- **Forbidden paths:** `Sources/RafuApp/Models/WorkspaceSession.swift` (the
  provider is already wired — verified; no edit needed),
  `Sources/RafuApp/Views/**` (trust prompt already mounted),
  `Sources/RafuApp/Navigation/**`, `Sources/RafuApp/Editor/**`,
  `Sources/RafuApp/Services/**` (incl. `ProcessResourceRegistry.swift` —
  already shared), `Sources/RafuApp/Markdown/**`, `Sources/RafuCLI/**`,
  `Sources/RafuCore/**`, `AGENTS.md`, `CLAUDE.md`, shared doc indexes
  (single appends at merge per the fan-out plan).
- **`Package.swift`/`Package.resolved` must not change** — npm runs under
  the already-managed Node runtime; if a step appears to need a new
  package, stop and escalate. This is the property that keeps the lane
  conflict-free.
- No logging of URLs, npm arguments, document text, or server payloads.
  The server→client dispatch edit (P3) and the installer edits (P1) take
  the `swift-concurrency-pro` review path and the AGENTS.md security
  review.
- All tests fully offline: `FixtureAssetDownloader`, fake dependency
  resolver, in-memory transport + scripted server.
- Verification per increment: `swift build`, `swift test`,
  `./script/format.sh --fix` then `--lint` (note: keep `ArchiveLayout`'s
  memberwise init synthesized — the `UseSynthesizedInitializer` lint rule);
  `./script/build_and_run.sh --verify` only for P2's consent-UI change and
  the P5 live pass — never while another lane runs it.
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.

## P1 — Warm-up handshake (G3; smallest, do first — unblocks live validation)

- `LSPTypes.swift`: add `WindowClientCapabilities { workDoneProgress:
  Bool? }` + a `window:` field on `ClientCapabilities` (:33–35);
  `LanguageServerSession.initialize()` (:92) advertises
  `workDoneProgress: true`.
- `JSONRPCMessage.swift`: add `JSONRPCSuccessResponseEnvelope` encoding
  `{"jsonrpc":"2.0","id":…,"result":null}` (mirror
  `JSONRPCErrorResponseEnvelope` at :253).
- `JSONRPCConnection.handleIncomingRequest` (:180 — the seam the file's
  doc comment reserves): reply success to `window/workDoneProgress/create`
  only; keep `-32601` for every other method. Minimal by design — this is
  a server→client security surface.
- Tests: scripted server sends the create request → success (null-result)
  envelope, not `-32601`; `initialize` params carry
  `window.workDoneProgress == true`; scripted `$/progress` begin/end flips
  `isWarmingUp`; `LSPNavigationProvider` returns `.indexing` while warming.

## P2 — npm dependency resolution (G1)

- New `Registry/NodeDependencyResolver.swift`:
  `protocol NodeDependencyResolving: Sendable` (the injected seam) +
  `NpmDependencyResolver`, which derives npm's CLI entry from the node
  executable (`../../lib/node_modules/npm/bin/npm-cli.js`) and spawns, via
  the existing argv-only `ArchiveUnpacker.runArgv`, `node <npm-cli.js>
  install --omit=dev --no-audit --no-fund --ignore-scripts
  --no-package-lock --prefer-offline` with `currentDirectory =
  packageDirectory`. `--ignore-scripts` is mandatory (no lifecycle-script
  execution). Non-zero exit → a typed install error.
- `ServerInstaller.swift`: `runArgv` gains `currentDirectoryURL:` (default
  nil) rather than duplicating spawn logic; `install` gains
  `nodeExecutableURL: URL? = nil` + an injected resolver (init pattern
  mirrors `downloader`); the npm step runs **in staging, after
  `StagingValidator.validate` (:407) and before
  `AtomicDirectoryReplacer.replace` (:411)** so `node_modules/` is part of
  the atomic install. `npmPackageRoot` set but `nodeExecutableURL` nil →
  throw.
- `ServerRegistry.swift`: `ArchiveLayout.npmPackageRoot: String?` —
  optional so legacy `language-servers.json` decodes unchanged (no schema
  bump; add a legacy-decode test).
- `CuratedCatalog.swift`: typescript-language-server sets
  `npmPackageRoot: "package"`; Pyright stays nil.
- `LanguageServersCatalogModel.performInstall` (:291) and
  `performInstallPack` (:324): capture the URL from
  `nodeRuntime.ensureInstalled(...)` (currently **discarded** at :293) and
  pass it to `installer.install`.
- `ServerInstallConsentView`: disclosure that installing this server also
  runs `npm install`, fetching additional unpinned packages from
  registry.npmjs.org (see the ADR flag below).
- Tests: fake resolver records its `packageDirectory` and fabricates
  `node_modules/typescript/` → assert it survives the atomic move; missing
  node URL throws; Pyright-shaped fixture never invokes the resolver;
  legacy `ArchiveLayout` JSON decodes.

**ADR 0010 (reserved by the fan-out plan) — npm supply chain.** Unpinned
transitive npm fetch breaks the checksum-everything model. Options: accept
with `--ignore-scripts`/`--omit=dev` mitigations and consent disclosure, or
vendor a `package-lock.json`/offline cache per entry. Decide and record
before typescript-language-server is advertised as runnable; the same ADR
records the checksum-source policy (locally-computed SHA-256 pin,
trust-on-first-download, vs an algorithm-tagged digest type — do not build
the type extension speculatively).

## P3 — sourcekit-lsp background indexing (G4)

- `CuratedCatalog.swift:182`: `sourceKitLSP.initializationOptions =
  .object(["backgroundIndexing": .bool(true)])`.
- Tests: catalog assertion + scripted-handshake round-trip of the flag.
- Docs: references populate only after sourcekit-lsp finishes background
  indexing (needs a project build); older versions ignore the flag
  (harmless); confirm the exact key against the shipped toolchain during
  P5; text tier remains the floor.

## P4 — Catalog verification constants (G2; human network gate)

Code in this increment is small (checksum-policy doc comment on the
descriptor + a test asserting non-nil checksums once pinned). The constant
edits are gated on a human/coordinator with network access running:

1. Per downloadable entry: `curl -fsSL -o asset <url>`; confirm HTTP 200
   and that the pinned version matches the resolved release/tag.
2. `shasum -a 256 asset` → paste into `checksum:`; cross-check upstream
   digests where published.
3. npm entries: fetch the packument, confirm `dist.tarball` matches, cross
   check `dist.integrity` (SHA-512); still pin Rafu's SHA-256 of the exact
   bytes.
4. Confirm each license at the pinned tag (marksman GPL-3.0-only
   especially).
5. Exact constants that change: rust-analyzer `:96,98,99`; clangd
   `:117,120,121`; marksman `:141,143,144,145`; typescript-language-server
   `:198,200,202`; pyright `:227,230,233`. Node is already verified —
   leave unless bumping.

If upstream re-publishes same-version bytes, the pin correctly fails the
install; the re-pin path is this same procedure.

## P5 — Live validation checklist (G5; manual, repeatable)

Per server (gopls on a Go module; rust-analyzer on a Cargo crate):

1. `./script/build_and_run.sh --verify`; open the sample repo.
2. Settings ▸ Language Servers: gopls discovered (localDiscovery);
   rust-analyzer installs with the consent sheet naming
   URL/version/size/license/checksum.
3. First navigation raises the trust sheet; approve.
4. Go to Definition / Find References land; tier label reads
   `"via gopls"` / `"via rust-analyzer"`.
5. During initial indexing the `.indexing` state shows (validates P1).
6. Resources surface shows the server row with RSS.
7. `kill <pid>` → navigation falls through to syntactic/text without a UI
   error; the row shows the crash/restart affordance.

Also validate typescript-language-server end-to-end once P2 + P4 land
(install → npm resolve → trust → navigate in a TS repo), and sourcekit-lsp
references after a project build (P3).

## Risks

- npm needs network at install time — offline tests use the fake resolver;
  a real install is never CI-verified (same posture as the download seam).
- `node_modules/` in temp staging enlarges the known cross-volume
  non-atomic `moveItem` residual (rollback still restores the prior
  install).
- npm-installed native addons could be unsigned (AMFI SIGKILL on arm64) —
  typescript-language-server's deps are pure JS; record as residual.
- rust-analyzer's pinned tag is a from-memory guess; P4's gate is the only
  fix — do not ship the catalog as "verified" before it runs.

## Exit

- typescript-language-server installs AND launches (npm step, consent
  disclosed, ADR 0010 decided).
- Every downloadable catalog entry has a human-verified URL/version and a
  pinned SHA-256.
- Real gopls/rust-analyzer drive `.indexing` via `$/progress`; the P5
  checklist run with captured evidence (tier labels, RSS row,
  kill-fallthrough).
- sourcekit-lsp cross-file references work after background indexing.
- All offline suites green; no Package.* diff; forbidden paths untouched.
