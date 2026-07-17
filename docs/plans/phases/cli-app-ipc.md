# Lane plan — CLI ↔ app IPC v1 (local socket)

## Status

Planned (2026-07-17). One of six post-audit lanes defined in
[`post-audit-worktree-fanout.md`](post-audit-worktree-fanout.md). Runs in a
**dedicated git worktree** after its contract commit (I0) lands on main.
Delivers the Phase 0 CLI spike and the foundation of Phase 1C: a
versioned, same-user Unix-domain socket carrying `openFolder`, `goto`, and
handshake requests with deterministic multi-window routing. Satisfies the
locked rule "CLI requests use versioned same-user Unix-domain socket IPC;
do not use `open --args` as the protocol" by demoting `open -a` to an app
*starter* only. Records **ADR 0009** (number reserved by the fan-out
plan). `--wait` is **honestly deferred to v2** (response carries
`waitSupported: false`); `--ssh` stays validation-only. Each increment is
one advisor → implementor → verification → documentor cycle. File:line
anchors reflect the tree on 2026-07-17; the repository wins when they
disagree.

## Verified baseline

- CLI today (`Sources/RafuCLI/main.swift`): parse (:10) → validate →
  `LauncherAppLocator.enclosingAppBundle()` → `/usr/bin/open -a <bundle>
  <folder>` (:41–45). No socket; `--goto`/`--new-window`/routing dropped.
  `.status`/`.listSSHHosts` → `EX_UNAVAILABLE` (:54–58).
- **The grammar already parses everything needed**:
  `LauncherArgumentParser.swift` — `--new-window` (:60), `--reuse-window`
  (:66), `--wait` (:72), `--ssh` (:75), `--goto path:line[:column]` (:85)
  → fully-populated `LauncherOpenRequest` (:126–133). The parser and
  `LauncherInvocation.swift` value types (`Codable`/`Sendable`) are the
  IPC payload — extend, never replace.
- App side: single `WindowGroup("Rafu", id: "workspace")`
  (`RafuApp.swift:9`); folder opens arrive via
  `NSApplicationDelegate.application(_:open:)` →
  `ExternalOpenRequests.shared` (`ExternalOpenRequests.swift:45–48,
  16, 28`); `WorkspaceSceneRoot` consumes one pending URL in `.task`
  and skips restoration (:22–34); a running key window consumes via
  `.onChange(of: hasPending)` (:35–41). **No session/window registry
  exists**; no way to open a new window pre-seeded except enqueue-then-
  `openWindow(id:"workspace")`.
- `WorkspaceSession` seams: `openLocalWorkspace(at:)` (:380),
  `openFile(atRelativePath:)` (:540), `openWorkspaceSymbol` (:550,
  NSRange selection), `findState(for:).select(range)` (:560/:1061).
  **No line/column goto API exists.**
- Framing precedent: `JSONRPCFraming.swift` (RafuApp target — CLI cannot
  import it; the pattern is mirrored into RafuCore, sizes-only errors,
  bounded body, fresh-copy re-basing).
- Targets: `RafuCore` dependency-free and nonisolated (`Package.swift:82`);
  `RafuCLI` depends only on RafuCore (:121–124); RafuApp is
  MainActor-default (:118). **Placing protocol/codec/client in RafuCore
  requires no `Package.swift` change** — the key de-risking fact.
- App is not sandboxed; bundle id `dev.vatsalsaglani.rafu`; CLI staged at
  `Contents/SharedSupport/bin/rafu` (ADR 0007).

## Protocol (frozen in I0, recorded in ADR 0009)

- **Socket:** `~/Library/Application Support/Rafu/ipc/v1.sock` —
  deterministic, computed identically by CLI and app; well under the
  104-byte `sun_path` limit (guarded); dir `0700`, socket `0600`;
  unlink-stale-on-start (never blindly unlink a live socket — `bind`
  `EADDRINUSE` means another instance owns it).
- **Same-user enforcement:** `getpeereid(fd) == getuid()` on every
  accepted connection **before processing any body byte**.
- **Framing:** 4-byte magic `"RAFU"` + 1-byte wireVersion + 4-byte
  big-endian body length; JSON body; **64 KiB bound** (paths +
  line/column + activation only — never document text or secrets).
- **Envelope:** `{ wireVersion, protocolVersion, requestID, kind,
  payload }`; kinds `handshake`, `openFolder`, `goto`; payload reuses
  `LauncherOpenRequest`. Responses: `accepted{workspaceMatched,
  windowFocused, waitSupported}` / `rejected{reason}`. Unknown fields
  tolerated; unknown kind / incompatible version → typed rejection,
  never a crash.
- **Encoding decision:** JSON for this local socket. Phase 0's
  "CBOR or MessagePack" open blocker concerns the SSH remote-agent
  protocol, not local IPC — recorded in the ADR.
- **Logging:** request kind + accepted/rejected outcome only; never full
  paths (Phase 1C redaction rule).

## Global rules for this lane

- **Owned paths (after I0):** `Sources/RafuCore/Launcher/IPC/**` (new),
  `Sources/RafuApp/Launcher/**` (new), `Sources/RafuCLI/main.swift`,
  `Sources/RafuCore/Launcher/LauncherHelp.swift`,
  `Tests/RafuCoreTests/LauncherIPC*Tests.swift`,
  `Tests/RafuAppTests/LauncherRequestRouterTests.swift` /
  `WorkspaceGotoLocationTests.swift`, `docs/decisions/0009-*.md`,
  `docs/references/cli-app-ipc.md` (new), `docs/references/
  launcher-cli.md`, Phase 0/1C status lines, and this plan document.
- **Shared — touched ONLY in the I0 contract commit, then frozen:**
  `Sources/RafuApp/Models/WorkspaceSession.swift` (goto seam only),
  `Sources/RafuApp/Views/WorkspaceSceneRoot.swift` (registry hook +
  `WindowAccessor`), `Sources/RafuApp/App/ExternalOpenRequests.swift`
  (server start/stop hooks).
- **Must not change:** `Package.swift`/`Package.resolved`,
  `Sources/RafuApp/App/RafuApp.swift` (reuse `ExternalOpenRequests`
  seeding; a value-based `WindowGroup` would be an integration-owner
  escalation), `LauncherArgumentParser`/`LauncherInvocation` grammar
  shapes, `LauncherAppLocator` (ADR 0007).
- **Forbidden paths:** `Sources/RafuApp/LanguageIntelligence/**`,
  `Sources/RafuApp/Editor/**` (read `findState.select` only),
  `Sources/RafuApp/Git/**` + `GitService.swift`,
  `Sources/RafuApp/Markdown/**`, `AGENTS.md`, shared doc indexes.
- Security review per AGENTS.md on the whole lane (new IPC surface,
  process trust transitions); `swift-concurrency-pro` review on
  `LauncherIPCServer` (fd ownership, cancellation, `Sendable` buffers).
  `window-management` skill sign-off on the window-focus mechanism.
- Verification per increment: `swift build`, full `swift test`, format
  fix+lint; `./script/build_and_run.sh` + manual checklist for I5/I6.
- After each green increment the coordinator stops and asks the user to
  commit. No agent commits.

## I0 — Contract commit (lands on MAIN before worktree fan-out)

a. `Sources/RafuCore/Launcher/IPC/LauncherIPCProtocol.swift` — envelope,
   kinds, responses, `wireVersion = 1`, `protocolVersion = 1`,
   `maxFrameBytes = 64 * 1024`, socket-path resolver;
   `LauncherSocketAddress.swift` — `sockaddr_un` construction with the
   104-byte guard. Pure types only.
b. `WorkspaceSession.openFile(atRelativePath:selecting: SourceLocation)`
   **signature** + a pure line/column→offset utility (implementation may
   be minimal; the signature is the contract).
c. `Sources/RafuApp/Launcher/WorkspaceWindowRegistry.swift` (`@MainActor
   @Observable`; sessions register `rootURL` + weak `NSWindow`) +
   `WindowAccessor.swift` (tiny `NSViewRepresentable`); registration
   hooks in `WorkspaceSceneRoot`.
d. `LauncherIPCServer` stub + start/stop calls in
   `applicationDidFinishLaunching`/`applicationWillTerminate`
   (`ExternalOpenRequests.swift:41`).
e. Build + full suite green; zero behavior change. **User commits; the
   worktree is created from this commit; the three shared files are
   frozen for the lane's duration.**

## I1 — Framing + codec (RafuCore, pure)

Encoder + incremental bounded decoder mirroring `JSONRPCFrameDecoder`
(sizes-only errors, fresh-copy re-basing); envelope `Codable` round-trip.
Tests: round-trip every kind; partial-chunk reassembly; oversized-body
and truncated/garbage-header rejection; unknown-field tolerance; unknown
kind → rejectable sentinel.

## I2 — App listener actor

`LauncherIPCServer` **actor** (explicitly non-MainActor in the
MainActor-default target): `socket(AF_UNIX)` → unlink-stale → `bind` →
`chmod 0600` → `listen`; detached accept loop; per connection:
`getpeereid` check → bounded incremental read → decode →
`await router.handle(_:)` on MainActor → framed response → close.
`stop()` closes fd + unlinks. Foreign-uid / oversized / malformed →
typed rejection + close. Tests over `socketpair` + injected-uid seam;
two concurrent clients.

## I3 — Router + registry routing

Pure decision function `route(request, openRoots:) -> RoutingDecision`
(`.focus(windowID)`, `.seedNewWindow(url)`,
`.focusAndGoto(windowID, file, loc)`), unit-tested as a matrix (reuse vs
new vs `--new-window`; matching vs non-matching root). Impure half:
`NSApp.activate` + `makeKeyAndOrderFront` (weak refs pruned on
deregister); new windows seed via `ExternalOpenRequests.enqueue` +
`openWindow(id:"workspace")` — reusing the existing tested
external-beats-restoration path. Cold-start race rule: if a window
already restored a different folder, seed a new window; "cold `rafu
<path>` shows the requested folder, not the restored one" is an explicit
verification item.

## I4 — `goto` seam

Implement `openFile(atRelativePath:selecting:)` using the line-index
utility + existing `findState.select(range)`. Line/column→offset tested
exhaustively (LF/CRLF, out-of-range line clamp, column past line end).
Buffer-not-yet-mounted: select on first mount; exact column on a
hibernated tab is best-effort (documented). File outside any workspace:
v1 opens the containing folder as the workspace, then gotos (Phase 1C
open blocker resolved this way in ADR 0009).

## I5 — CLI client + fallback

`LauncherIPCClient` (RafuCore): connect → handshake → send → await →
map to exit codes/stdout. `ENOENT`/`ECONNREFUSED` → start app via
`open -a <bundle>` **without a document argument** (prevents the
double-open) → bounded exponential backoff reconnect (cap ~10 s) → send
over IPC. Total IPC failure → last-resort `open -a <bundle> <folder>`
document path so `rafu <path>` never regresses. Help/version/`--status`
unchanged.

## I6 — `--wait` deferral, docs, end-to-end

- `--wait`: CLI prints a one-line "not yet available" notice after the
  ack (never hangs); response carries `waitSupported: false`.
- ADR 0009 (transport, framing, permissions, peer auth, starter-only
  `open -a`, alternatives: `open --args`/URL scheme rejected by locked
  rule, XPC deferred to signing phase, localhost TCP rejected; revisit
  triggers: sandboxed build moves the socket into the container, --wait
  v2, SSH routing). New `docs/references/cli-app-ipc.md`; update
  `launcher-cli.md`; refresh `LauncherHelp`; Phase 0/1C status lines.
- **Manual end-to-end checklist:**
  1. App closed → `rafu .` from unrelated cwd → launches + opens (cold,
     IPC).
  2. App running with A → `rafu <B>` → opens B per reuse rules.
  3. App running with A → `rafu <A>` → focuses the existing A window, no
     duplicate.
  4. `rafu --new-window <A>` → second A window.
  5. `rafu --goto <file>:<line>[:col]` → caret lands.
  6. Two windows → `rafu <A>` focuses the A window specifically.
  7. Unclean kill → `rafu .` recovers (stale-socket unlink).
  8. `--ssh` unchanged unavailable; `--help`/`--version` unchanged.
  9. `rafu --wait <path>` prints deferral notice, exits.
- Security checks: `ls -le` dir `0700`/socket `0600`; no paths in
  `log stream --predicate 'subsystem == "dev.vatsalsaglani.rafu"'`
  during a request; foreign-uid rejection covered by the unit seam.

## Risks

- **Cold-start restoration race** — handled by the seeding rule (I3);
  explicit verification item.
- **Focusing a specific SwiftUI window instance** has no public API —
  `WindowAccessor` weak-`NSWindow` capture is the pragmatic path; needs
  `window-management` sign-off; registry prunes stale refs.
- **`sun_path` overflow** (relocated home) — guarded construction, clear
  error, document-open fallback. Sandbox/container path shift noted as
  an ADR revisit trigger.
- **Concurrent CLI invocations** — each connection awaits its own
  MainActor router call; tested with two concurrent clients.

## Exit

- All nine manual checklist items pass; framing/codec/router/goto/uid
  suites green; full suite green; no `Package.swift` diff; the three
  shared files untouched since I0; no paths or content logged; ADR 0009
  + references landed; `--wait` honestly deferred.

## Lane completion record

- **I1 — complete (2026-07-17):** Added the pure fixed-header frame encoder,
  incremental bounded decoder, and content-redacting JSON codec in RafuCore.
  Tests cover every request kind and response shape, all chunk boundaries,
  multiple rebased frames, oversized/truncated/garbage headers, unknown-field
  tolerance, unknown-kind sentinel decoding, and malformed JSON. Evidence:
  `swift build`; full `swift test` (525 tests); `./script/format.sh --fix` and
  `./script/format.sh --lint` all passed.
