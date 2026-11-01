# Ensemble agent terminal tools

- **Applies to:** `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift`,
  `Sources/RafuApp/Canvas/Integration/CanvasTerminalStarter.swift`,
  `CanvasAgentActions.swift`, `CanvasBoardState.swift`,
  `CanvasLiveBridge.swift`, `Canvas/Adapters/CanvasTerminalCard.swift`
- **Last verified:** Swift 6.2 language mode, macOS Darwin 27.0.0, on 2026-10-25

## Rule or observed behavior

### 1. An agent command or prompt is one typed line, with design bounds

`terminal_create` and `terminal_start` do not spawn a process from an argument
string. They build a launch line, quote it with `CanvasAgentShell` (argv quoting,
never shell interpolation), and type that one line into the PTY. The bounds:

| Thing | Limit | Where |
|---|---|---|
| Arguments in a command | 32 | `maximumCommandArguments` |
| Bytes per argument | 1,024 | `maximumCommandArgumentBytes` |
| Bytes per quoted line | 4,096 | `maximumCommandBytes` |
| Agent `prompt` | 1,024 bytes | the prompt is one argument; schema `maxLength` 1024 |
| `terminal_send` `text` | 4,096 bytes | `maximumPromptBytes`, via `singleLine(_:maxBytes:)` |
| `send_message` text, note-node text | 16,384 bytes | `maximumTextBytes` |
| `note_write` body | 64 KiB | `maximumNoteBytes` |
| `mermaid_set` source | 16,384 bytes | `maximumTextBytes` |

All byte counts are UTF-8 bytes, and `singleLine(_:maxBytes:)` cuts on a scalar
boundary. Quoting grows a line (a `'` becomes `'\''`), so the per-argument limit
and the per-line limit are both needed.

**These are deliberate design bounds, not a measured tty limit.** Do not justify
them with `MAX_CANON`: an interactive zsh and every agent TUI run the tty in raw
mode, where that limit does not apply. The prompt bound also keeps clear of the
variadic-flag hazard fixed in `d79f9fe`.

A refusal is a `CanvasAgentShellRefusal` turned into
`invalidArgumentReason(key:reason:)`. The reason carries indices, byte counts and
limits only — never the text. `terminal_create` validates the launch line before
it creates anything, so a refused create leaves no node on the board.

### 2. Only the card's own view starts a process; a start can therefore be missed

ADR 0023 and ADR 0025 stand: a terminal process starts only through the mounted
`CanvasTerminalCard`. The agent path never calls `performTerminalGroupViewAction`.

Root cause of the reported bug: `CanvasBoardState.terminalStartRequest` is
consumed only by a *mounted* card. A card culled by the viewport
(`visibleCards`), or shown as the compact face below 50 % zoom, never consumes
it — and the old code still replied `ok`.

`CanvasTerminalStarter.start` now:

- queues the line first, so a later start still types it;
- refuses early with a named reason — `leaseCap` (four live Ensemble terminals
  already hold a presentation lease), `unavailable` (no shell to start, or
  `startAvailability` says no), `refused` (the terminal manager put up its alert);
- reveals the node: `revealCard` pans at live zoom, `zoomToCard` below it. This
  moves the user's view, and the report says so (`viewMoved`);
- sets `terminalStartRequest` only when it is `nil` or already this card, so
  another card's pending request is never overwritten;
- waits at most 2.5 s (25 steps × 100 ms), re-asking at most 3 times;
- reports `state` as `running` or `stopped`, the same words `ensemble_describe`
  uses.

### 3. "Pane live" ≠ "process running" ≠ "shell ready"

A re-entrant start is impossible: `.start` flips the pane to `.live`
synchronously and `startOrRestart` acts only on `.stopped`/`.exited`. The real
cause of a lost `terminal_send` right after `terminal_start` is the three-state
gap — `sendReply` returns false and queues nothing while the pane is live but the
process has not run yet.

The fix is an ordered per-node queue, `CanvasBoardState.pendingTerminalLines`:

- at most 8 lines per node, 15-minute expiry;
- `@ObservationIgnored`, never persisted, never logged;
- pruned when the node is removed and when the board closes (`forgetClosed`);
- drained once `controller.isProcessRunning` plus a 500 ms settle (5 × 100 ms).
  A bridge terminal with `hasBootstrap` skips the settle;
- the drain loop is bounded at about 10 s, one drain per node
  (`terminalLineDrains`); each line leaves the queue before the send and is
  pushed back to the front if the send refuses;
- `CanvasTerminalCard` drains through `.task(id: pane.sessionID)`, so a later
  `terminal_start` — or the user pressing Start — types the waiting lines.

Queued lines are typed back-to-back after one settle. If line 1 starts an
interactive program, line 2 lands inside it. That ordering is the agent's
responsibility, not Rafu's.

### 4. The IPC budget decides how long an in-call wait may be

The bridge socket timeout is 20 s
(`LauncherIPCClient.canvasBridgeTimeoutSeconds`), and Ask-mode approval can use
12 s of it (`CanvasAgentCenter.approvalWait`). **An in-call wait must stay at or
below 2.5 s.** The typing wait is the exception because it runs *after* the reply
has gone back.

### 5. Result messages carry counts, never content

The Activity log records `toolResult.message`. A result message therefore states
byte counts and states only — never the typed line, the prompt, or a message body.

### 6. A refused start must be detected by the matching alert title

`isOpenFolderErrorPresented`/`openFolderErrorTitle` is shared by six producers,
so it cannot tell a refused terminal start from anything else.
`WorkspaceSession.terminalGroupErrorTitle` and `isTerminalGroupErrorPresented`
are the only Terminal Group signal.

### 7. Swift: a task-local in a MainActor-default module

A `@TaskLocal static var` in a module with default `MainActor` isolation needs a
`nonisolated` default value (hence `nonisolated static let defaultConfirmSteps`).
A test seam that shortens a wait should be a task-local or an injected parameter,
**not** a mutable static: parallel `@MainActor` tests interleave at every `await`
and would see each other's writes.

### 8. terminal_create link, and who may receive text

- `terminal_create` with `link: true` adds a caller→new-node message edge and
  sets it live, returning `edge_id` and the mention. A link failure *after* the
  node exists is reported in the result message, not thrown — the node is real.
- `terminal_send` accepts `text` when Rafu created the node with an `agent`, or
  when `CanvasLiveBridge.connectedProvider(controllerID:)` reports a connected
  provider. A `command` that happens to start a known agent CLI only records a
  describe hint (`launchedAgents`); it never opens the text path.
- Only `claude` and `codex` register with the bridge. Rafu never scrapes
  terminal output to guess what is running.
- `send_message` success returns `delivered: true`, with "Queued … not
  acknowledged yet" in the message. Failures stay errors.
- The no-agent error points the caller at `edge_create` plus `link_set_state`.

## Why it matters

An agent that gets `ok` for a start that never happened, or a `terminal_send`
that is silently dropped, cannot recover — it has no way to see the board. The
queue plus the reveal plus the honest `running`/`stopped` state make the failure
either visible or self-healing. The byte bounds and the counts-only reporting are
what keep a prompt out of the shell grammar and out of the Activity log.

## Reproduction or evidence

Verified on this change (2026-10-25):

- `./script/format.sh --lint` clean.
- `./script/build.sh` with 0 source warnings. Only the pre-existing SwiftPM
  "missing creator for mutated node … SwiftTerm bundle" notice appears.
- `./script/test.sh` (parallel): 2,885 tests in 203 suites passed in 16.1 s.
- `./script/test.sh --no-parallel` (CI mode): 2,885 tests passed in 47.4 s.
- `./script/build_and_run.sh --verify`: exit 0.

**Not yet verified — a live MCP pass inside Rafu Lightning.** Still open: an
off-screen / zoomed-out create; `terminal_start` followed at once by
`terminal_send`; the 500 ms settle against heavy rc files; the 4-terminal lease
cap; Ask mode; the `CanvasTerminalCard` `.task(id: pane.sessionID)` drain; the
refused-start alert path.

## Verification

```bash
./script/format.sh --lint
./script/build.sh
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift`,
  `CanvasBridgeMCPServer.swift`
- `Sources/RafuApp/Canvas/Integration/CanvasTerminalStarter.swift`,
  `CanvasAgentActions.swift`, `CanvasBoardState.swift`, `CanvasLiveBridge.swift`
- ADR 0023 (Terminal Group editor tab), ADR 0025, ADR 0026
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md), workstream X4
- [`canvas-live-sessions.md`](canvas-live-sessions.md),
  [`ensemble-bridge-resilience.md`](ensemble-bridge-resilience.md)
