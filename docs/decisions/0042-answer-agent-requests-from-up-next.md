# ADR 0042: Answer agent requests from the Up next row

- **Status:** Accepted (2026-11-20) on the user's direction (answer an agent's approval request from the Up next row
  of the notch, the island card or the menu bar card, with no trip to the terminal). GUI checks pending (listed
  below).
- **Date:** 2026-11-20
- **Related:** [`codex-app-server-approvals.md`](../references/codex-app-server-approvals.md),
  [`claude-permission-request-hook.md`](../references/claude-permission-request-hook.md),
  [`notch-companion.md`](../references/notch-companion.md) (approval rows), the Dynamic Island Macs decision
  ([`0037-dynamic-island-macs.md`](0037-dynamic-island-macs.md), amendment "Answer a pending agent request"), the
  agent status vocabulary ([`0029-agent-status-vocabulary.md`](0029-agent-status-vocabulary.md)), the Ensemble
  phase ([`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)).

## Context

An agent that runs in a Rafu terminal can stop and ask. Codex asks to run a command, to apply file changes, to
grant permissions, or to answer a question. Claude Code asks before it runs Bash or changes a file. Before this
decision the Up next row only showed that an agent "needs you". The user had to go to the terminal and press a key.

The user wants to answer from the row. Rafu must still not become the only place that can answer: the terminal
dialog must stay usable, and an answer must never be typed into a terminal as keystrokes.

## Decision

1. **The row shows the request and answers it.** A terminal with a pending request shows a "Needs approval" badge
   (words and a symbol, not color alone) and a request row in Up next. The row shows what runs (the full command or
   the files, the working folder, the reason) and the buttons that the request permits. The island card shows the
   request while one is pending, and shows Usage again when the last one closes, with no change to the user's saved
   section. Requests exist in memory only. They are never saved and never logged (no command, reason, question or
   answer text).
2. **The answer goes on the agent's own channel, never as keystrokes.**
   - Codex: the Codex proxy that already sits in front of the terminal UI writes one frame upstream, with the
     original JSON-RPC id, as if the terminal UI had answered. The id never leaves the proxy: the app sees an opaque
     key.
   - Claude Code: a separate blocking `PermissionRequest` hook entry. The helper runs in `--answer` mode, waits for
     a private answer file (folder 0700, file 0600, no text) and prints the allow or deny decision.
3. **The terminal stays in charge.** The terminal dialog always shows, because Claude Code and Codex show it at the
   same time as the request starts. Rafu never hides it. If Rafu prints no output, the terminal decides. The
   helper never answers for the user: a missing answer, an unreadable file, a timeout, a stopped Rafu and a dismiss
   all print nothing. An answer in the terminal closes the row (and tells a waiting helper to stop).
4. **One request is shown per terminal at a time**: the oldest. The app keeps at most 8 requests for one terminal.
   The proxy tracks at most 8 per connection, and only for the bound thread. More are not announced, and the user
   answers them in the terminal.
5. **Sanitizer limits.** Text is cut at a bound, control characters and bidirectional overrides are removed, and a
   request is `terminalOnly` (the row shows "Open terminal" only) when what the user reads would not be exactly what
   runs. Bounds: command 2 KiB, reason 512 bytes, folder 1 KiB, at most 4 questions with at most 6 choices each,
   label 128 bytes, detail 256 bytes, at most 8 permission lines of 256 bytes. `terminalOnly` cases:
   - a command that sanitizing changed, or an empty command, or a command kind Rafu does not know;
   - a permissions request that is incomplete, has more than 8 lines, or has a line that changed;
   - a question that is secret, has no choice, has more than 6 choices, a changed label or a repeated id; more than
     4 questions;
   - a Claude request with a command over 2 KiB, a path over 480 bytes, or text that sanitizing changed. Claude
     requests for any tool other than Bash, Edit, MultiEdit and Write get no row at all (the helper prints
     nothing).
6. **Codex question choices.** Codex 0.170.0 marks every model question `isOther` (the terminal shows "None of the
   above"). That flag alone does not make a question terminal-only: the listed choices are answered from the row. A
   free-text answer still needs the terminal.
7. **Claude has no "Allow for this session".** The hook could grant it only through `updatedPermissions`, which Rafu
   does not send. The row offers Run or Apply, Deny, and Deny and stop. Deny carries a fixed text ("The user denied
   this request in Rafu."); no user text travels.
8. **Claude answers are opt-in with an explicit review.** Settings > Agents > "Answers from Up next" has a switch
   that is off by default and an "Answer hook" row with its own reviewed Connect and Disconnect (Connect needs
   Claude Code activity tracking connected). Connect is a trust transition: after it, Rafu can allow a tool for
   Claude Code. The switch alone installs nothing. Rafu tells a helper that it is watching only while the switch is
   on and the entry is connected (a held `flock`; the kernel drops it when the app quits or crashes). Disconnect of
   activity tracking removes the answer entry too.
9. **Claude Code questions are not answered from Up next (final for this release).** A question that Claude Code
   asks with its `AskUserQuestion` tool stays terminal-only: Rafu shows no row for it. Reason: a spike with Claude
   Code 2.1.329 showed that a blocking `PreToolUse` hook for `AskUserQuestion` hides the terminal question until
   the hook exits. The choices appeared about 20 ms after a hook that ran for 12 s exited. This breaks decision 3
   (the terminal must stay usable while Rafu waits), so the safety check failed. Details: the section "Claude Code
   questions use a different hook" in
   [`claude-permission-request-hook.md`](../references/claude-permission-request-hook.md).

## Alternatives considered

The reference notes record the verified facts below. They do not record why each rejected option lost; the
coordinator's brief named the first three, and their reasons are listed as far as the evidence goes.

- **Type keys into the terminal.** Not chosen. The two channels above give a defined answer shape (verified reply
  table for Codex; allow, deny and interrupt JSON for Claude Code), and the terminal closes its own prompt without a
  keystroke.
- **A second Codex connection.** Not chosen. The proxy already sits in front of the terminal UI, and the server
  accepted an answer with the original id on that connection.
- **Claude Code `--permission-prompt-tool`.** Not probed; the notes hold no test of it. The documented behaviour
  noted in the hook reference is that `PermissionRequest` hooks do not run in `claude -p` (not probed either).
  Rafu's Ensemble terminals run the interactive UI.
- **Treat `isOther` as terminal-only (the first contract).** Rejected after a probe: every Codex question is
  `isOther`, so no question could be answered from the row.
- **Allow when no answer arrives.** Rejected: there is no default allow. The terminal dialog decides.
- **Grant "allow for this session" through the Claude hook.** Not built (see decision 7).
- **Answer Claude Code questions with a blocking `PreToolUse` hook for `AskUserQuestion`.** Rejected after the
  spike in decision 9: the hook hides the terminal question while it waits.

## Consequences

- Rafu answers on the same channel the agent already uses, so a wrong key cannot reach the wrong terminal. A late
  Claude hook decision cannot touch a later request (verified: only that hook's own output decides its dialog).
- **Claude Code specific.** The hook behaviour was verified on Claude Code 2.1.328 only. A later version can
  change it.
- **Not verified live: "No" in the Claude terminal.** Whether Claude Code sends any hook event when the person
  answers "No" in the terminal was not probed. If it sends none, the Claude request stays until the next prompt or
  until the helper wait ends.
- **Parallel tools.** A finished tool of another kind does not end a request, because parallel tools exist. Two
  parallel tools of the same kind can end the wrong request.
- **The helper waits up to 285 s** (hook timeout 300 s, last-resort alarm 290 s). A timeout kills the hook and the
  terminal dialog stays.
- A terminal answer does not stop the Claude hook by itself. Rafu must write a dismiss, or the helper runs to its
  own end.
- Claude answer files older than 10 minutes are removed. The spool file limit rose from 8 KiB to 16 KiB so the
  largest summary fits.
- The release app and Rafu Lightning never share an answer channel (the answers folder is a sibling of the spool).
- The Claude install step was verified with unit tests only. No live probe of the full app path exists yet.
- Codex permission replies with scope `session` and the file change request were not run live. They follow the same
  schema.
- **Claude Code questions stay terminal-only (decision 9).** The row cannot answer an `AskUserQuestion` question.

## Revisit trigger

A Claude Code release that changes the `PermissionRequest` hook (decision JSON, timeout, stdin keys, or whether the
dialog shows at the same time), a Codex release that changes server request resolution or the `isOther` meaning, a
verified hook event for a "No" in the Claude terminal, or a Claude Code version in which the `AskUserQuestion`
question shows in the terminal while a blocking hook waits (then Claude Code questions can be reconsidered).

## GUI checks pending

Answer from the row and from the terminal (the row closes, no stuck prompt); a stale click (the message "This
request was already answered."); keyboard use of the row buttons on a pinned panel; VoiceOver for the badge, the row
and the island card; contrast of the badge and the row; a second window (the request of window B shows and answers
from the row, "Show this agent in its window" opens B); island card expansion and the return to Usage; the Settings
switch and the Connect review for the Answer hook, including Disconnect.
