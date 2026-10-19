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
- **No tab-strip badge.** Deferred.
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

## Alternatives considered

- **Derive Failed from a non-zero exit status.** Rejected: it mislabels a
  person quitting the CLI, and it would make Codex the only CLI that reports
  failures frequently and wrongly.
- **Persist read/unread.** Rejected: the ledger itself is session-scoped, so
  persisted read state would outlive the replies it refers to.
- **More states (cost, sub-agent count, tab badge).** Rejected or deferred as
  above; a vocabulary a person cannot verify is worse than silence.
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

- Code: `Sources/RafuApp/AgentTracking/`, `Sources/RafuApp/Canvas/`
  (`CanvasAgentSummaryBar`), `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`.
- References:
  [`agent-hooks-and-now-playing.md`](../references/agent-hooks-and-now-playing.md)
  ("Agent card status vocabulary"),
  [`canvas-interaction.md`](../references/canvas-interaction.md).
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md).
- Related ADRs: [0021](0021-agent-terminals.md),
  [0025](0025-workspace-canvas-and-app-previews.md).
