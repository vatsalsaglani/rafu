# CLI ↔ app local IPC

- **Applies to:** Rafu's local launcher Unix-domain socket, framing, peer
  authentication, listener/client fd ownership, request routing, and fallback
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-26

## Rule or observed behavior

The listener owns its bound socket path only after `bind` succeeds. Startup may
probe and unlink an existing path only when it is a socket and `connect` proves
there is no live listener (`ECONNREFUSED` or `ENOENT`). A server instance that
sees a live listener or otherwise fails before binding must never unlink that
path during error cleanup or `stop()`.

Accepted connection fds have a single closing owner: the detached connection
task. The server actor tracks those fds only so shutdown can call `shutdown` to
unblock reads, cancel and await the tasks, and let each task perform its one
`close`. The listener fd itself remains actor-owned. A connection accepted just
before listener shutdown is rejected at actor registration once listener
ownership is cleared, preventing reentrant teardown from stranding an fd.
Every accepted connection runs `getpeereid` and compares it with `getuid`
before the first body `read`.

Framing and logging remain content-free: errors retain only sizes/versions, and
unified logs contain a stable request-kind label plus accepted/rejected outcome,
never payloads, document text, secrets, or full paths.

Window selection is split into a pure routing matrix and a MainActor effects
bridge. Open roots are normalized and matched on path-component boundaries;
goto chooses the deepest containing root, while folder opens require an exact
root match. Reuse ordering is deterministic: key window first, then registry
registration order. A goto outside every open workspace first replaces the
selected window's workspace with the file's containing folder and applies the
relative goto after that root is active.

`WindowAccessor` captures both the concrete `NSWindow` and SwiftUI's
`openWindow` action. The registry keeps only weak window and session references,
prunes dead entries on every snapshot/effect, and uses SwiftUI to create the
`workspace` scene. AppKit is limited to `NSApp.activate` and
`makeKeyAndOrderFront` for focusing a specific surviving window. Pending gotos
for `--new-window` carry a minimum registration order so an older same-root
window cannot consume the new window's navigation request.

Goto selection uses the mounted editor's `textSnapshotProvider` when present,
so unsaved TextKit content determines the UTF-16 caret offset. When no editor
is mounted, it reads the clean file from disk and places the resulting range in
both `DocumentFindState` and the document's existing `restoredSelection` before
the session selects it. Both are required: the find controller attaches before
the editor's asynchronous disk load, so its early selection can be overwritten;
`restoreViewState()` reapplies the seeded range after the text arrives.
Selecting a hibernated tab rematerializes it through the same path. Its exact
column is necessarily best-effort until mount because the clean disk snapshot
is the only available text authority at that moment.

The CLI client performs handshake and open/goto as two sequential socket
connections. This follows the I2 listener's one-frame-per-connection contract
while still ensuring compatibility is acknowledged before a request is sent.
Each synchronous exchange has one fd owner, closes exactly once, suppresses
`SIGPIPE`, and uses bounded send/receive timeouts. Errors contain only syscall
names/codes or the app's typed rejection; raw frame bytes are never retained in
diagnostics.

### Streaming subscriptions

`ensembleStatus` and `ensembleArtifact` preserve the established request/reply
shape: handshake on one connection, then exactly one request frame and one
response frame on a second connection. Only `ensembleSubscribe` changes a
connection into a stream. Its frame sequence is:

1. the client writes one `LauncherIPCEnvelope(kind: ensembleSubscribe)`;
2. the app writes one `LauncherIPCResponse.ensemble(.subscribed(cursor:))`
   acknowledgement;
3. the app writes zero or more independent RAFU frames whose JSON bodies are
   `EnsembleEvent` values; and
4. either peer closes the connection. There is no terminal response frame.

The same peer-authentication and rejection ladder applies: `getpeereid` must
match `getuid` before the first read, then wire version, protocol version, and
request kind are checked in that order. A stream does not weaken or duplicate
the one-frame-per-connection contract for nonstreaming request kinds.

The event center assigns one process-local monotonic cursor, retains the newest
512 events, and gives each subscriber an independent
`AsyncStream.bufferingNewest(64)` buffer. While at least one subscriber exists,
it publishes a content-free heartbeat event every 15 seconds. The CLI treats
45 seconds without a complete frame—three missed heartbeat intervals—as app
unavailability (exit 69). A user `--timeout` is a separate monotonic client
deadline and exits 75 when it wins.

The server permits at most 24 live accepted connections, of which no more than
16 may be streams. A seventeenth stream receives a typed exit-69 failure frame
and closes. Stream fds use a five-second `SO_SNDTIMEO`; a slow or abandoned
reader is disconnected rather than retaining an unbounded queue. Events and
snapshots are re-derivable, so clients reconnect and use `status --since
<cursor>` instead of relying on delivery durability.

Shutdown cancels every tracked connection task and calls `shutdown` on its fd
before awaiting the task. This unblocks a stream waiting for its next event or
blocked in a socket operation; the detached connection task remains the one
owner that closes the fd. Stream cancellation, `EPIPE`, and send timeout end
the connection without attempting a second response.

Only `ENOENT` and `ECONNREFUSED` at connect trigger `/usr/bin/open -a
<bundle>` as a starter, with no document argument. Reconnect uses a bounded
exponential schedule totaling under ten seconds. An automatic request sent
after that cold start is promoted to `newWindow`, preventing a restored window
for another workspace from consuming it; explicit `reuseWindow` and
`newWindow` remain unchanged. If IPC still cannot complete, the final fallback
is `/usr/bin/open -a <bundle> <folder>` (the containing folder for goto), so
basic document-open behavior remains available.

In the RafuApp target's Swift 6.2 default-`MainActor` mode, declaring
`LauncherIPCServer` as a custom `actor` gives it its own executor and is the
explicit isolation boundary. Do not spell the type `nonisolated actor`: Swift
6.2 applies that modifier to the synchronous actor initializer and rejects it
as invalid. `nonisolated` remains appropriate on the lifecycle wrappers and
pure/static syscall helpers that do not touch actor state.

## Why it matters

Blind stale-socket cleanup can sever a healthy app's deterministic endpoint
without killing its listener fd, leaving every later CLI invocation unable to
reach the running app. Double-closing a recycled fd can close an unrelated
resource. Authenticating after reading lets a foreign local user consume parser
and memory work before rejection and violates the protocol's trust boundary.
Component-aware root matching prevents `/work/app2` from being mistaken for a
child of `/work/app`. Weak registry references avoid extending a window or
workspace session lifetime, while the registration-order fence preserves
`--new-window` semantics across asynchronous SwiftUI scene creation.

### SIGPIPE in socket tests kills the whole test process (verified 2026-07-20)

Every fd that raw socket TESTS write to needs `SO_NOSIGPIPE` just like the
production fds (`LauncherIPCClient`/`LauncherIPCServer` already guard theirs):
a test-side `write` racing the peer's close raises SIGPIPE, whose default
disposition terminates the entire test process. The failure signature is
misleading — on CI every in-flight test appears "stuck at started" (the run
then hits the job timeout); locally `swift test --no-parallel` exits with
"Exited with unexpected signal code 13" at whichever test happened to be
running. It is timing-dependent: parallel scheduling usually dodges it.
Both test targets' socket helpers now set `SO_NOSIGPIPE` per fd AND install a
process-wide `signal(SIGPIPE, SIG_IGN)` (belt-and-braces; a suppressed
SIGPIPE just turns the write into a handled `EPIPE`). CI additionally runs
`swift test --no-parallel` (via `RAFU_TEST_FLAGS` in `script/test.sh`) so a
genuine hang is identifiable as the last "started" line in the log. Serial
runs also expose order-dependent tests that parallel scheduling masks — e.g.
the JSONRPC out-of-order-responses test assumed frame ARRIVAL order matched
request order across two racing `async let` child tasks; match by request
payload, never by position.

Socketpair fakes that block in `read` must not occupy the shared global
dispatch queue while a repository-wide parallel run is creating hundreds of
other tasks. That pattern can delay the matching client beyond its production
timeout or starve every fake behind waiting readers. Give the tiny blocking
peer a dedicated `Thread`, serialize that test suite, and still keep socket
polls bounded for failure diagnostics. A focused filter may pass reliably
while `swift test` exposes this scheduler-pressure failure, so both are
required evidence.

## Reproduction or evidence

`LauncherRequestRouterTests` uses `socketpair` transports to prove same-user,
foreign-UID-before-body, malformed/oversized, typed-version/kind, and concurrent
client behavior without launching the GUI. A real temporary listener test starts
an owner and a contender on one path, verifies directory `0700` and socket
`0600`, confirms the contender receives `alreadyRunning`, and confirms its
cleanup leaves the owner's socket present.

The isolation spelling was verified directly by the compiler: `nonisolated
actor LauncherIPCServer` produced “`nonisolated` on an actor's synchronous
initializer is invalid”; the ordinary custom actor builds under strict Swift 6
checking and keeps all mutable listener state actor-isolated.

Headless router tests cover exact and nonmatching roots, component boundaries,
deepest-root goto, containing-folder goto, deterministic reuse, forced new
windows, unsupported targets, and injected focus/seed/goto effects. The
window-management review verified that scene creation remains on SwiftUI's
`openWindow` path and the AppKit escape is restricted to specific-window focus.

`WorkspaceGotoLocationTests` proves that mounted live text wins over differing
disk text, CRLF disk offsets queue before first mount, and a hibernated tab is
rematerialized with its pending caret. `LineColumnIndexTests` supplies the
exhaustive LF/CRLF, line-clamp, and column-clamp matrix beneath that seam.

`LauncherIPCClientTests` scripts both halves with socketpairs. It verifies
handshake ordering, request kind/payload, typed rejection short-circuiting,
listener-unavailable classification, and the bounded retry schedule without
launching the app or sleeping.

`EnsembleClientStreamTests` proves subscribe-before-snapshot ordering, queued
event delivery without a lost wakeup, heartbeat liveness, the 45-second policy
through an injected shortened timeout, and the separate user deadline.
`EnsembleServerStreamTests` proves uid-before-read, acknowledgement/event frame
boundaries, the 16-stream cap seam, and listener shutdown of a live stream.
`EnsembleEventCenterTests` proves cursor/ring/buffer bounds and heartbeat
generation with an injected continuation rather than a fixed sleep.

The staged-bundle pass (`./script/build_and_run.sh --verify`) exercised all
nine lane checklist items without UI automation guesses. CoreGraphics window
titles/counts proved cold open, nonmatching reuse, exact-root focus, no
duplicate exact match, and forced new-window behavior. Accessibility reported
`/etc/hosts:1:1` at UTF-16 selection `0,0` and `main.swift:70:3` at the
independently calculated `2155,0`. A SIGKILL left the socket inode and the next
CLI invocation recovered it. Help/version/SSH/status and the one-line wait
notice returned their expected exit behavior. A live unified-log stream showed
only handshake/openFolder request kinds and accepted outcomes.

## Verification

```bash
swift build
swift test --filter LauncherIPC
swift test --filter Ensemble
swift test
swift test --no-parallel
./script/format.sh --fix
./script/format.sh --lint
```

## Related code, ADRs, and phases

- `Sources/RafuCore/Launcher/IPC/LauncherIPCCodec.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCClient.swift`
- `Sources/RafuCore/Ensemble/EnsembleCLIClient.swift`
- `Sources/RafuCLI/main.swift`
- `Sources/RafuApp/Launcher/LauncherIPCServer.swift`
- `Sources/RafuApp/Launcher/LauncherRequestRouter.swift`
- `Sources/RafuApp/Conductor/Ensemble/ConductorEnsembleEventCenter.swift`
- `Sources/RafuApp/Launcher/WindowAccessor.swift`
- `Sources/RafuApp/Launcher/WorkspaceWindowRegistry.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Tests/RafuCoreTests/LauncherIPCFramingTests.swift`
- `Tests/RafuCoreTests/LauncherIPCClientTests.swift`
- `Tests/RafuCoreTests/EnsembleClientStreamTests.swift`
- `Tests/RafuAppTests/Conductor/EnsembleEventCenterTests.swift`
- `Tests/RafuAppTests/Conductor/EnsembleServerStreamTests.swift`
- `Tests/RafuAppTests/LauncherRequestRouterTests.swift`
- `Tests/RafuAppTests/WorkspaceGotoLocationTests.swift`
- `docs/plans/phases/cli-app-ipc.md`
- ADR 0009 (authored by I6)
