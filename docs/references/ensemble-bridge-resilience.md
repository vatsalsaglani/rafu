# Ensemble bridge resilience, Codex rebind, and App Nap

- Applies to: the `_canvas-mcp` stdio bridge
  (`Sources/RafuCore/CanvasBridge/CanvasBridgeMCPServer.swift`), the app bridge
  (`Sources/RafuApp/Canvas/Integration/CanvasLiveBridge.swift`), the Codex
  supervisor and proxy (`CanvasCodexSession.swift`, `CanvasCodexProxy.swift`),
  and the agent tool guard (`CanvasAgentActions.swift`).
- Last verified: 2026-10-22, Apple Swift 6.4, macOS 27.0.1 (Darwin 27.0.0).
  Source and test verification. Live overnight, screensaver, and real Ctrl-D
  behaviour is NOT yet checked live.

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

## Related

- Code: `RafuCore/CanvasBridge/CanvasBridgeMCPServer.swift`,
  `CanvasBridgeProtocol.swift`, `CanvasCodexSession.swift`,
  `CanvasCodexProxy.swift`,
  `RafuApp/Canvas/Integration/CanvasLiveBridge.swift`,
  `RafuApp/Canvas/Integration/CanvasAgentActions.swift`.
- Decision: [ADR 0026](../decisions/0026-canvas-live-session-links.md),
  amendment of 2026-10-22.
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md).
- Reference: [`canvas-live-sessions.md`](canvas-live-sessions.md).
