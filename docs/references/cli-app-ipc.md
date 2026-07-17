# CLI ↔ app local IPC

- **Applies to:** Rafu's local launcher Unix-domain socket, framing, peer
  authentication, listener/client fd ownership, request routing, and fallback
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-17

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
`DocumentFindState`; that state delivers the pending selection when the editor
attaches. Selecting a hibernated tab rematerializes it through the ordinary
session path. Its exact column is necessarily best-effort until mount because
the clean disk snapshot is the only available text authority at that moment.

The CLI client performs handshake and open/goto as two sequential socket
connections. This follows the I2 listener's one-frame-per-connection contract
while still ensuring compatibility is acknowledged before a request is sent.
Each synchronous exchange has one fd owner, closes exactly once, suppresses
`SIGPIPE`, and uses bounded send/receive timeouts. Errors contain only syscall
names/codes or the app's typed rejection; raw frame bytes are never retained in
diagnostics.

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

## Verification

```bash
swift build
swift test --filter LauncherIPC
swift test
./script/format.sh --fix
./script/format.sh --lint
```

## Related code, ADRs, and phases

- `Sources/RafuCore/Launcher/IPC/LauncherIPCCodec.swift`
- `Sources/RafuCore/Launcher/IPC/LauncherIPCClient.swift`
- `Sources/RafuCLI/main.swift`
- `Sources/RafuApp/Launcher/LauncherIPCServer.swift`
- `Sources/RafuApp/Launcher/LauncherRequestRouter.swift`
- `Sources/RafuApp/Launcher/WindowAccessor.swift`
- `Sources/RafuApp/Launcher/WorkspaceWindowRegistry.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Tests/RafuCoreTests/LauncherIPCFramingTests.swift`
- `Tests/RafuCoreTests/LauncherIPCClientTests.swift`
- `Tests/RafuAppTests/LauncherRequestRouterTests.swift`
- `Tests/RafuAppTests/WorkspaceGotoLocationTests.swift`
- `docs/plans/phases/cli-app-ipc.md`
- ADR 0009 (authored by I6)
