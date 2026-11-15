# Ensemble bridge resilience, Codex rebind, and App Nap

- Applies to: the `_canvas-mcp` stdio bridge
  (`Sources/RafuCore/CanvasBridge/CanvasBridgeMCPServer.swift`), the app bridge
  (`Sources/RafuApp/Canvas/Integration/CanvasLiveBridge.swift`), the Codex
  supervisor and proxy (`CanvasCodexSession.swift`, `CanvasCodexProxy.swift`),
  and the agent tool guard (`CanvasAgentActions.swift`).
- Last verified: 2026-10-22, Apple Swift 6.4, macOS 27.0.1 (Darwin 27.0.0)
  for the sections before "Codex relay reconnect". The 2026-11-15 section was
  verified by source and tests; the handoff did not state a toolchain version.
  Live overnight, screensaver, real Ctrl-D, and a real Codex reconnect are NOT
  yet checked live.

## Rules

**The MCP bridge never exits on a link failure.** IPC loss, a refused
`register`, a failed heartbeat `receive`, and a failed thread re-register all
keep the process alive. It ends only on stdin EOF, a poll error, an oversized
frame, an encode failure, or an output write failure. Earlier behaviour was one
transient exchange error, then `exit(0)` — which is why Claude Code showed the
`rafu` MCP server disconnected with no error code.

**Reconnection uses bounded backoff.** 300 ms, doubled to a 5 000 ms cap. The
backoff applies to the heartbeat only; a tool call re-registers at once. There
are no sleeps.

**Tool calls during an outage answer with an error, not silence.** The reply is
`isError` with "Rafu is not reachable right now. The Ensemble link is
reconnecting. Try again in a few seconds."

**Diagnostics are one deduplicated stderr line per state change** (lost,
refused, restored, closed), each at most 200 bytes. A line never holds the
capability token, a socket path, a thread ID, or message text.

**`CanvasBridgeResponse` has an optional `code` field.** The value
`"unregistered"` tells the MCP that the app forgot the client, so the MCP
re-registers instead of matching an error string.

**Suspension is route-scoped, and the route can be rebound.** The supervisor
sends a `release` operation (codex provider plus the matching endpoint) after
the visible TUI exits; `release` clears the route and the suspension. A `bind`
from a NEW supervisor endpoint replaces a route that is dead, stale (15 s or
more), released, or suspended, but it is refused while a live agent holds the
route. A `bind` from the SAME endpoint keeps the earlier thread rule.
`register` rules stop the old agent from retaking a freshly rebound route.
`unregister` works while the route is suspended.

**App Nap is opted out only while an agent route is live.** The app holds
`ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
reason: "Ensemble agent links are connected")` while a terminal has a live,
non-suspended agent route, and releases it otherwise. That option set stops App
Nap, sudden termination, and automatic termination, and it never prevents idle
system sleep or display sleep. Do NOT use `.idleSystemSleepDisabled` or
`.idleDisplaySleepDisabled`: the user's power settings decide sleep.

**The mutation guard is "board open in the workspace", not "view on screen".**
See the "Off-screen agent edits" section of
[`canvas-live-sessions.md`](canvas-live-sessions.md) for the tool-by-tool rule
and the exact messages.

## Why it matters

The user reported three symptoms in one overnight period: the Claude Code
`rafu` MCP server showed as disconnected with no error code; after Ctrl-D in a
Codex terminal, a new `codex` run printed "Rafu: Ensemble could not bind the
Codex session."; and agents could not change diagrams while the Ensemble was
not on screen. The Mac did not system-sleep (display and screensaver only).
A bridge that exits on one transient IPC error gives the provider no way to
recover, and a permanent suspension makes a normal CLI exit look like a broken
terminal.

## Evidence and reproduction

- Root cause of the bind failure: the Codex proxy calls `revoke(.transportLost)`
  when the TUI closes its own socket, so an ordinary Ctrl-D marked the terminal
  route suspended, and suspension was permanent. The supervisor `release` plus
  the new `bind` replacement rule remove that dead end.
- New `ProxyError.pendingOverflow` separates the 256-ID pending cap from a real
  malformed frame, so the next event is identifiable.
- Supervisor messages: a bind refusal prints "Rafu: Ensemble could not bind the
  Codex session. <app literal> Run codex again, or start a new terminal."; an
  unreachable app prints "Rafu did not answer."; after the TUI exits, one line
  "Rafu: The Ensemble link to this Codex session was lost (<phrase>). Run codex
  again to reconnect." is printed only for a real cause — never for a normal TUI close. The
  `<phrase>` values (`CanvasCodexProxy.LinkLoss`) are "the conversation
  changed", "the Codex server closed the connection", "a malformed frame",
  "a frame did not finish in time", "too many unanswered requests", and "Rafu
  did not confirm a session change".
- Residual limit: a client that dies without `unregister` keeps the activity
  assertion until its terminal closes. There is no timer.
- Unverified: the exact overnight trigger of the old Codex "Disconnected from
  this task" text.
- Platform nuance found while building this: a Swift default argument cannot
  reference a `private` static function. Use an optional parameter and resolve
  the default inside the initializer body.

## Verification

```bash
./script/test.sh --filter CanvasBridge
./script/test.sh --filter CanvasLiveBridge
./script/test.sh --filter CanvasCodexSession
./script/test.sh --filter CanvasAgentActions
./script/test.sh                    # parallel
./script/test.sh --no-parallel      # serial (CI mode)
./script/build_and_run.sh --verify  # Rafu Lightning only
```

Evidence recorded for this change: the parallel suite passed in the
implementor's worktree with 262 RafuCore tests and 2860 RafuApp tests. After
the merge to `main` (`aa7e782`), the parallel suite and the `--no-parallel`
(CI mode) suite both passed with 262 + 2860 tests; format lint was clean and
the build added no new warnings.

Manual check the user can run later: open an Ensemble, start `codex`, select
another tab, ask Codex to add a diagram; then press Ctrl-D, run `codex` again,
and confirm "Codex connected".

## Control connection waits for the listener (2026-11-15)

- **Observation.** The app server creates its socket file at `bind` and accepts
  only after `listen`. `CanvasCodexSession` waits only for the file
  (`socketIsOwned`), so a control connection made in that gap gets
  `ECONNREFUSED`. CI (Swift 6.3.3, `macos-26`, run 43728255863) failed
  `unreachableAppDuringBindIsNamedWithoutDetail` with "Codex did not complete
  the control connection." The race can also hit a real `codex app-server` on a
  busy Mac.
- **Rule.** `CanvasCodexRPC.connectedSocket(path:deadline:)` retries
  `ECONNREFUSED`, `ENOENT` and `EINTR` every 20 ms until the RPC deadline (15 s
  default), with a new socket for each attempt. A refused connect that lasts to
  the deadline is `RPCError.timeout`; other connect errors are `transport`.
- **Evidence.** `controlConnectionWaitsForAListenerBehindAnExistingSocket` binds
  a socket without `listen`: it fails on the old code (2 issues) and passes with
  the fix. Main gate: 530 tests in 40 suites and 3927 tests in 319 suites passed,
  parallel and `--no-parallel` (Apple Swift 6.4.2, macOS 27.2).

## Codex relay reconnect (2026-11-15)

Applies to `CanvasCodexProxy.swift`, `CanvasCodexSession.swift`,
`CanvasCodexRPC.swift`, and `CanvasLiveBridge.swift`. Last verified 2026-11-15
by source and tests; no live Codex reconnect check yet.

### Report and cause

The user saw Codex, in an Ensemble terminal, print "Reconnecting to server…",
then "Automatic reconnect timed out … Reconnect failed". Verified cause: the
relay on `<dir>/terminal` cancelled its listener on the first accept, so the
TUI's reconnect got `ECONNREFUSED` (the socket file stays, nothing listens).
Also, any one frame or IO failure ended both workers and sent
`suspend(transportLost)`, and nothing resumed the Ensemble link afterwards.

### Rules

**The listener lives for the whole supervisor run.** Each accepted connection
has its own state: two descriptors (TUI side and upstream), two workers, and its
own pending request IDs. One connection is active. A newer connection replaces
the active one without recording a loss ("newest wins"). Descriptors close only
after both workers end, under the same lock that guards shutdown, so a shutdown
cannot reach a reused descriptor number. Backlog is 4.

**A connection failure closes only that connection.** It still sends
`suspend(transportLost)` at once. A failed upstream connect closes only that
pair; the listener stays. Pending IDs are per connection: an ID that was pending
on a dropped connection is a valid new ID on the next one.

**Link states: `live`, `lostInTransport`, `sessionChanged`.** `sessionChanged` is
final: the relay never resumes a changed conversation, and a reconnect to
another thread stays suspended. The explicit reason `sessionChanged` now
overrides an earlier `transportLost` in the app. A legacy `suspend` with no
reason keeps the first cause.

**`resume` is a new bridge operation.** The relay sends it once per connection,
when the reconnected TUI sends a request whose `params.threadId` equals the bound
thread (a request has both `method` and `id`). The app clears the suspension
only for provider codex, the same endpoint, the same thread, a suspended source,
and reason `transportLost`. Any other case is refused with "This terminal cannot
resume that Codex session." An empty bound thread ID never sends `resume`. A
refused or failed `resume` keeps the link suspended and the relay running; one
attempt per connection stops a refusal from stalling every later request.

**Exit line comes from the outcome.** `proxy.outcome` is `.intact` (no line),
`.lost(cause)` ("Rafu: The Ensemble link to this Codex session was lost
(<phrase>). Run codex again to reconnect."), or `.restored(count:first:)`
("... dropped once|N times (first: <phrase>) and reconnected."). A new
`LinkLoss` cause is `terminalClosed`: "the Codex terminal closed the
connection". Phrases are fixed and hold no data.

**The relay strips the compression offer.** The TUI's upgrade is `GET /rpc` with
`x-codex-app-server-compression: zstd-stream-v1`. The relay removes that header
and `Sec-WebSocket-Extensions` from the forwarded request, because a compressed
stream would break the relay's plain-text frame checks (canonical response
prefix, JSON, `params.threadId`). Test:
`relayRemovesTheCompressionOfferFromTheUpgrade`.

**`CanvasCodexRPC.deinit` sends a masked empty close frame** (opcode 8) after a
successful upgrade. This removes the harmless app-server WARN "Connection reset
without closing handshake" seen at start.

### Evidence

- `relayAcceptsAReconnectOnTheSamePathAfterADrop` fails on the old code with
  `ECONNREFUSED` (verified), and passes now.
- Other relay tests: `relayAcceptsAnIDThatWasPendingOnTheDroppedConnection`,
  `relayNeverResumesAChangedConversationAfterAReconnect`,
  `relayReplacesAnActiveConnectionWithANewerOneWithoutALoss`.
- `relayForwardsLargeServerNotifications` (71,680 bytes; 65,536 plain; 65,536
  mixed) also passes on the OLD code. The incident notification (an
  `item/completed` with `aggregated_output` of exactly 65,536 bytes, a frame of
  about 66,925 bytes and the first 64-bit-length frame of the session) was
  therefore NOT the drop trigger.
- `CanvasLiveBridgeTests`: the `resume` rules and "A changed conversation is
  final".
- Parallel run on the implementor's branch before `2e47ddd`: 528 tests in 40
  suites (RafuCore) and 3895 tests in 317 suites (RafuApp) passed.
- Main gates (parallel and `--no-parallel`) after merge `621a96a`:
  529 tests in 40 suites and 3903 tests in 318 suites passed in each mode; `build_and_run.sh --verify` passed (Apple Swift 6.4.2, macOS 27.2).

### Diagnostic: the Codex log database

Codex writes its own log to `~/.codex/logs_2.sqlite`. It was how the incident
timeline was read (the server queued the large `item/completed` at 18:36:37.501
and the reset came at .507). The log can hold conversation text and tool output:
read only the columns and counts you need, never copy rows into a note, a
commit, or a log, and do not paste text from it into a doc. The handoff did not
state the table or column names; list them first with `sqlite3
~/.codex/logs_2.sqlite ".schema"` and query a time window, for example
selecting the timestamp, level and target for rows between two instants, ordered
by time.

### Security

Any same-user process that can reach the 0700 directory can connect to
`<dir>/terminal` and replace the active connection. Every connection gets the
full frame checks. A reconnect to another thread never resumes the link.

### Open questions

- The drop trigger is unproven. Candidates: the compression negotiation (now
  removed, `2e47ddd`) and the 10 s write and frame deadlines.
- Not proven that codex-cli 0.169.0 sends `thread/resume` after a reconnect. If
  it does not, the link becomes live at the next request with the bound
  `threadId` (for example `turn/start`); until then the link stays suspended.
- The real reconnect has not been run in Rafu Lightning after the fix.

## Related

- Code: `RafuCore/CanvasBridge/CanvasBridgeMCPServer.swift`,
  `CanvasBridgeProtocol.swift`, `CanvasCodexSession.swift`,
  `CanvasCodexProxy.swift`,
  `RafuApp/Canvas/Integration/CanvasLiveBridge.swift`,
  `RafuApp/Canvas/Integration/CanvasAgentActions.swift`.
- Decision: [ADR 0026](../decisions/0026-canvas-live-session-links.md),
  amendments of 2026-10-22 and 2026-11-15.
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md).
- Reference: [`canvas-live-sessions.md`](canvas-live-sessions.md).
