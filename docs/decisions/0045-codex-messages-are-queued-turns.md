# ADR 0045: Codex gets Ensemble messages as queued turns; agents wait by ending their turn

- **Status:** Accepted (2026-11-21) after a live Codex failure. Source and unit tests only. Two hand checks are pending (see "Hand checks"). Whether a queued message wakes an idle Codex is not
  verified.
- **Date:** 2026-11-21
- **Related:** [`canvas-live-sessions.md`](../references/canvas-live-sessions.md) (section "2026-11-21: Codex has no
  inbox"), the decision about pre-approving Rafu's own tools for Codex
  ([`0044-pre-approve-rafu-tools-for-codex.md`](0044-pre-approve-rafu-tools-for-codex.md)), the Ensemble phase
  ([`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)).

## Context

A Codex agent in an Ensemble terminal got a prompt that said "wait for the next message". Live evidence (Codex
0.171.0, rollout of 2026-11-21): the agent called `receive_messages` and the hidden Codex tool `clock.sleep`
(`{"duration_ms":60000}`) in a loop. It made 9 polls in 9.5 minutes. `receive_messages` was always empty, because
Rafu has no inbox for Codex. The Codex terminal showed only "Working".

Rafu delivers a message to Codex with `codex queue --remote <endpoint> --thread <id> --message <text>`. A queued
message starts a new turn (`turn_trigger: "queue"`) only after the active turn ends. The polling turn never ended,
so the messages sent during it waited. After that turn ended, Codex answered in seconds.

So the loop was caused by guidance, not by delivery: the tool text told Codex to poll an inbox that is always
empty.

## Decision

1. **Codex receives an Ensemble message only as a queued turn.** There is no inbox for Codex. The `receive_messages`
   tool still calls the app (the call is also the heartbeat that retries held messages) but, for a Codex client, it
   ignores the message list and returns a fixed note: "No inbox for Codex. A message to you arrives as a new user
   turn after your current turn ends. To wait for a message: end your turn now. Do not sleep and do not call
   receive_messages again." It is a constant; no peer text enters it. Claude Code behaviour is unchanged.
2. **An agent waits by ending its turn.** The MCP instructions are provider-specific (Claude: channel events,
   `receive_messages` reads any that still wait; Codex: a message is a new turn, end your turn to wait, never sleep,
   never poll). The `receive_messages` description says "Claude Code only". The `send_message` description, the
   `prompt` description of `terminal_create` and `terminal_send`, and the bundled Ensemble skill say: do not tell
   an agent to wait or poll for messages; a message starts its next turn.
3. **The sender's result is honest and covers both cases.** An accepted send to a Codex peer says that Codex takes
   the message as a new turn when its current turn ends, and that if Codex waits idle at its prompt and does not
   start, the sender can start it with `terminal_send`. The text does not claim that an idle Codex wakes.
4. **Rafu does not steer a running Codex turn for now.** `turn/steer` exists in the stable Codex 0.171.0 protocol
   (parameters `threadId`, `expectedTurnId`, `input`; it fails when `expectedTurnId` is not the active turn). It is
   deferred, not rejected.

## Alternatives considered

- **Return the queued messages from `receive_messages`.** Rejected. The messages are already in the Codex queue, so
  Codex would get each message twice (once in the tool result, once as a turn). To avoid that, Rafu would have to
  hold messages itself and track the turn state, which is the steering design.
- **Steer a running turn with `turn/steer`.** Deferred, for four reasons: it cannot be proven without an inference
  call, because the test needs an active turn; the proxy runs in the helper process (`rafu _canvas-agent codex`) and
  the app delivers by a spawned `codex queue`, so it needs a new app-to-helper path; the proxy today never changes
  the forwarded stream, and a steer request that the proxy injects gives a response frame the terminal UI did not
  ask for, which the proxy would have to hide from it; and it changes behaviour, because peer text would enter a
  task that is in progress. If it is built later: the proxy records the turn id at `turn/started` for the bound
  thread and clears it at `turn/completed`; the helper reports "turn active and id" to the app; the app steers with
  `expectedTurnId` only while a turn is active; if the steer fails (the turn ended in the gap) the app uses the
  queue path; one message never goes by both paths.
## Consequences

- After this change a Codex peer waits only for the length of its real work, the same as a person who types into a
  busy Codex. A message sent during a long task arrives as a new turn when the task ends.
- A Codex session that started before the change keeps the old instructions, but the fixed note stops its loop at
  the first poll.
- The `codex queue` argument array is unchanged. The `--resume` flag ("after queueing, try to resume the thread on
  the local daemon or selected `--remote` server") was not added.
- **Not verified:** whether `codex queue` starts a turn for a Codex that is already idle at its prompt. The
  rollout only shows messages queued during an active turn. The reference note had two statements that disagreed;
  both now say "unverified" (see the reference note).

## Revisit trigger

A live test that shows an idle Codex does or does not start on a queued message (then the sender text in decision 3
can be made exact, and `--resume` can be tried if it does not). A Codex release that changes the queue behaviour or
the `turn/steer` contract. A user wish for peer messages to reach a running Codex turn without waiting.

## Hand checks

In Rafu Lightning, repeat the failing prompt ("Ping pong test: ... wait for the next message"). Codex must end its
first turn in seconds, with no long "Working". Send "ping" from the coordinator: Codex must start a turn and reply
"pong" with `send_message` in seconds. Then give Codex a long task and send a message during it: the sender result
must say that the message waits for the end of the turn, and the message must arrive as a new turn when the task
ends. To close the open question, also send to a Codex that is idle at its prompt and record whether a turn starts
(this uses one short Codex turn, so ask the user first).
