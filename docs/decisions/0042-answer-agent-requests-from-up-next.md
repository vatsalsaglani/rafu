# ADR 0042: Answer agent requests from the Up next row

- **Status:** Amended 2026-11-22 (every prompt shows; question sets answer in Rafu; lasting grants pending the
  user's decision, see the last amendment). Accepted (2026-11-20) on the user's direction (answer an agent's approval request from the Up next row
  of the notch, the island card or the menu bar card, with no trip to the terminal). Amended the same day after a
  read-only review (the full command always shows, more terminal-only cases, file changes are terminal-only, and a
  live check of a late hook answer). GUI checks pending (listed below).
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
   (words and a symbol, not color alone) and a request row in Up next. The row shows what runs (the full command,
   the working folder, the reason) and the buttons that the request permits. The command always shows whole: there
   is no line limit and no "Show all" control, so no part of a command can be out of view while Run is active. A
   file change shows its title, path or reason and "Open terminal" only (decision 10). The island card shows the
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
5. **Sanitizer limits.** Text is cut at a bound, control characters and format characters (Unicode category Cf:
   bidirectional controls, zero-width spaces and joiners such as U+200B, U+2060 and U+FEFF, the soft hyphen U+00AD,
   the Arabic letter mark U+061C) are removed, and a
   request is `terminalOnly` (the row shows "Open terminal" only) when what the user reads would not be exactly what
   runs. Bounds: command 2 KiB, reason 512 bytes, folder 1 KiB, at most 4 questions with at most 6 choices each,
   label 128 bytes, detail 256 bytes, at most 8 permission lines of 256 bytes. `terminalOnly` cases:
   - a command that sanitizing changed, or an empty command, or a command kind Rafu does not know;
   - a command with blank space that could push its end out of view: more than 2 blank lines in a row, or more than
     64 spaces and tabs in a row (for example `ls`, four empty lines, then `; curl … | sh`);
   - a Codex command request that carries `networkApprovalContext` (it asks for network access to a host that the
     row does not show);
   - a Claude Bash request with `tool_input.dangerouslyDisableSandbox` set to true (it asks to run outside the
     sandbox, which the row does not show);
   - every file change (decision 10);
   - a permissions request that is incomplete, has more than 8 lines, or has a line that changed;
   - a question that is secret, has no choice, has more than 6 choices, a changed label or a repeated id; more than
     4 questions;
   - a Claude request with a command over 2 KiB, a path over 480 bytes, or text that sanitizing changed. Claude
     requests for any tool other than Bash, Edit, MultiEdit, Write and (amended 2026-11-21) a tool of an MCP server
     get no row at all (the helper prints nothing).
6. **Codex question choices.** Codex 0.170.0 marks every model question `isOther` (the terminal shows "None of the
   above"). That flag alone does not make a question terminal-only: the listed choices are answered from the row. A
   free-text answer still needs the terminal.
7. **Claude has no "Allow for this session".** The hook could grant it only through `updatedPermissions`, which Rafu
   does not send. The row offers Run, Deny, and Deny and stop. Deny carries a fixed text ("The user denied
   this request in Rafu."); no user text travels.
8. **Claude answers are opt-in with an explicit review.** Settings > Agents > "Answers from Up next" has a switch
   that is off by default and an "Answer hook" row with its own reviewed Connect and Disconnect (Connect needs
   Claude Code activity tracking connected). Connect is a trust transition: after it, Rafu can allow a tool for
   Claude Code. The switch alone installs nothing. Rafu tells a helper that it is watching only while the switch is
   on and the entry is connected (a held `flock`; the kernel drops it when the app quits or crashes). Disconnect of
   activity tracking removes the answer entry too.
9. **Claude Code questions are not answered from Up next (final for this release).** *Superseded on 2026-11-22 by
   the amendment "Every agent prompt shows; question sets answer in Rafu" below: a blocking `PermissionRequest`
   hook, not the `PreToolUse` hook tested here, receives the question and the terminal stays usable.* The original
   text follows. A question that Claude Code
   asks with its `AskUserQuestion` tool stays terminal-only: Rafu shows no row for it. Reason: a spike with Claude
   Code 2.1.329 showed that a blocking `PreToolUse` hook for `AskUserQuestion` hides the terminal question until
   the hook exits. The choices appeared about 20 ms after a hook that ran for 12 s exited. This breaks decision 3
   (the terminal must stay usable while Rafu waits), so the safety check failed. Details: the section "Claude Code
   questions use a different hook" in
   [`claude-permission-request-hook.md`](../references/claude-permission-request-hook.md).

10. **File changes are terminal-only (coordinator decision after the review).** *Superseded on 2026-11-21 by the
    amendment "File changes and long commands answer in the peek" below: a file change is answerable when the row
    shows the whole change.* The original text follows. A Codex `fileChange` approval and a
    Claude Code Edit, MultiEdit or Write request show the title ("Apply file changes"), the path or reason, the
    write root when Codex sends one, and "Open terminal". The row offers no Apply or Deny. Reason: the row cannot show
    the change itself (Codex sends no diff with the request; Rafu reads only the Claude `file_path`), so "what the
    row shows is what runs" cannot hold. `CanvasAgentRequest` makes every `fileChange` terminal-only, also when one
    is decoded from the bridge.

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
- **Parallel tools.** A finished tool of another kind does not end a request, because parallel tools exist. Two
  parallel tools of the same kind can end the wrong request.
- **The helper waits up to 285 s** (hook timeout 300 s, last-resort alarm 290 s). A timeout kills the hook and the
  terminal dialog stays.
- A "Yes" in the Claude terminal does not stop the hook: Rafu must write a dismiss, or the helper runs to its own
  end. A "No" in the terminal does stop it (see the live check below).
- **Live check: a late hook "allow" after a terminal "No" is not obeyed** (Claude Code 2.1.329, Haiku, 2026-11-20).
  A hook that waited 10 s and then printed allow did not make the denied `touch` run: the file was never created.
  Claude Code ends the turn ("Interrupted · What should Claude do instead?") and sends SIGTERM to the hook about
  45 ms after the "No". A hook that ignored SIGTERM also never printed. Claude Code sends no hook event for the
  "No" (no `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` or `Stop`), so the Up next request stays until
  the next prompt (`UserPromptSubmit`) or the helper wait ends; its helper is already gone, so an answer from the
  row then has no effect. Details: [`claude-permission-request-hook.md`](../references/claude-permission-request-hook.md),
  observation 10.
- Claude answer files older than 10 minutes are removed. The spool file limit rose from 8 KiB to 16 KiB so the
  largest summary fits (and to 64 KiB on 2026-11-21, see the last amendment).
- The release app and Rafu Lightning never share an answer channel (the answers folder is a sibling of the spool).
- The Claude install step was verified with unit tests only. No live probe of the full app path exists yet.
- Codex permission replies with scope `session` were not run live. They follow the same schema. File changes are no
  longer answered from the row (decision 10).
- ~~**Claude Code questions stay terminal-only (decision 9).** The row cannot answer an `AskUserQuestion` question.~~
  Superseded on 2026-11-22 (see the last amendment).

## Revisit trigger

A Claude Code release that changes the `PermissionRequest` hook (decision JSON, timeout, stdin keys, or whether the
dialog shows at the same time), a Codex release that changes server request resolution or the `isOther` meaning, a
a Claude Code release in which a "No" in the terminal no longer stops the hook or sends a hook event, a way to show
the full change of a file change request in the row (then decision 10 can be reconsidered), or a Claude Code version in which the `AskUserQuestion`
question shows in the terminal while a blocking hook waits (then Claude Code questions can be reconsidered).

## Amendment: the approval peek, the fit rule and the swipe (2026-11-20)

On the user's direction (an approved visual mock), a request now also shows in a small "approval peek" card, so
the person can answer without opening the panel. This also gives the island Mac a request surface that does not
need a click on the pill first. Details and constants:
[`notch-companion.md`](../references/notch-companion.md), rule 20.

1. **The peek.** A 360 pt black card hangs below the notch, Rafu's island pill, the plain-display pill or the menu
   bar item. Rafu does not activate, the full panel does not open, and the card is not key when it appears. It
   shows the oldest request of each terminal (decision 4 is unchanged), as a stack with "1 of N". There is no
   auto-dismiss timer: a request blocks the agent. The close button hides the stack until a new request arrives.
   Settings: "Show approval peek", on by default. The full Up next row stays the place that shows everything.
2. **The fit rule.** The peek shows Allow only when the full command, the folder and the permission lines fit the
   card (4 wrapped lines of 44 columns, 88 folder columns, 4 permission lines) and the measured card is at most
   260 pt tall. Otherwise the card is a Review card: it cuts the command to 2 lines and has no accept answer at all
   (no Allow, no "Allow for this session", no right swipe). So the rule of decision 1 holds in the peek too: no
   part of a command is out of view while an accept control is active.
3. **The swipe.** On the top card, a drag (or a two-finger trackpad swipe) to the right sends the primary answer
   and to the left sends Deny. Only the distance at release decides (120 pt); velocity is not used, so a flick
   cannot approve. A label ("Allow" or "Deny") shows before the commit, a short release springs back, and a swipe
   that starts in the 0.5 s quiet interval after the card changed is ignored. Buttons give every answer a swipe
   gives. Every answer path still ends in `AgentRequestStore.choose`.
4. **The glow.** The card border is amber while it waits, then green on allow and red on deny, with the words
   "Allowed" or "Denied", so the result never rests on colour alone.

Alternatives considered: a fourth hover state of the companion panel (rejected: it has no panel in menu bar mode
and changes the tested hover policy); a velocity-based swipe commit (rejected for safety); cutting a long command
under an active Allow with a "Show all" control (rejected by decision 1).

Still not checked in the GUI: the anchors on each surface, keyboard and VoiceOver use of the card, the menu in a
non-key panel, and the two-finger swipe direction on a real trackpad.

## Amendment: file changes and long commands answer in the peek (2026-11-21)

On the user's direction. Two live cases showed the limits. A Claude "Create file" request showed only "Open
terminal" ("can't this be coming in the peek? The options!"). A command of about 190 characters showed Deny and
Review ("Again review not approve"). The rule stays: never allow what the person cannot see in full.

1. **Decision 10 is superseded.** A file change is answerable when the request carries the whole change and every
   part of it fits the bounds exactly. The sources:
   - Claude Code: `tool_input` of Write (`file_path`, `content`), Edit (`file_path`, `old_string`, `new_string`,
     `replace_all`, or an `edits` array) and MultiEdit (`file_path`, `edits`). An edit shows as `- ` lines (removed)
     and `+ ` lines (added).
   - Codex: the `item/fileChange/requestApproval` params carry no diff (only item, thread and turn ids, `reason`
     and `grantRoot`). The diff arrives earlier in the notification `item/fileChange/patchUpdated` for the same
     `itemId`. The proxy keeps the newest patch of at most 8 items per connection, clears them when the turn ends
     or the connection retires, and never logs them. A request with no patch stays terminal-only.
   - A file change is terminal-only when there is no change, more than 2 files, a path over 480 bytes, a body over
     4 KiB, text that sanitizing changed, blank space that could hide the end (decision 5), or a tool input of a
     shape Rafu does not know.
   - Options: Allow, Deny, Deny and stop. "Allow for this session" stays off for both agents. Claude has no such
     answer here. Codex's session grant for files is not verified live, and `grantRoot` is not stable.
2. **The fit rule (peek amendment, rule 2) changes.** The peek shows Allow when the command, or the file change
   text (one line that names the action and the path, then the content or diff), fits 10 wrapped lines of 44
   columns, and the measured card is at most 45% of the visible screen height (between 260 and 420 pt).
3. **In-peek expand replaces Review.** A request that does not fit shows its text cut to 2 lines and a "Show all"
   button. There is no Allow and no right swipe on this card. Deny and a left swipe still work. A click on "Show
   all" (guarded by the 0.5 s click guard) shows the whole request in a selectable box that scrolls (at most
   220 pt tall), with Allow and the right swipe active. A new card always starts collapsed. Only a click expands;
   nothing expands by itself. VoiceOver reads the whole box as one element, with the path and "New content" or
   "Diff".
4. **The spool file limit rose from 16 KiB to 64 KiB** (the summary of a file change holds up to 4 KiB of body).

Alternatives considered: Claude's "accept edits for this session" through `updatedPermissions` with
`{type: "setMode", mode: "acceptEdits", destination: "session"}` (not built: not verified live, and the person
should see each change); a Review button that opens Up next (rejected: the user asked for the answer in the peek);
a larger fixed card (rejected: small screens).

Revisit trigger: the Codex `patchUpdated` notification and the Claude `tool_input` key names are now load-bearing.
A Codex or Claude Code release that renames them, sends the patch after the request, or splits one change over
several notifications makes the file-change rows terminal-only again (the safe result) until Rafu reads the new
shape.

## Amendment: Claude requests for MCP tools answer in the peek (2026-11-21)

On the user's direction. A Claude permission prompt for a tool of another MCP server (for example the Atlassian
connector) showed only "Needs you", because the helper summarized Bash, Edit, MultiEdit and Write and nothing else.

1. **A new request kind, `toolCall`.** A Claude `PermissionRequest` for a tool named `mcp__<server>__<tool>` is
   answerable from the peek and from Up next. The title is "Use MCP tool". The tool identity goes in the existing
   `reason` field and the arguments in the existing `command` field, so the bounds, the sanitizer, "Show all" and
   the answer path are the ones that already exist.
2. **What the person sees.** `reason` has two lines: the friendly server and the tool, then the raw tool name.
   The raw name is always shown, so the friendly form cannot hide the real target. The arguments show as sorted,
   pretty JSON text. **Nothing is masked**: a hidden value would let the person approve what the row does not
   show. The text stays in memory and in the private spool file and is never logged.
3. **Name rule.** A name is accepted only if it starts with `mcp__`, is at most 200 bytes, has only
   `A-Z a-z 0-9 _ - .`, and has a non-empty server and tool (split at the first `__` after the prefix). Any other
   name gets no row (Claude's own dialog stays). A server that starts with `claude_ai_` shows without that
   prefix, with spaces for underscores and "(claude.ai)". Rafu cannot prove where a server comes from, so this is
   a label and the card never says "trusted" or "official".
4. **Bounds and terminal-only.** Arguments at most 2 KiB (decision 5 bound for a command). A request is
   `terminalOnly` (the row offers "Open terminal" only) when the arguments or the identity were cut or changed by
   the sanitizer, or when blank space could hide the end. A `tool_input` that is present but is not a JSON object
   gives no summary and no row (an absent `tool_input` counts as `{}`).
5. **Answers.** Allow, Deny, Deny and stop. There is no "Allow for this session" (decision 7 holds). The hook
   decision JSON is the same as for Bash: the answer channel has no tool name, so no change to the answer files,
   the spool or the hook entry was needed. ~~The Codex proxy never answers this kind.~~ Superseded the same day by
   the amendment "Codex requests for MCP tools answer in the peek" below.
6. ~~**Codex stays out.** A Codex approval for a tool of another MCP server (`mcpServer/elicitation/request`) is
   still not followed by the proxy and still shows in the terminal only (the decision about pre-approving Rafu's
   own tools for Codex, [`0044-pre-approve-rafu-tools-for-codex.md`](0044-pre-approve-rafu-tools-for-codex.md),
   decision 5).~~ Superseded the same day by the amendment below.

Alternatives considered: a card for any unknown tool such as `WebFetch` (rejected: each built-in tool needs its own
review of what must be shown); new fields on `CanvasAgentRequest` for server, tool and arguments (rejected: more
coding, sanitizer and IPC surface for no gain); reuse of the `command` kind (rejected: the card would say "Run
command" and VoiceOver "asks to run", which is false); masking argument values (rejected, see 2).

Not verified live: that Claude Code sends `PermissionRequest` with `tool_name` in the `mcp__server__tool` form and
`tool_input` as the arguments object. The hand check proves it. If Claude Code sends another form, the name rule
gives no row and the terminal dialog stays (the safe result).

## Amendment: Codex requests for MCP tools answer in the peek (2026-11-21)

On the user's direction. It supersedes items 5 (last sentence) and 6 of the Claude amendment above, and reverses
decision 5 of the decision about pre-approving Rafu's tools
([`0044-pre-approve-rafu-tools-for-codex.md`](0044-pre-approve-rafu-tools-for-codex.md)) for tool approvals. Detail and
evidence: [`codex-app-server-approvals.md`](../references/codex-app-server-approvals.md), section "MCP tool approvals are
elicitations".

1. **The proxy follows `mcpServer/elicitation/request`.** (Codex 0.171.0.) A Codex request to run a tool of an MCP
   server opens the same `toolCall` request as the Claude case: same "Use MCP tool" card, same identity lines, sorted
   JSON arguments up to 2 KiB with no masking, "Show all", Allow, Deny, Deny and stop, no session answer. No new
   kind, no new field on the request and no change in the app were needed. The thread check, the 8-request bound, the
   clear paths and the single masked frame with the original JSON-RPC id are unchanged.
2. **Recognition rule.** A request is a tool approval only when: mode `form`; an empty form schema; `_meta`
   has `codex_approval_kind` equal to `mcp_tool_call`; `serverName` is non-empty and has no `__`; `_meta.tool_name` is
   non-empty; `_meta.tool_params` is a JSON object; and the built name `mcp__<server>__<tool>` passes the Claude name
   rule and splits back into the same server and tool. Any other shape gives no row and the terminal answers, as
   before. A generic form (a property in the schema) and a `url` elicitation stay terminal-only with no row.
3. **Unknown `_meta` key.** A `_meta` key that Rafu does not know (for example `codex_sensitive_action`) makes the
   row terminal-only ("Open terminal"), because the request may ask for more than the card shows. Arguments that are
   cut or changed by the sanitizer do the same.
4. **Answers.** Allow sends `{"action":"accept","content":{}}`, Deny sends `{"action":"decline"}`, Deny and stop
   sends `{"action":"cancel"}`. Rafu never sends `_meta`, so it never sends `persist`: no "remember for this session"
   or "always allow" can come from Rafu, and no session answer exists in the row.
5. **Not shown.** `message`, the display title, the display arguments and the connector fields are free text from
   Codex. The card builds its identity from `serverName` and `tool_name` only.

Alternative considered: a row for generic forms ("Answer in the terminal"). Rejected: it needs a new kind and title,
and the agent hook state already shows "Needs you". "Deny and stop" as a decline plus an injected `turn/interrupt` was
rejected: the proxy would have to invent a client request id.

Not verified live (the `_meta` key names are INFERRED from strings in the Codex binary, not from the schema): the
exact `_meta` of a real request; that the accept shape runs the tool; that the terminal prompt closes by itself; that
`cancel` stops the turn (it may only skip the call; then the fallback is Allow and Deny only for a Codex tool call,
with a new stored flag). A request whose shape does not match the rule gets no row, so a wrong guess hides the feature
and does not make it unsafe. Test evidence: 4143 tests passed in parallel mode in the implementor's worktree; the
`--no-parallel` result was not supplied to the documentor.

## Amendment: every agent prompt shows; question sets answer in Rafu (2026-11-22)

On the user's direction: "every kinda choice and question set should come to Rafu" (Claude Code and Codex can ask
several questions at once), and "no guesses": a fact that is not checked is parked, not built. The coordinator
reported the work merged (shared contract, Codex group, UI group, Claude group, and the "Needs you" hint follow-up).
Detail and evidence: [`claude-permission-request-hook.md`](../references/claude-permission-request-hook.md),
[`codex-app-server-approvals.md`](../references/codex-app-server-approvals.md),
[`agent-prompt-coverage.md`](../references/agent-prompt-coverage.md),
[`notch-companion.md`](../references/notch-companion.md) rule 21.

1. **No prompt is dropped in silence.** Three silent allow-lists caused the repeated gaps (Claude summary returned
   nil for unknown tools, Codex `parse` returned nil for unknown requests, the plain "Answer in the terminal" row).
   Now a request that Rafu does not know shows read-only, with the agent's own text and "Open terminal" (new
   request kind `notice`). Only a method that is not a prompt for the user returns no row. `AgentRequestShape`
   records key names and value types, never values (tested), and `AgentPromptCoverageTests` fails when a Claude
   Code tool name or a Codex server request method has no class. Each Claude Code or Codex update follows the
   version checklist in the coverage note.
2. **Question sets answer in Rafu.** This supersedes decision 9 (Claude questions terminal-only) and the last
   sentence of decision 6 (Codex free text needs the terminal). Claude Code: the `PermissionRequest` hook receives
   `AskUserQuestion`; the terminal question stays visible while the hook waits; the hook allows with `updatedInput`
   that holds `answers` keyed by question text (live probe, Claude Code 2.1.330). Decision 9 recorded that a
   `PreToolUse` hook hides the question; that is still true and Rafu does not use it. Codex: a question set with a
   typed note answers as `user_note: <text>` (source checked, 0.171.0). Up to 4 Claude questions and 3 Codex
   questions; multi-select exists for Claude only.
3. **The answer file now carries chosen labels and typed text.** This changes decision 2, which said the answer
   file has no text. It still never carries question text or request text. The file stays 0600 in a 0700 folder, is
   deleted on read and pruned after 10 minutes, and is never logged. The typed text is at most 1 KiB for each
   question and sanitized. The file limit rose from 1 KiB to 16 KiB. The helper keeps the original `tool_input` and
   checks each label against it; a mismatch prints nothing and the terminal dialog stays. A multi-select label that
   holds `", "` and two questions with one text are terminal-only.
4. **New request kinds and a wider tool card.** `plan` (Claude `ExitPlanMode`, read-only, always terminal-only) and
   `notice`. A Claude built-in tool with a plain name (Read or Glob outside the folders, WebFetch, WebSearch,
   NotebookEdit, Skill, Agent, ...) gets the same "Use MCP tool"-style card with the identity "Claude Code tool:
   <name>" and the whole `tool_input` as JSON. This supersedes the sentence in decision 5 that Claude requests for
   other tools get no row. `AskUserQuestion` and `ExitPlanMode` are excluded from it by name.
5. **Codex tool card repaired.** The `_meta` key list is now the set that Codex 0.171.0 writes (source tag
   `rust-v0.171.0`): the earlier inferred list missed `tool_annotations`, `link_id` and `link_is_implicit`, so a
   connector tool (Google Calendar) was terminal-only. Four keys keep it terminal-only (`codex_sensitive_action`,
   `codex_requires_user_input`, `codex_strict_auto_review`, `approvals_reviewer`). Accept now sends
   `{"action":"accept","content":null}` (this replaces `content: {}` of the Codex MCP amendment). `cancel` does not
   stop the turn, so the Codex button reads "Cancel tool call", not "Deny and stop", and it sends
   `codex_approval_cancellation_reason: "user"` in `_meta`. A tool approval that arrives as a question (id prefix
   `mcp_tool_call_approval`) is a terminal-only notice, because it holds no arguments.
6. **Network approvals answer in the row.** A Codex command approval with `networkApprovalContext` shows "Network:
   <protocol> <host>" and answers accept, decline or cancel, with no session answer. This supersedes the
   `networkApprovalContext` case in decision 5. Every Codex server request with an id for the bound thread is parsed;
   the older approval methods name the thread in `conversationId`.
7. **Pending amendment: lasting grants (not approved).** The remember choices are modelled and tested but OFF
   through `CanvasAgentRequest.PersistPolicy.current`: Codex "Allow for this session" and "Always allow" for a tool
   (`_meta.persist`), the Codex command prefix rule (`acceptWithExecpolicyAmendment`), and the Claude rule suggestion
   (`updatedPermissions`, one understood `addRules` entry, echoed by the helper). Decision 7 stays in force: Rafu
   sends no `persist` and no `updatedPermissions`. The user has not agreed to change that. If the user agrees, the
   choices go in the menu with their exact effect as text, never on the primary button or the swipe.
8. **Parked** (each needs a user action or a probe): Claude "Chat about this"; Claude plan approval answering
   (probe P2); Claude MCP elicitation answering (probe P3, and a new hook entry that the user approves in a Connect
   review); Codex generic form answering; Codex "Implement this plan?" (needs a screenshot); lasting grants (the
   user's decision). A sandboxed Claude network request cannot be answered at all: no hook runs for it (hooks
   documentation, 2026-11-22).

Alternative considered: one fixed text ("Answer in the terminal") for every unknown prompt. Rejected: it is the
cause of the repeated gaps, because it shows no question, option or reason.

Not verified live: the Claude generic tool card, the plan card, the notice rows; every Codex answer shape in item 5
and 6 (source only; the Google Calendar terminal-only symptom was seen live). Test evidence: each group's parallel
run passed in its worktree; counts were not supplied. Coordinator runs on `main`: Coordinator on `main` (2026-11-22, after the merge of the Needs-you hint follow-up): `./script/test.sh` and `./script/test.sh --no-parallel` both passed (4,174 tests in 339 suites and 795 tests in 54 suites); `./script/build_and_run.sh --verify` passed. Hand tests in Rafu Lightning are open.

## GUI checks pending

For the Codex MCP tool card (needs a live Codex turn and one MCP server in the user's Codex config that is not
Rafu): ask Codex to call a tool of that server with arguments. The peek must show "Use MCP tool", `<server>: <tool>`,
the raw name and the sorted JSON. If no card shows, or the card says "Open terminal" only, capture one request and
compare the `_meta` key names (never values) with the rule. Then check: Allow runs the tool and the terminal prompt
closes by itself; a later answer in the terminal closes the card; Deny makes Codex report the refusal; Deny and stop
stops the turn (if it does not, report it); a tool with no arguments shows `{}`; arguments over 2 KiB give "Open
terminal" only; a Rafu tool raises no Codex question; a Claude MCP tool card is unchanged; VoiceOver, keyboard and a
second window.

For the MCP tool card: with "Answers from Up next" on, ask a Claude terminal for an MCP tool (for example "Atlassian
MCP - Get Atlassian user info"). The peek must show "Atlassian MCP (claude.ai): atlassianUserInfo", the raw name and
`{}`. Allow runs the tool and the terminal prompt goes away; Deny makes Claude report the denial; long arguments
give "Show all", and arguments over 2 KiB give "Open terminal" only. Check VoiceOver, keyboard reach and a second
window. Bash and file edit requests must still show their cards.

Also: answer from the row and from the terminal (the row closes, no stuck prompt); a stale click (the message "This
request was already answered."); keyboard use of the row buttons on a pinned panel; VoiceOver for the badge, the row
and the island card; contrast of the badge and the row; a second window (the request of window B shows and answers
from the row, "Show this agent in its window" opens B); island card expansion and the return to Usage; the Settings
switch and the Connect review for the Answer hook, including Disconnect.
