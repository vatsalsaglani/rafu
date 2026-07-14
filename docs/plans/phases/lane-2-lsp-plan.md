# Lane 2 execution plan — Stage C opt-in LSP client

## Status

Execution plan for lane 2 of the split defined in
[`language-intelligence.md`](language-intelligence.md), governed by
[ADR 0005](../../decisions/0005-language-intelligence-and-lsp.md). Runs in a
**dedicated git worktree** created from the commit that contains lane 1's
increment 0 (the contract commit) — do not start before that commit exists
in the branch history. Increments C0–C5; each is one advisor → implementor →
verification → documentor cycle.

## Global rules for this lane

- Owned paths: `Sources/RafuApp/LanguageIntelligence/` (including the
  coordinator stub created by the contract commit),
  `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift`, matching
  test files under `Tests/RafuAppTests/`, and this plan document.
- **Forbidden paths** (lane 1 owns them): `Package.swift`,
  `Package.resolved`, `Sources/RafuApp/Models/WorkspaceSession.swift`,
  everything else under `Sources/RafuApp/Editor/`, `Views/`, `Navigation/`
  (lane 2 *reads* the navigation and registry contracts, never edits them),
  `AGENTS.md`, shared doc indexes. If work appears to require editing a
  forbidden path, stop and escalate to the user instead of editing.
- **No new package dependencies.** JSON-RPC framing is small; hand-roll it
  on Foundation. This is what keeps `Package.swift` conflict-free.
- Verification: `swift build`, `swift test`, `./script/format.sh --fix`
  then `--lint`. This lane verifies headlessly by design (in-memory
  transport, below); run `./script/build_and_run.sh --verify` only for
  increment C4's UI pass, and never while lane 1 is running it — the script
  kills any running staged Rafu.app.
- All actors and process I/O take the `swift-concurrency-pro` review path.
  Increments C3–C4 additionally require the AGENTS.md security review
  (downloads, quarantine, trust, process spawn).
- Never log document text, server request/response bodies containing
  document content, or download URLs joined with user tokens. Server stderr
  goes to a bounded ring buffer only.
- After each green increment the coordinator stops and asks the user to
  commit. Before starting each increment, ask the user whether to sync the
  worktree branch with the main branch first.

## C0 — JSON-RPC framing and transport

New files under `Sources/RafuApp/LanguageIntelligence/`:

- `JSONRPC/JSONRPCMessage.swift` — Codable request/notification/response;
  id as int-or-string union; standard error object.
- `JSONRPC/JSONRPCFraming.swift` — `Content-Length` header framing: encoder
  plus an incremental decoder that accepts arbitrary byte chunks and yields
  complete messages (pure, no I/O).
- `JSONRPC/JSONRPCConnection.swift` — actor: request/response correlation
  via continuation map, notification `AsyncStream`, `$/cancelRequest` on
  Swift task cancellation, connection teardown fails all pending requests.
- `Transport/LanguageServerTransportProtocol.swift` — byte-in/byte-out
  protocol so tests can inject an in-memory pair. **This protocol is the
  key to headless verification for the whole lane.**
- `Transport/LanguageServerProcessTransport.swift` — `Process` + pipes,
  executable + argument-array spawn only, stdout reader off the main actor,
  stderr → bounded buffer, termination handler surfaces exit status.

Tests: framing round-trips, partial/multi-message chunk reassembly, id
correlation, cancellation, teardown. All pure or in-memory.

## C1 — LSP protocol layer and server session

- `LSP/LSPTypes.swift` — only the needed subset: initialize handshake types
  with **lenient decoding** of `ServerCapabilities` (unknown fields and
  either-shape unions are normal across servers), text document sync types,
  Position/Range/Location, definition/declaration/references/hover/
  documentSymbol, `$/progress`. Position encoding negotiation (client
  offers utf-16 first — native for TextKit; utf-8 conversion helpers with
  dedicated tests). `file://` URI ↔ path mapping helpers
  (percent-encoding).
- `LSP/LanguageServerSession.swift` — actor; state machine: spawned →
  initializing → ready → idle → shuttingDown → dead. Capability-gates every
  feature per server (a server without `referencesProvider` yields decline,
  not error). `DocumentEditDelta` → incremental `didChange`, with
  full-text-sync fallback when the server demands it. Per-request timeout
  returns decline.

Tests: state transitions (pure), capability gating, encoding conversion,
scripted handshake over the in-memory transport.

## C2 — Lifecycle manager and resource bounds

- `LanguageServerManager.swift` — per-workspace: one session per
  languageID; lazy start on first navigation request; idle shutdown via a
  cancellable sleeping task reset on activity (no repeating timers);
  restart backoff (1 s / 5 s / 30 s, then manual restart only); RSS ceiling
  watchdog sampling through the shared `ProcessResourceRegistry` — over
  ceiling ⇒ terminate, notify, offer restart. Registers/unregisters every
  server pid in `ProcessResourceRegistry` (kind `.languageServer`) so lane
  1's Resources surface attributes them with zero cross-lane edits.
- Fill in `LanguageIntelligenceCoordinator.swift` (owned since the contract
  commit): owns the manager, forwards document lifecycle from the session
  seam, exposes small observable metadata (per-server state) for UI.

Tests: idle-shutdown policy, backoff policy, ceiling decision (all pure) +
manager behavior over in-memory transports.

## C3 — Registry, curated catalog, installer, managed Node runtime

- `Registry/ServerRegistry.swift` — Codable descriptor: id, languageIDs,
  displayName, kind (singleBinary / nodeHosted / localDiscovery), source
  (URL, version, checksum?, license), args, `initializationOptions` JSON,
  prerequisites. User entries persisted to
  `Application Support/Rafu/language-servers.json` with atomic writes
  (settings, not secrets — never Keychain, never shell-interpolated).
- `Registry/CuratedCatalog.swift` — static entries: rust-analyzer, gopls,
  clangd, marksman (single binaries); sourcekit-lsp (localDiscovery via the
  Xcode toolchain — no download); typescript-language-server and Pyright
  (nodeHosted, prerequisite: managed Node runtime). Every entry: exact
  https source URL, pinned version, license, size estimate.
- `Registry/ServerInstaller.swift` — URLSession download → temp → checksum
  verify (when published) → unpack via `/usr/bin/tar` or `/usr/bin/ditto`
  with argument arrays → install under
  `Application Support/Rafu/LanguageServers/<id>/` → executable bit.
  Quarantine handling is consent-gated and per-install, never a blanket
  strip; the exact mechanism and its rationale go in a security reference
  note.
- `Registry/NodeRuntimeManager.swift` — one pinned Node runtime under
  `Application Support/Rafu/Runtimes/node-<version>/`, installed once on
  first nodeHosted install, same consent + checksum treatment.
- `Registry/WorkspaceTrustStore.swift` — per-workspace approved-server ids,
  persisted in Application Support.

Tests: descriptor codec, catalog validation (https-only, versions pinned,
no duplicate ids), installer path math and archive-name parsing (pure),
trust-store round-trip. **No live-network tests** — fixture-driven.

## C4 — Language Servers catalog UI and trust flow

- Fill `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift`: the
  browsable catalog per the phase doc — status per server (not installed /
  installed vX / running with RSS), Install with the consent sheet naming
  exact URL, version, size, license, checksum; progress and cancel;
  uninstall; update; user-supplied entry form (GitHub release asset URL or
  local binary + args + language); pack rows batching servers + runtime
  into one disclosure.
- First-launch-per-workspace trust prompt raised from the coordinator when
  a navigation request would start an untrusted server; decline ⇒ decline
  tier (fall through), remembered until changed in settings.
- Keyboard reachability and VoiceOver labels on every row/sheet; this is
  the one increment with a GUI verification pass in the worktree.

## C5 — LSP navigation provider and merge-readiness

- `LSPNavigationProvider.swift` — implements `NavigationTierProvider`: maps
  `NavigationRequest` → session request via the manager; short timeout ⇒
  decline (`nil`) so the ladder falls through; answers labeled
  `via <serverName>`; warm-up (`$/progress` active) returns
  state `.indexing` rather than empty results.
- **Do not register the provider in the ladder** — `NavigationLadder`
  wiring is lane 1 territory; registration is one line in the
  post-merge integration round.
- End-to-end tests over in-memory transport with a scripted fake server:
  open → didChange → definition/references round-trip; kill-server
  degradation (provider declines, never throws to UI); ceiling kill.
- Merge-readiness checklist the coordinator verifies before declaring the
  lane done: no forbidden-path diffs (`git diff --stat` audited), no new
  dependencies, all tests green, security review notes written, docs
  updated, handoff summary prepared (delivered behavior, changed paths,
  evidence, risks, integration steps).

## Integration (after merge, runs in the main checkout)

One small round: register `LSPNavigationProvider` in the ladder above the
syntactic tier; verify tier labels and degradation end-to-end with a real
server (gopls or rust-analyzer on a sample repo); confirm server rows appear
in the Resources surface; run the full lane-1 + lane-2 test suite together.
