# ADR 0009: Use versioned same-user Unix-domain socket IPC for the local CLI

- **Status:** Proposed
- **Date:** 2026-07-18

## Context

The `rafu` launcher must open or focus a workspace in the correct running Rafu
window, carry a file line/column, recover after an unclean app exit, and avoid
opening the same document twice during cold start. The transport crosses a
local process boundary and carries private filesystem paths, so it needs a
bounded, authenticated, versioned contract without becoming a remote-command
or document-content channel.

The local launcher protocol is separate from the later SSH remote-agent
protocol. Phase 0's CBOR/MessagePack question applies to that remote protocol;
it does not require binary encoding for this small local metadata exchange.

Alternatives considered:

1. **Same-user Unix-domain socket with explicit framing and JSON** — supports a
   deterministic endpoint, filesystem permissions, peer UID authentication,
   bounded messages, and headless socketpair tests. Chosen.
2. **`open --args` or a custom URL scheme** — simple app activation, but Launch
   Services does not provide reliable acknowledgement, per-request peer
   identity, stale endpoint handling, or deterministic existing-window
   routing. Rejected by the locked launcher rule.
3. **XPC** — strong Apple-platform integration and a good future signed/sandbox
   option, but it couples the bootstrap protocol to service embedding, signing,
   and entitlement work that is outside this lane. Deferred to hardening.
4. **Localhost TCP** — avoids `sun_path`, but expands the network attack
   surface and lacks the socket-file ownership/permission model needed here.
   Rejected.

## Decision

- The endpoint is `~/Library/Application Support/Rafu/ipc/v1.sock`. The app
  creates the containing directory as `0700` and the socket as `0600`. It only
  unlinks a socket proven stale; a live listener is never displaced.
- Every accepted connection calls `getpeereid` and compares the effective UID
  with `getuid()` before reading any body byte.
- A frame is four ASCII bytes `RAFU`, one wire-version byte, a four-byte
  big-endian body length, then a JSON body. The body limit is 64 KiB. The JSON
  envelope has an independent protocol version and typed handshake,
  `openFolder`, and `goto` kinds. Unknown kinds or incompatible versions receive
  typed rejection.
- Payloads reuse `LauncherOpenRequest` and carry only target path,
  line/column, activation, and wait metadata. Document text, diffs, secrets,
  credentials, and arbitrary commands are forbidden. Unified logs record only
  request kind and accepted/rejected outcome, never full paths.
- The CLI handshakes before sending its request. Because the v1 server owns one
  frame per connection, handshake and request use two sequential short-lived
  connections.
- `/usr/bin/open -a <bundle>` is an app starter only on absent/refused socket
  errors and receives no document argument. The CLI reconnects with bounded
  exponential backoff. An automatic request after this cold start becomes a
  new-window request so restoration cannot consume a different folder.
- If IPC cannot complete, the last-resort compatibility path is
  `/usr/bin/open -a <bundle> <folder>` (the containing folder for an external
  goto), preserving basic `rafu <path>` behavior.
- `--wait` is deferred to protocol v2. V1 replies
  `waitSupported: false`; after acknowledgement, the CLI prints a one-line
  notice and exits instead of hanging.
- A goto target outside every workspace opens its containing folder first and
  then selects the requested location.

## Consequences

- Warm requests can focus an exact weakly registered window; forced new-window
  requests cannot be consumed by an older same-root window. Cold and stale
  socket paths converge on the same versioned request router.
- The app owns a small local listener actor and deterministic socket cleanup.
  Blocking fd I/O stays off the MainActor; window effects cross to MainActor
  only after validation and decoding.
- JSON is inspectable during development but remains protected by same-user
  peer checks, permissions, strict framing, and redacted logs. Encoding can add
  optional fields without a wire-format migration.
- V1 does not keep connections open for document/window lifetime and therefore
  cannot implement wait tokens. SSH targets remain unavailable rather than
  entering this local-only router.

**Revisit triggers:** a sandboxed build relocates the socket into an app-group
or container; protocol v2 adds `--wait` lifecycle tokens; SSH routing needs a
distinct authenticated path; or the signed/hardened distribution phase makes
an XPC service materially simpler than maintaining the socket endpoint.

**Related:** `docs/plans/phases/cli-app-ipc.md`,
`docs/plans/phases/phase-0-feasibility.md`,
`docs/plans/phases/phase-1c-cli-integration.md`,
`docs/references/cli-app-ipc.md`, `docs/references/launcher-cli.md`, ADR 0007;
`Sources/RafuCore/Launcher/IPC`, `Sources/RafuApp/Launcher`,
`Sources/RafuCLI/main.swift`.
