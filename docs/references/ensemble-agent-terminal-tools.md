# Ensemble agent terminal tools

- **Applies to:** `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift`,
  `Sources/RafuApp/Canvas/Integration/CanvasTerminalStarter.swift`,
  `CanvasAgentActions.swift`, `CanvasBoardState.swift`,
  `CanvasLiveBridge.swift`, `Canvas/Adapters/CanvasTerminalCard.swift`,
  `Sources/RafuApp/Terminal/TerminalReplyWriter.swift`,
  `WorkspaceTerminalController.sendReply`
- **Last verified:** Swift 6.2 language mode, macOS Darwin 27.0.0, on 2026-11-09

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
  already hold a presentation lease; see section 9), `unavailable` (no shell to start, or
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
- drained once `controller.isProcessRunning` has held for 500 ms (5 × 100 ms)
  **and** the terminal has printed nothing for 300 ms
  (`WorkspaceTerminalController.secondsSinceLastOutput`). A terminal that never
  goes quiet (an agent redraws a spinner) gets its line 2 s (20 steps) after
  the drain first saw its process, quiet or not. No terminal skips the settle:
  the old `hasBootstrap` skip for bridge terminals typed the launch line while
  zsh was still starting, and the line showed twice (the tty echoes typeahead
  in cooked mode, then the line editor reads and echoes it again; it still ran
  once);
- the drain loop is bounded at about 10 s, one drain per node
  (`terminalLineDrains`); each line leaves the queue before the send and is
  pushed back to the front if the send refuses;
- `CanvasTerminalCard` drains through `.task(id: pane.sessionID)`, so a later
  `terminal_start` — or the user pressing Start — types the waiting lines.

The drain types **one line per 100 ms step**, and each line waits for quiet
again. `sendReply` writes a line's Return 250 ms after its text (section 10), so
the step lets that Return land before the next line's text. If line 1 starts an
interactive program, line 2 still lands inside it. That ordering is the agent's
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

### 9. Only a terminal that is live (or starting) holds a presentation lease

The ADR 0025 lease cap is four Ensemble terminals per window (ADR 0023). A
mounted card used to take a lease whenever its board could present, also when
its pane was stopped. Four stopped cards on screen then filled the cap, and the
fifth start failed with "Four Ensemble terminals already hold a live view"
while nothing ran.

Now:

- a card takes a lease on mount only when it has a controller to show
  (live, or exited with its last output); a stopped card takes none;
- the card's Start/Restart (`startOrRestart`, which also serves
  `terminalStartRequest`) takes the lease **before** it starts the pane, through
  `WorkspaceSession.claimCanvasTerminalLease`. Without that, a card whose lease
  was released would start and then show "Terminal view is not attached";
- `.task(id: pane.sessionID)` takes the lease when a session appears by any
  other path;
- at the cap, `claimCanvasTerminalLease` and the starter's `leaseBlocked`
  first call `releaseIdleCanvasTerminalLeases`, which drops the leases of
  panes that are not `.live` (stopped, exited, unavailable) or whose group is
  gone. Four **live** terminals still block a fifth; the cap stays four.

### 10. Return is CR, not LF, and it goes in a second write

Every typed line (`terminal_send`, queued launch lines, notch and notification
replies, Agent History resume, agent hand-off) goes through
`WorkspaceTerminalController.sendReply`, which uses `TerminalReplyWriter`:

- Return is `"\r"` (0x0D). Agent TUIs put the tty in raw mode, so the kernel
  does not map CR and LF. Claude Code (ink) and Codex (crossterm) read 0x0A as
  Ctrl-J, which **inserts a newline** in their prompt; only 0x0D submits. zsh's
  ZLE accepts both, which is why `text + "\n"` looked right in a shell and
  failed in every agent: "hi" sat in the prompt with an empty line under it.
- The text is written first and `"\r"` **250 ms** later in a second write.
  Codex detects a paste by timing: an Enter that arrives within about 120 ms
  of a fast burst of characters is kept as a newline. With 50 ms (verified
  2026-11-09, Codex v0.167.0, voice `terminal_send`), a 335-byte line was
  submitted and the next 282-byte line was not: the text sat in the prompt with
  the cursor on a new line.
- When the program turned bracketed-paste mode on (SwiftTerm
  `Terminal.bracketedPasteMode`; Claude Code, Codex and zsh do), the text is
  sent as an explicit paste, `ESC[200~` text `ESC[201~`, so the CR is a key
  press and never part of a paste. Callers already refuse control characters
  in a line, so the text cannot end the paste early.
- The Ensemble drain does not type the next queued line while the previous
  line still owes its Return (`WorkspaceTerminalController.isReturnPending`).
- Order: a line that still owes its CR writes it at once when the next line
  arrives (`flushReturn` before the text), so lines never interleave whoever
  calls and however fast. The drain also paces one line per step.
- The owed CR is dropped (`discard`) when the process exits or the controller
  shuts down, so it never reaches the next process.
- `sendReply` still returns `true` once the text is written and `false` when
  no process runs; the delayed CR does not change that.
- `sendReturn` (channel-prompt confirmer) flushes an owed CR first, then
  writes one CR.

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

2026-11-09 live voice test (transcript `voice-20261109-134202-a9e3.jsonl`):
`terminal_send` "hi" into Claude Code and into Codex inserted a newline and did
not submit (LF); the `claude` launch line showed twice above and in the prompt
(no settle for a bridge terminal); with four **stopped** cards on screen a
start failed with the lease-cap message. Fixed by sections 3, 9 and 10. Unit
evidence: `TerminalReplyWriterTests` (text then CR, never LF; two lines never
interleave; refused and discarded CR), `CanvasTerminalStartTests`
(`drainWaitsForQuiet`, `drainTypesAfterTheQuietWait`,
`stoppedTerminalsDoNotFillTheLeaseCap`, `liveTerminalsKeepTheLeaseCap`). A
live re-check in Rafu Lightning is still owed (see the voice-control phase
manual checks).

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
- `Sources/RafuApp/Terminal/TerminalReplyWriter.swift`,
  `WorkspaceTerminalController.swift` (`sendReply`, `sendReturn`,
  `secondsSinceLastOutput`)
- ADR 0023 (Terminal Group editor tab), ADR 0025, ADR 0026
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md), workstream X4
- [`canvas-live-sessions.md`](canvas-live-sessions.md),
  [`ensemble-bridge-resilience.md`](ensemble-bridge-resilience.md)
