# ADR 0029: Agent status vocabulary for Ensemble terminal cards

- Status: Accepted
- Date: 2026-10-19
- Implementation: commit 9c6c095 (merge a257e8d)

## Context

An Ensemble terminal card that runs an agent CLI showed terminal state only.
A person could not tell, without reading the pane, whether the agent was
working, waiting for them, finished, or dead. Rafu already derives agent
activity from hook events (`AgentActivityStore`, the `rafu-agent-events`
helper) and from terminal runtime state, so the question is which vocabulary
to publish and what to refuse to publish.

## Decision

Seven states, and no more, for agent terminal cards (`AgentCardStatus`):

| State | Meaning |
|---|---|
| `working` | the agent is running a turn |
| `needsYou(.approval)` / `needsYou(.input)` | the agent is blocked on the person |
| `failed` | the agent reported a failure |
| `doneUnread` | a reply landed and has not been seen |
| `done` | a reply landed and was seen |
| `inactive` | no activity for 30 minutes |
| `stopped` | the terminal process is gone |

Precedence, highest first:
`stopped` → `failed` → `needsYou` → `working` → `inactive` → `doneUnread` →
`done`.

Bounds that are part of the decision, not implementation detail:

- **`failed` comes only from a reported failure**, never from an exit code:
  Claude Code's hook `StopFailure` and Cursor's error signal. Codex reports
  neither, so a Codex card can never show Failed. An exit code does not
  distinguish "the agent failed" from "the person quit the CLI".
- **`inactive` after 30 minutes.** The activity ledger keeps sessions for at
  most 6 hours and persists nothing, so a long idle label such as "2d" is
  unreachable and must not be written.
- **No cost or spend.** Rafu has no billing access and will not estimate one.
- **No sub-agent count.** The ledger collapses subagent events; deferred.
- **Tab-strip pill and Dock badge** (amended 2026-11-07, see below).
- **Read/unread is not persisted.** It is session-scoped: a FIFO of 256
  acknowledged reply IDs plus an observable revision.

Marking read runs through `WorkspaceTerminalController.clearAttention()` →
`AgentActivityStore.markReplyRead`, because that call already covers every
focus funnel, plus an `onChange` for the case where a reply lands on a card
that is already focused.

No new timer: `AgentActivityStore.now` already ticks every 30 s while
sessions exist, and the status views read it.

Accessibility and layout bounds: the working spinner stops under Reduce
Motion and shows a static three-quarter arc; the elapsed-time text is dropped
when `card.rect.width × scale < 260`.

Board-level rollup: `CanvasAgentSummaryBar` shows "N agents · N working",
with an amber "N needs you" and a red "N failed" that open jump menus
(`focusCanvasCard`). Shell-only terminal cards are unchanged — they gain no
agent vocabulary.

### Amendment 2026-11-07: tab pill, Dock badge, provenance mark

This replaces "No tab-strip badge. Deferred."

- **Tab pill.** An Ensemble tab shows one pill after its title: "N failed"
  in `error` or "N needs you" in `warning`. Failed outranks needs you, the
  same precedence as above. It is a count only, of the same seven-state
  vocabulary; it adds no state and names no card. No pill at zero. A click
  reveals the first counted card (`focusCanvasCard`).
- **Dock badge.** The app-wide sum of needs-you and failed cards over every
  open Ensemble in every visible window, capped at "99+", cleared at zero.
  Tabs refresh it when their counts change; there is no timer.
- **Agent provenance badge.** A card an agent added, moved, resized, renamed
  or wrote shows the agent's name and vendor mark for 8 s, from the tool
  call, not from activity events. It is **not a status**: it never enters
  `AgentCardStatus`, never changes precedence, and is never saved. The
  board notice "Claude added Note 3 · Undo" accompanies it; its Undo works
  only while no later edit changed the board's cards or links.

All three use `CanvasAgentSummaryItem(board:session:)` or the tool log, so the
tab, the bar, the Dock and the card header cannot disagree. Details:
[`ensemble-presence-and-trust.md`](../references/ensemble-presence-and-trust.md).

### Amendment 2026-11-15: sub-agents (in memory)

This replaces "no sub-agent count" for display: a card and an outside-agent row
may show the sub-agents of a session, with type, model and a short description
(user decision, same day). Still no cost, and sub-agents add no state to the
seven-state vocabulary and never change the parent's state.

- **Event fields.** `AgentHookEvent` gains optional `subagentType`,
  `subagentModel`, `subagentDescription`. `schemaVersion` stays 1: events from an
  older helper still decode.
- **Where each value comes from.** Type: `agent_type`, only on an event that also
  has `agent_id`, filtered to `[A-Za-z0-9 _.:-]`, at most 64 characters. Model,
  type and description: only from the `tool_input` of a Claude `PreToolUse` for
  the Agent or Task tool. The helper reads only the keys `subagent_type`, `model`
  and `description`, never `prompt`. Description: one line, whitespace collapsed,
  at most 80 characters with an ellipsis.
- **Ledger.** `TrackedAgentSession.subagents` holds `TrackedSubagent` values.
  Cap 16 per session (the least recently active is dropped). `SubagentStart`
  adds one and takes model and description from the matching queued spawn (same
  type first, else an untyped one). `SubagentStop` removes it. A bounded list of
  recently stopped ids stops a late event from adding it again. A parent `Stop`
  keeps the list; a parent `SessionEnd` clears it. A sub-agent expires after 10
  minutes of silence; a queued spawn expires after 2 minutes.
- **Isolation from the parent.** Sub-agent tracking is exempt from the turn-ID and
  event-order checks and never changes the parent's state, so a late parent `Stop`
  still cannot finish a newer turn.
- **Privacy.** The description crosses the private spool (folder 0700, file
  deleted on read), as the existing 600-character reply preview does. Afterwards
  it is in memory only: never logged, never persisted.
- **UI.** `CompanionSubagentsView`: an "N sub-agents" chip on Rafu and outside
  agent rows in Agents and Up next. It expands to "type · model · description".
  It is a `Button`, so the keyboard reaches it. VoiceOver reads "3 sub-agents
  running: implementor, …". With an older helper (no type) the list says
  "Reconnect Activity tracking in Settings ▸ Agents to see names."
- **Heuristic.** The link from a spawn to a start is a heuristic (type match,
  oldest first), not an id match.
- **Providers.** Claude Code 2.1.325 is verified (see
  [`agent-hooks-and-now-playing.md`](../references/agent-hooks-and-now-playing.md)).
  Codex 0.169.0 is NOT verified: its binary contains the names `SubagentStart`
  and `SubagentStop` and `agent_type`, `agent_id` and `model` in `spawn_agent`
  arguments; Rafu reads `agent_type` from any event that has `agent_id` and has no
  Codex tool-input path. Cursor is unchanged.

## Alternatives considered

- **Derive Failed from a non-zero exit status.** Rejected: it mislabels a
  person quitting the CLI, and it would make Codex the only CLI that reports
  failures frequently and wrongly.
- **Persist read/unread.** Rejected: the ledger itself is session-scoped, so
  persisted read state would outlive the replies it refers to.
- **More states (cost, sub-agent count).** Rejected or deferred as above; a
  vocabulary a person cannot verify is worse than silence. The tab badge,
  first deferred here, is now the count-only pill of the 2026-11-07
  amendment.
- **A dedicated 1 s ticker for elapsed time.** Rejected in favour of the
  existing 30 s tick, to keep the idle-work budget.

## Consequences

Codex cards never show Failed; this is intentional and must be stated
wherever the vocabulary is documented, so a future reader does not treat it
as a bug. Read/unread resets on relaunch. Any new state proposal must say
which signal proves it and what its precedence is.

## Revisit trigger

A CLI that reports failures in a way Rafu can read without inferring from an
exit code, a persisted activity ledger, or a product decision to show spend.

## Related

- Code: `Sources/RafuCore/AgentTracking/` (`AgentHookEvent`,
  `TrackedAgentSession`, `TrackedSubagent`),
  `Sources/RafuApp/Notch/CompanionSubagentsView.swift`,
  `Sources/RafuApp/AgentTracking/`, `Sources/RafuApp/Canvas/`
  (`CanvasAgentSummaryBar`), `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`.
- References:
  [`agent-hooks-and-now-playing.md`](../references/agent-hooks-and-now-playing.md)
  ("Agent card status vocabulary"),
  [`canvas-interaction.md`](../references/canvas-interaction.md),
  [`ensemble-presence-and-trust.md`](../references/ensemble-presence-and-trust.md).
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md).
- Related ADRs: [0021](0021-agent-terminals.md),
  [0025](0025-workspace-canvas-and-app-previews.md).
