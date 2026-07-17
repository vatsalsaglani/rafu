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

### Completion record — C0 delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean; `swift test` 186 tests pass; format lint clean; zero forbidden-path edits; no new package dependencies.

**Changed paths:** All new files under `Sources/RafuApp/LanguageIntelligence/`:
- `JSONRPC/JSONRPCMessage.swift`, `JSONRPCFraming.swift`, `JSONRPCConnection.swift`
- `Transport/LanguageServerTransportProtocol.swift`, `LanguageServerProcessTransport.swift`
- Test files: `Tests/RafuAppTests/InMemoryLanguageServerTransport.swift`, `JSONRPCMessageTests.swift`, `JSONRPCFramingTests.swift`, `JSONRPCConnectionTests.swift`, `LanguageServerProcessTransportTests.swift`

**Key C1-facing contracts (implement depends on these):**
1. `JSONRPCConnection.start()` **must be called** before sending requests; without it, the read loop never drains responses and all requests hang.
2. **Concurrent-request write-ordering caveat:** `sendRequest(_:)` defers transport writes to an unstructured `Task`; concurrent callers have no wire ordering guarantee. Sequential `await` of send operations (e.g., `didOpen` then `didChange`) preserves order.
3. `handleIncomingRequest(_:)` (currently auto-replying `-32601` not-implemented) is the designed seam C1 replaces to implement request dispatch.

**Verified nuances documented for future reference:**
- Explicit `nonisolated` required on all new types (actor + nested) due to `.defaultIsolation(MainActor.self)` in RafuApp target.
- `Data` slice index hazard: slice retains parent indices; body extraction must copy and re-base.
- `"result": null` vs missing `result`: envelope uses `container.contains(.result)` flag to distinguish explicit null from protocol violation.
- `Synchronization.Mutex` (macOS 15+) safely gates off-actor stderr ring-buffer appends from `Process` readability handler.

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

## Increment status

### C0 — JSON-RPC framing and transport — delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean (no warnings); `swift test` 186 tests
pass; `./script/format.sh --lint` clean; zero forbidden-path edits; no new
package dependencies.

**Changed paths** (all new files):

- `Sources/RafuApp/LanguageIntelligence/JSONRPC/JSONRPCMessage.swift`,
  `JSONRPCFraming.swift`, `JSONRPCConnection.swift`
- `Sources/RafuApp/LanguageIntelligence/Transport/LanguageServerTransportProtocol.swift`,
  `LanguageServerProcessTransport.swift`
- `Tests/RafuAppTests/InMemoryLanguageServerTransport.swift`,
  `JSONRPCMessageTests.swift`, `JSONRPCFramingTests.swift`,
  `JSONRPCConnectionTests.swift`, `LanguageServerProcessTransportTests.swift`

**C1-facing contracts** (the next increment depends on these):

1. `JSONRPCConnection.start()` **must be called** before sending requests;
   without it the read loop never drains responses and every request hangs.
2. **Concurrent-request write-ordering caveat:** `sendRequest(_:)` defers its
   transport write to an unstructured `Task`, so concurrent callers have no
   wire-ordering guarantee. Sequential `await` of send operations preserves
   order, so the session must `await` ordering-sensitive notifications
   (`didOpen` before `didChange`) before issuing dependent requests.
3. `handleIncomingRequest(_:)` (currently auto-replying `-32601`
   method-not-found) is the single designed seam C1 replaces to implement real
   server-to-client request dispatch.

**Verified nuances** (full reference note drafted; pending filing into
`docs/references/` + its shared index during the post-merge integration round):

- Explicit `nonisolated` is required on every new top-level and actor-nested
  type because the RafuApp target uses `.defaultIsolation(MainActor.self)`.
- `Data` slice index hazard: slices preserve the parent's indices, so body
  extraction must copy (`Data(buffer[range])`) and re-base off `startIndex`.
- `"result": null` vs a missing `result` key: the response envelope uses
  `container.contains(.result)` to keep a legal null result distinct from a
  protocol violation.
- `Synchronization.Mutex` is production-safe on this `.macOS(.v15)` package and
  gates the off-actor stderr ring-buffer append from the `Process` readability
  handler without an actor hop.
- Hermetic process-transport testing uses `/bin/cat` (echo stdin→stdout) with a
  bounded grace-poll `close()` so a clean stdin-EOF exit is not escalated to
  SIGTERM.

### C1 — LSP protocol layer and server session — delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean; `swift test` 218 tests pass;
`./script/format.sh --lint` clean; **zero C0 edits** and zero forbidden-path
edits; no new package dependencies.

**Changed paths** (all new files):

- `Sources/RafuApp/LanguageIntelligence/LSP/LSPTypes.swift` — handshake types,
  lenient `ServerCapabilities` (`BoolOrOptions`, number-or-object
  `TextDocumentSyncSetting`), `Position`/`LSPRange`/`Location`/`LocationLink`,
  sync notification params, null-tolerant result unions
  (`LocationsResult`/`HoverResult`/`DocumentSymbolResult`), `$/progress` types,
  `PositionEncoding`, `DocumentTextMirror` (UTF-16↔UTF-8 conversion), and
  `file://` URI↔path helpers.
- `Sources/RafuApp/LanguageIntelligence/LSP/LanguageServerSession.swift` — the
  `actor`: handshake (timeout-bounded), capability gating, document sync,
  offset-based nav entry points (per-request timeout → decline), graceful
  shutdown, state machine incl. `.idle`.
- Tests: `LSPTypesTests.swift`, `LSPPositionEncodingTests.swift`,
  `LSPURITests.swift`, `LanguageServerSessionTests.swift` (scripted server over
  the C0 in-memory transport).

**C2-facing contracts / dependencies:**

1. Sync is fed by `didChange(uri:delta:newFullText:)` — C2's coordinator reads
   the full post-edit text via `EditorDocument.textSnapshotProvider?()` on the
   main actor after each `editDeltas()` delta and passes it. For large files
   this per-keystroke full-text read is a C2 optimization target (debounce /
   coalesce), not a correctness issue; the session mirror is drift-free
   (replaced with `newFullText` each change).
2. External reload uses `resync(uri:fullText:)` (no delta available).
3. The session exposes `state` (incl. `.idle`) and an in-flight counter but
   starts **no** idle-shutdown timer — C2 owns lazy-start, the idle timer,
   restart backoff, and RSS-ceiling policy, plus `ProcessResourceRegistry`
   registration.

**C5-facing dependencies:**

1. `isWarmingUp` is set by parsing `$/progress` **notifications**, but C1 does
   **not** advertise `window.workDoneProgress` and keeps C0's `-32601` reply to
   server→client requests — so real rust-analyzer/gopls indexing progress does
   not yet flow. C5 completes warm-up: advertise the capability + reply to
   `window/workDoneProgress/create` (a minimal, owned-file C0 seam extension),
   then read `isWarmingUp` to return `NavigationAnswer.State.indexing`.
   `isWarmingUp` is currently a coarse boolean (no per-token tracking); C5
   should track progress tokens if flicker with multiple concurrent tokens
   matters.
2. Nav entry points return `nil` = decline (fall through) vs an authoritative
   empty answer; C5 maps `[Location]`/`Hover`/`DocumentSymbolResult` to
   `SymbolCandidate`/`NavigationAnswer` and converts the frozen-contract UTF-16
   `NavigationRequest.position` offset via the session (which owns the mirror).

**Verified nuances** (for the integration-round reference note):

- `String.Index(_ utf16Offset:within:)` does **not** exist on this toolchain;
  UTF-16-offset→`String.Index` must be done by a `unicodeScalars` walk (caching
  indices or an explicit helper), which also correctly rejects mid-surrogate
  offsets by returning `nil` instead of trapping.
- A same-module top-level `struct Range` would shadow `Swift.Range` target-wide;
  the LSP range type is named `LSPRange`.
- One-directional wire types are `Decodable`-only or `Encodable`-only
  (`ServerCapabilities`/`InitializeResult` decode-only;
  `DidChangeTextDocumentParams`/`TextDocumentContentChangeEvent` encode-only) —
  making them full `Codable` would fabricate an unused, untested half.
- Diagnosing an actor deadlock under parallel `swift test`: a genuine deadlock
  shows near-zero cumulative CPU over real minutes; `swift test --filter <name>`
  in isolation bisects the hanging test fastest.

### C2 — Lifecycle manager and resource bounds — delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean; `swift test` 242 tests pass (stable
across 8+ repeated runs); `./script/format.sh --lint` clean; **zero C0/C1
edits** and zero forbidden-path edits; no new package dependencies. Two
scheduling-dependent concurrency defects found in coordinator review were fixed
with regression tests before sign-off.

**Changed paths:**

- `Sources/RafuApp/LanguageIntelligence/LanguageServerLifecycle.swift` (new) —
  pure policy value types: `RestartBackoffPolicy` (1 s/5 s/30 s → manual),
  `LanguageServerLifecycleBounds` (idle 300 s, stability 30 s, RSS ceiling
  4 GB default, sample 5 s), `RSSCeilingDecision`, `LanguageServerStatus`.
- `Sources/RafuApp/LanguageIntelligence/LanguageServerDependencies.swift` (new)
  — `LanguageServerResolving`/`ResolvedLanguageServer`/`NoLanguageServersResolver`
  and `LanguageServerSpawning`/`SpawnedLanguageServer`/`ProcessLanguageServerSpawner`.
- `Sources/RafuApp/LanguageIntelligence/LanguageServerManager.swift` (new) — the
  lifecycle-owning `actor`.
- `Sources/RafuApp/LanguageIntelligence/LanguageIdentifier.swift` (new) —
  extension → LSP languageId.
- `Sources/RafuApp/LanguageIntelligence/LanguageIntelligenceCoordinator.swift`
  (filled) — owns the manager, forwards the four frozen non-async hooks via
  independent `Task`s, self-subscribes each document's `editDeltas()`, exposes
  `LanguageServerStatusStore`.
- Tests: `LanguageServerLifecycleTests`, `LanguageServerManagerTests`,
  `LanguageIntelligenceCoordinatorTests`, `LanguageIdentifierTests`.

**Key architectural decisions (accepted in review):**

- **Registry sharing is DEFERRED — integration handoff.** There is no shared
  `ProcessResourceRegistry` owner in this branch (it is referenced only by its
  own file + tests; lane 1's Resources surface is not yet built). The manager
  therefore holds its **own injected** `ProcessResourceRegistry` (default fresh
  instance) and registers/unregisters server pids against it. **Post-merge
  integration must wire the manager's registry to the same instance the
  Resources surface reads** (a constructor argument in lane-1 territory) — until
  then, server RSS is tracked but not user-visible. This is the same shape as
  the deferred `NavigationLadder` provider registration.
- **C3 seam:** `LanguageServerResolving` (default `NoLanguageServersResolver`
  returns nil, so the coordinator is inert in production until C3). C3's
  registry/catalog provides the real conformer with no manager edit.
- **RSS ceiling default 4 GB**, per-server overridable via
  `ResolvedLanguageServer.rssCeilingBytes` (ADR 0005's revisit trigger warns
  against killing legitimate large-repo servers). **Idle timeout 300 s.**

**C4/C5-facing:** `session(forLanguageID:)` on the coordinator (→
`manager.ensureSession`) is the only entry point C5's provider needs; nothing is
registered in `NavigationLadder`. `LanguageServerStatusStore.statuses` is the
observable per-server metadata (phase, RSS, crashes) C4's UI consumes.
`LanguageServerStatus.Phase.warmingUp` exists but is not yet driven (C1's
`isWarmingUp` isn't wired into pushed statuses) — C4/C5 should wire it when
warm-up is completed, or drop the case.

**Verified concurrency nuances (for the integration-round reference note):**

- Intentional shutdown must remove the server from the tracking map **before**
  awaiting `session.shutdown()`; otherwise the process exit resolves the
  supervision task's `awaitTermination()` and its `handleTermination` races to
  misclassify the intentional stop as a crash. All stop paths (idle, ceiling,
  restart, deactivate) now do tearDown-then-shutdown; the supervision task
  no-ops on a `registryID` mismatch.
- An in-flight spawn must be guarded by an **activation epoch**: if the
  workspace is deactivated (or re-activated) during the spawn, `finishStart`
  discards + shuts down the spawned session instead of adopting an orphan.
- A `@MainActor`-isolated class is implicitly `Sendable`, so it can be captured
  into a `@Sendable` closure and touched inside `MainActor.run` — this is how
  the coordinator hands its main-actor `OpenDocumentIndex` to the manager's
  `snapshotProvider` without a data race.
- A fire-and-forget status-push `Task` means status assertions in tests must
  poll (`waitUntil`) for the specific expected status, never read `.last` once.

### C3 — Registry, curated catalog, installer, Node runtime — delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean; `swift test` 301 tests pass **fully
offline** (fixture-driven; no test hits the network); `./script/format.sh
--lint` clean; **zero C0/C1/C2 edits**, coordinator NOT wired (still
`NoLanguageServersResolver`); `Package.resolved` byte-identical (no new
dependency — only Foundation, CryptoKit, Darwin).

**Changed paths** (all new, under `Sources/RafuApp/LanguageIntelligence/Registry/`):
`ServerRegistry.swift` (descriptor model + atomic `language-servers.json` user
store), `CuratedCatalog.swift` (7 entries + `validate`), `ServerInstaller.swift`
(download→checksum→unpack→zip-slip-validate→atomic-install→exec-bit→quarantine),
`NodeRuntimeManager.swift` (idempotent pinned Node runtime),
`WorkspaceTrustStore.swift` (per-workspace approvals, atomic),
`InstalledServerResolver.swift` (trust-gated `LanguageServerResolving`, built
but unwired). Tests: 9 fixture-driven suites + shared test support.

## Security-review notes — C3 (installer / downloads / trust)

Enumerated by surface; the standalone `docs/references/` security note is
drafted for the post-merge integration round (this lane may not edit the shared
`docs/references/README.md` index).

- **Download** — all network I/O flows through the injected `AssetDownloading`
  seam (production `URLSessionAssetDownloader`: HTTP-200 check, moves the OS temp
  file to a Rafu-owned path). Every catalog source is `https`
  (`CuratedCatalog.validate` enforces `scheme == "https"` on non-localDiscovery
  entries); user entries are validated `https` or explicit local `file://`
  before persistence. No download URL is ever logged (user-entry URLs may carry
  query tokens).
- **Checksum** — CryptoKit `SHA256` over the raw downloaded bytes, lowercased-hex
  compare; mismatch is a hard abort with temp cleanup; a `nil` published checksum
  yields an honest `.notPublished` status (install proceeds, surfaced to the C4
  consent UI) rather than a fabricated `.verified`. Node's runtime uses a
  64-char all-zero placeholder digest that fails safe until the real published
  `SHASUMS256.txt` value is filled in.
- **Quarantine** — a single native `removexattr(path, "com.apple.quarantine",
  XATTR_NOFOLLOW)` on exactly the one installed binary, gated on an explicit
  `consentToQuarantineRemoval` parameter. Never recursive, never a spawned
  `xattr`. Finding: `ditto` propagates a source archive's quarantine to
  extracted files; a non-quarantine-enabled Rafu's `URLSession` downloads
  generally carry no quarantine, so the remover checks unconditionally and only
  clears on consent.
- **Process spawn** — exactly four fixed executables, all `executableURL` +
  `arguments: [String]`, never a shell, never interpolated: `/usr/bin/gunzip`,
  `/usr/bin/ditto -x -k`, `/usr/bin/tar -xzf`, `/usr/bin/xcrun --find
  sourcekit-lsp`. Child I/O is `/dev/null`; runs are cancellable (terminate on
  task cancel).
- **Install location** — `InstallLayout` (injectable base, default `~/Library/
  Application Support/Rafu`) → `LanguageServers/<id>/`, `Runtimes/node-<v>/`.
  Unpack into an isolated temp staging dir; `AtomicDirectoryReplacer` does
  rename-aside → rename-in → delete with rollback so a crash never leaves a
  half-written install at the real path.
- **Trust** — `WorkspaceTrustStore` persists `language-server-trust.json`
  (`{workspaceKey: [serverID]}`), atomic write, settings not Keychain; the
  resolver refuses to build a launch spec unless a server is installed on disk
  **and** trusted for the workspace.
- **Zip-slip** — archives unpack only into isolated staging; `StagingValidator`
  rejects the whole install on any real-path escaping staging — including a
  symlink whose declared target (resolved lexically against the link's real
  parent, so the check holds even if the target does not exist yet) points
  outside staging — before anything moves into place, layered atop
  bsdtar/ditto's own `..`/absolute-path defenses. It does **not** reject every
  symlink: the managed Node runtime tarball legitimately ships internal
  `bin/npm`, `bin/npx`, and `bin/corepack` links pointing back inside its own
  directory, and a blanket symlink rejection broke every `nodeHosted` install
  (Pyright, typescript-language-server) with a generic "The operation failed."
  See [`docs/references/language-server-install-staging.md`](../../references/language-server-install-staging.md).

**Known security residuals / deferred (recorded, not blocking C3):**

1. **During-extraction symlink escape** — a malicious archive that creates a
   symlink and writes through it *during* `tar`/`ditto` extraction is not
   interceptable without re-implementing archive parsing; post-hoc validation
   catches it only after the fact. Mitigated by https + checksum + trusted
   curated sources + isolated staging + bsdtar's built-in protections. Hardening
   follow-up: pre-extraction entry scan (`tar -tzf` / `zipinfo`).
2. **Cross-volume "atomic" replace** — staging lives in `temporaryDirectory`,
   the target in Application Support; if on different volumes, `moveItem` is a
   non-atomic copy+delete (the rollback still restores the prior install on
   failure). Hardening follow-up: stage on the same volume as the target.
3. **arm64 unsigned-binary SIGKILL** — an unsigned Mach-O is killed by AMFI on
   Apple Silicon regardless of quarantine; consent-gated ad-hoc `codesign` is
   **deferred** (official rust-analyzer/clangd/marksman/Node builds are signed).
4. **nodeHosted dependency resolution** — typescript-language-server needs
   `npm install` of runtime deps (deferred, descriptor-only); Pyright's bundled
   package is the validated nodeHosted example.
5. **Catalog versions/URLs/checksums** are unverified against live upstream (no
   network in this environment) — every entry is code-commented verify-before-
   ship.

**C4-facing:** `InstalledServerResolver` is built and fully tested but NOT wired.
C4 constructs it per workspace with a `WorkspaceTrustStore`-backed `isTrusted`
predicate and injects it via the existing `LanguageServerManager(resolver:)`
parameter (no new API). C4 owns the catalog UI, the consent sheet (which reads
`ChecksumVerificationStatus` and names URL/version/size/license), and the
first-launch-per-workspace trust prompt.

### C4 — Language Servers catalog UI and trust flow — delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean; `swift test` 319 tests pass (offline);
`./script/format.sh --lint` clean; **GUI launch pass green** (`./script/
build_and_run.sh --verify` — app builds as a bundle and launches cleanly, idle
resident ~105 MB, under the 150 MB budget). **Zero forbidden-path edits**: only
the owned `LanguageServersSettingsSection.swift` and `LanguageIntelligence
Coordinator.swift` are modified; `RafuSettingsView.swift`, `LanguageServer
Manager.swift`, `InstalledServerResolver.swift`, `WorkspaceSession.swift`,
`Package.resolved` all unchanged. No new dependencies. C2's coordinator tests
still pass (the coordinator edit is strictly additive).

**Changed/new paths:**

- `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift` (filled) — the
  catalog UI (curated list, packs disclosure, custom-servers section).
- New under `Sources/RafuApp/LanguageIntelligence/Catalog/`:
  `LanguageServersCatalogModel.swift` (`@Observable @MainActor` view-model),
  `LanguageServerCatalogRow.swift`, `LanguageServerPackRow.swift`,
  `ServerInstallConsentView.swift`, `UserServerEntryForm.swift`,
  `ServerPack.swift`.
- New under `Sources/RafuApp/LanguageIntelligence/Trust/`:
  `LanguageServerResolverBox.swift` (Mutex-backed box + `Dynamic
  LanguageServerResolver`), `LanguageServerTrustPromptView.swift` (reusable,
  unmounted), `NodeRuntimeLocator.swift` (pure Node-presence path math avoiding a
  C3 edit).
- `LanguageIntelligenceCoordinator.swift` (additive) — resolver box injected at
  `init()`, per-workspace trust state, `pendingTrustRequest`/`approveTrust`/
  `declineTrust`, resolver-snapshot rebuild on `workspaceDidOpen`; all C2 hooks
  and the editDeltas subscription preserved verbatim; new DI init for tests.

**Trust flow (implemented, presentation deferred):** an installed-but-untrusted
server ⇒ the resolver declines (nav falls through to syntactic/text) AND the
coordinator raises an observable `pendingTrustRequest`; `approveTrust` persists
to `WorkspaceTrustStore` + rebuilds the resolver snapshot (immutable trusted-set
copy captured by `isTrusted`) so the next nav resolves; `declineTrust` remembers
the decline for the session. `discoverGopls`/`discoverSourceKitLSP` (blocking
`waitUntilExit`) run in `Task.detached`, never the cooperative pool.

**DEFERRED TO INTEGRATION (require forbidden `Views/`/`App/` edits or C5):**

1. Live "running with RSS" status in the Settings catalog — per-window
   `LanguageServerStatusStore` is not reachable from the app-global Settings
   scene (same shape as the deferred `ProcessResourceRegistry` sharing).
2. Mounting `LanguageServerTrustPromptView` in a window (a `Views/` `.sheet`
   keyed off `coordinator.pendingTrustRequest`) — also only reachable once C5's
   nav provider is registered.
3. Per-workspace trust management UI in Settings (view/revoke approvals).
4. Local-binary (`file://`) user-entry launch: `InstalledServerResolver`'s
   `.singleBinary` case needs a non-nil `archive` to compute a launch path, so a
   local-binary entry installs/trusts but never resolves a launch spec (the form
   shows a "launch support is limited" note). Fixing it is a small C3 resolver
   addition, out of C4's consume-only scope.
5. Real Node runtime + catalog checksums (pre-existing C3 placeholders; consent
   sheet surfaces the honest "not published / cannot verify" wording).

**Manual GUI pass still recommended for the human** (I cannot drive the UI
interactively): open Settings ▸ Language Servers and confirm the catalog renders
with correct install-state text, the consent sheet is keyboard-navigable (Install
= default, Esc = cancel) and names URL/version/size/license/checksum, the
custom-server form validates, and VoiceOver reads row/sheet labels. A successful
install is not expected offline (nodeHosted fails on the placeholder checksum by
design).

**C5-facing:** `coordinator.session(forLanguageID:)` is the nav seam (now also
raises `pendingTrustRequest` on decline). C5's `LSPNavigationProvider` calls it,
maps `[Location]`/`Hover`/`DocumentSymbolResult` → `SymbolCandidate`/
`NavigationAnswer`, converts the frozen UTF-16 `NavigationRequest.position`
offset via the session, and returns `.indexing` while `isWarmingUp`. C5 must NOT
register in `NavigationLadder` (post-merge integration).

### C5 — LSP navigation provider and merge-readiness — delivered & verified (2026-07-15)

**Status:** COMPLETE. `swift build` clean (no warnings); `swift test` **330
tests pass** fully offline; `./script/format.sh --lint` clean; provider **NOT**
registered in `NavigationLadder`; **zero forbidden-path edits** (the entire
`Sources/RafuApp/Navigation/` contract, `Package.*`, `WorkspaceSession.swift`,
`RafuSettingsView.swift`, `ProcessResourceRegistry.swift`, `AGENTS.md` all
byte-unchanged); no new dependencies (`Package.resolved` identical).

**Changed/new paths:**

- `Sources/RafuApp/LanguageIntelligence/LSPNavigationProvider.swift` (new) — a
  `nonisolated struct LSPNavigationProvider: NavigationTierProvider`.
- `Sources/RafuApp/LanguageIntelligence/LSP/LanguageServerSession.swift`
  (one-token edit) — `private let serverName` → `let serverName` so the
  provider can read it synchronously for the `"via <serverName>"` tier label
  (an immutable `let` of a `Sendable` type on an actor is `nonisolated`). C1's
  `LanguageServerSessionTests` re-run green — no regression.
- `Tests/RafuAppTests/LSPNavigationProviderTests.swift` (new) — 11 offline E2E
  cases over the in-memory transport + scripted server + real temp files.

**Provider behavior:** looks up the session via an injected
`@Sendable (String) async -> LanguageServerSession?` source (production =
`coordinator.session(forLanguageID:)`); declines (`nil`) on no session / not
navigable / capability declined / timeout / any error so the ladder falls
through; returns `.indexing` (empty candidates) while `isWarmingUp`; routes
`kind` to definition/declaration/references/hover; converts each `Location` to a
`SymbolCandidate` by a **bounded (2 MB), off-main, `file://`-only** read of the
target file, building a fresh `DocumentTextMirror` to map the `LSPRange` →
`NSRange` in the negotiated encoding (coarse line-start fallback when the
server's position lands past our on-disk text); hover flattens to a single
preview candidate at the request position; per-request/answer timeout races via
`withThrowingTaskGroup` (loser's cancellation → the session's `$/cancelRequest`).

**Discovered behavior nuance (record for integration):** a JSON `null`
definition/declaration/references result currently **declines** (falls through
to the syntactic tier) rather than answering an authoritative empty, because the
C0 `JSONRPCResponseEnvelope` decodes the result with a non-optional
`container.decode(_:forKey:)`, which Foundation rejects for a `null` value
before `LocationsResult.decodeNil()` can map it to `.none`. An empty array `[]`
IS the authoritative-empty signal (answers `.ready` with no candidates). This is
arguably desirable (an LSP miss falling through to the syntactic tier is useful),
but the intended-empty-on-null design should be confirmed at integration; the
fix, if wanted, is a small owned C0 envelope tweak (decode the result
optionally / tolerate `null`). Not changed in C5 to avoid reopening the framing
layer in the final increment.

## Merge-readiness checklist (verified by the coordinator)

- [x] `git diff --stat` + untracked audit: every change under owned paths
  (`Sources/RafuApp/LanguageIntelligence/**`,
  `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift`,
  `Tests/RafuAppTests/**`, this plan doc). Zero forbidden-path diffs.
- [x] `Package.swift`/`Package.resolved` byte-identical — no new dependency.
- [x] `swift build` clean; `swift test` 330 tests green fully offline;
  `./script/format.sh --lint` clean.
- [x] `LSPNavigationProvider` NOT registered in `NavigationLadder`; no
  `Sources/RafuApp/Navigation/` edits.
- [x] No logging of document text, target-file contents, hover text, or server
  payloads anywhere in lane 2.
- [x] Security-review notes written (C3 install surfaces; C5 bounded off-main
  `file://`-only reads, no shell/spawn, no payload logging).
- [x] C4 GUI launch pass green (app builds as a bundle and launches, ~105 MB
  idle) — interactive Settings ▸ Language Servers pass is a human follow-up.
- [x] Concurrency review path applied to every actor + process/file I/O; two
  C2 races found and fixed with regression tests.

## Exact post-merge integration steps (run in the main checkout)

1. **Register the provider** in `NavigationLadder`, above the syntactic tier —
   one line — building `LSPNavigationProvider(rootURL: <workspace root>,
   sessionSource: coordinator.session(forLanguageID:))`.
2. **Complete the warm-up handshake:** add a server→client request handler seam
   + success-result envelope to the owned C0 `JSONRPCConnection` (the file
   already names `handleIncomingRequest` as the designed seam), and in
   `LanguageServerSession.initialize()` advertise `window.workDoneProgress` and
   reply `{}` to `window/workDoneProgress/create` — so real rust-analyzer/gopls
   drive `isWarmingUp`/`.indexing`.
3. **Mount the trust prompt:** attach `LanguageServerTrustPromptView` as a
   `Views/`-owned `.sheet` keyed off `coordinator.pendingTrustRequest`
   (approve/decline already wired).
4. **Share the `ProcessResourceRegistry`** instance between
   `LanguageServerManager` and lane 1's Resources surface (a constructor
   argument), then wire live "running with RSS" into the Settings catalog.
5. **Confirm the null-result decline** behavior (above) — keep as fall-through
   or make the C0 envelope tolerate `null` for an authoritative empty.
6. **Optional refinements:** `session.utf16Offset(forURI:position:)` for
   same-file conversion through the live mirror (unsaved-edits caveat);
   local-binary (`file://`) user-entry launch support in
   `InstalledServerResolver`; the arm64 ad-hoc codesign step; the nodeHosted
   `npm install` pipeline; real pinned versions/checksums in the catalog.
7. **File the drafted reference notes** into `docs/references/` + its shared
   index (shared-index edits are the integration round's job), and add the
   ADR-0005-scoped security note for the installer.
8. **Verify end-to-end with a real server** (gopls / rust-analyzer on a sample
   repo): definition/references land, tier labels read `"via gopls"`,
   degradation falls through on kill, server rows appear in Resources.
