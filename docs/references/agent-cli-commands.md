# Agent CLI commands for `agent_configure`

Applies to: `Sources/RafuCore/CanvasBridge/CanvasAgentConfigure.swift` (allowlists, plans, readback matcher,
readiness), `Sources/RafuCore/CanvasBridge/CanvasAgentTools.swift` (`agent_configure`, the `terminal_create`
`model`/`effort` launch flags), `Sources/RafuCore/AgentHistory/AgentHistoryResumeCommand.swift`
(`arguments(for:model:effort:mode:)`), `Sources/RafuApp/Canvas/Integration/CanvasAgentConfigureRunner.swift` (the
runner and the queue), `Sources/RafuApp/Canvas/Integration/CanvasAgentActions+Configure.swift` (gate and dispatch),
`Sources/RafuApp/Voice/VoiceToolExecutor.swift` and `VoiceConfirm.swift` (voice path).
Last verified: Swift 6.4.2, macOS 27, 2026-11-10, against Claude Code 2.1.319 and codex-cli 0.167.0
(`--help`, `strings` on the binaries, `codex app-server generate-json-schema`, on 2026-11-09). Rows marked
**unverified** were not run against a live CLI; the manual checks below confirm them.

## CLI facts

| CLI | Command | Form | Status |
|---|---|---|---|
| Claude Code | `/model <model>` | takes the argument directly; no picker | verified (binary metadata, argumentHint `<model>`) |
| Claude Code | `/effort <low\|medium\|high\|xhigh\|max\|auto>` | takes the argument directly | verified |
| Claude Code | `/fast [on\|off]` | takes the argument directly | verified; not used by Rafu |
| Claude Code | permission mode | Shift+Tab cycles; `/permissions`; `/config key=value`; no `/mode <name>` | verified that these exist; Rafu uses `--permission-mode` on resume only |
| Claude Code | `/exit` | quits to the shell | **unverified** name; Ctrl+D is the usual fallback (Rafu does not send it) |
| Claude Code | `/status` | exists | output text **unverified**; Rafu does not read it |
| Claude Code | `claude --resume <id> --model X --effort Y --permission-mode Z` | keeps the conversation | flags verified |
| Claude Code | launch `--model`, `--effort low\|medium\|high\|xhigh\|max`, `--permission-mode` | — | verified (`auto` is not a launch effort) |
| Codex | `/model` | opens a picker (model + reasoning effort); no argument form found | verified; Rafu never drives the picker |
| Codex | `/quit` | quits to the shell | **unverified** name (`/exit` is a likely alias) |
| Codex | `/status` | exists; Rafu reads it back after a resume | output format **unverified** |
| Codex | `codex resume <id> -c model="X" -c model_reasoning_effort="Y"` | keeps the thread; `-c` works on `resume`, `-m` does not | `-c` verified; the key `model_reasoning_effort` **unverified** |
| Codex | `-c sandbox_mode="read-only\|workspace-write"` on resume | mode change | key **unverified** |
| Codex | launch `-m/--model`, `-c key=value`, `-a on-request\|never`, `-s read-only\|workspace-write\|danger-full-access` | — | verified |

## Rules

- **Allowlists, never free text.** `model` matches `^[a-z0-9][a-z0-9._-]{0,63}$`. `effort`: Claude
  `low medium high xhigh max auto`; Codex `low medium high` until more are verified. `mode` is a per-agent enum of
  wire tokens: Claude `default accept_edits plan` (`--permission-mode default|acceptEdits|plan`), Codex
  `read_only workspace_write` (`sandbox_mode`). The modes that remove every check (Claude `bypassPermissions`, Codex
  `danger-full-access`) are deliberately absent. Every typed agent line is a fixed template (`/model `, `/effort `,
  `/status`, `/exit`, `/quit`) plus one allowlisted token. Shell lines are argument vectors quoted by
  `CanvasAgentShell` (its refusal checks apply), never a shell string.
- **Strategies.** Claude default `in_place`: type `/model <m>`, then `/effort <e>`, as separate lines through the
  board's queued-line path (bracketed paste, Return 250 ms later). A Claude mode change and every Codex change use
  `resume`: type the exit line, wait up to 6 s for the shell (no agent in the process sample, or the hook session
  `ended`, and 1 s without output), then type the resume vector from `AgentHistoryResumeCommand`. If the shell does
  not come back, Rafu stops and never types the resume line (it would reach the agent as a prompt). Codex then waits
  up to 8 s for Codex to be in front and sends `/status`. There is no picker drive (Phase B2) and no fresh restart
  rung: a "start over" is `terminal_create` with `model` and `effort`.
- **Busy gate.** Only an idle agent takes a change: hook state `finished`, or, without a hook session, no output for
  3 s (`CanvasAgentConfigureReadiness`). `working` gives `agent_busy`. `waitingForPermission` and `needsInput` also
  give `agent_busy`: `/model` plus Return would answer the dialog. Without hooks the agent must be the process in
  front, or the line would reach the shell. A stale `working` session (no event for 10 minutes) counts as no session.
- **Queue.** `queue: true` on a busy agent with a hook session stores one change per node
  (`CanvasAgentConfigureQueue`; a newer one replaces it). The queue watches the hook state with
  `withObservationTracking`, re-armed after each change; no timer. It runs on the next `finished`, drops the change
  when the session ends or disappears, and drops it after 15 minutes. At run time the board must still be open and
  not Off, and the gate runs again. The user confirmed the change when it was queued; the result goes to the activity
  log only. Without hooks, `queue` is refused ("connect agent hooks").
- **Readback.** After the last line Rafu waits for the queued lines to be typed, then reads the newest 12 viewport
  lines for up to 2 s. A line counts only when it is new since the step began and does not hold a typed command
  (`/model`, `/effort`, `/status`, `codex resume`, `model=`), so the echo never confirms itself. Each token must
  appear as a whole word. `readback` is the fresh lines after `VoiceOutputScrubber`, joined with " / ", at most 200
  characters. `confirmed: false` means "not seen", and Rafu never retries. A Claude resume has no readback.
- **Consent.** Risk `sensitive`, like `terminal_send`. MCP: Ask asks every time, Allow runs, Off denies, and the
  creator rule holds (only a terminal the caller created). Voice: the ADR 0035 §9 rules (any terminal, Confirm in
  Ask). A `resume` always asks, in Allow too, and its voice Confirm is destructive ("Restart", no session grant,
  its own grant key). The gate runs before the question, so a busy agent never shows a card.
- **IPC budget.** The MCP call has a 20 s IPC timeout; Ask can use 12 s of it. An in-place change takes about 1–5 s;
  a Codex resume can take up to about 18 s (6 s exit, typing, 8 s start, 2 s readback). Past the timeout the agent
  sees an IPC error while the change still completes; its outcome is in the activity log.

## Why it matters

Typing into an agent is input on the user's behalf. A line in the wrong place (a running turn, an approval dialog,
or the shell after a failed exit) is a prompt, an answer, or a command the user did not mean. The gates above keep
each line where it was meant to go.

## Verification

```bash
swift test --filter CanvasAgentConfigureTests      # RafuCore: allowlists, plans, readback
swift test --filter CanvasAgentConfigureAppTests   # MCP path, busy, queue
swift test --filter VoiceAgentConfigureTests       # voice Confirm, Codex resume
```

## Manual checks (the user; Rafu Lightning only)

1. Running Claude, idle, Ask: say "Switch Build to Sonnet, low effort". Confirm, then `/model sonnet` and
   `/effort low` are typed, the reply says whether the terminal confirmed it, and the conversation continues.
   Record Claude's exact answer lines.
2. The same while Claude is working: the reply says it is busy and offers to queue. Accept: the change runs after
   the Stop (Settings ▸ Agents ▸ Activity tracking must be connected).
3. Running Codex: say "Use gpt-5 with low reasoning in Tests". The destructive Confirm names the restart; Codex
   quits and resumes with its history intact. Record whether `/quit` quits, and whether `model_reasoning_effort` is
   accepted.
4. Record the exact `/status` output of both CLIs here, and whether `/exit` quits Claude Code.

## Related

- ADR: [`0035-voice-through-gpt-live.md`](../decisions/0035-voice-through-gpt-live.md) (amendment
  "`agent_configure`"), [`0026-canvas-live-session-links.md`](../decisions/0026-canvas-live-session-links.md)
  (MCP instructions cross-reference).
- Phase: [`voice-control.md`](../plans/phases/voice-control.md).
- Notes: [`agent-history.md`](agent-history.md) (resume command quoting).
