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
- `Sources/RafuApp/Launcher/LauncherIPCServer.swift`
- `Tests/RafuCoreTests/LauncherIPCFramingTests.swift`
- `Tests/RafuAppTests/LauncherRequestRouterTests.swift`
- `docs/plans/phases/cli-app-ipc.md`
- ADR 0009 (authored by I6)
