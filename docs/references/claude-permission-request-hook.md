# Answering Claude Code permission requests through a blocking hook

Applies to: `Sources/RafuAgentEventHelper/AgentEventHelper.swift` and `main.swift` (the `--answer` mode),
`Sources/RafuCore/AgentTracking/AgentAnswerChannel.swift` (the private answer files, the watch lock, the wait loop and
the decision JSON), `AgentPermissionRequestSummary.swift` (the bounded `tool_input` summary), `AgentHookEvent.swift`
(`requestSummary`), `Sources/RafuCore/CanvasBridge/CanvasAgentRequest.swift` (`offersSessionAllow`), and
`Sources/RafuApp/AgentTracking/ClaudePermissionAnswerBridge.swift` (event to request, decision to answer, write and
dismiss). Tests: `Tests/RafuCoreTests/AgentAnswerChannelTests.swift`, `AgentPermissionRequestSummaryTests.swift`,
`Tests/RafuAppTests/ClaudePermissionAnswerBridgeTests.swift`.

Last verified: Swift 6.4.2, macOS 27.2.1, 2026-11-20, Claude Code 2.1.328 (live probes below, with the real `claude`
in a pseudo-terminal, model `haiku`, a temporary settings file, and the real helper binary).

Status: the helper mode, the answer channel and the app mapping exist and are tested. The hook entry is not installed
by Rafu yet, there is no Settings switch, and nothing in the app drains the answer request into the Up next row yet.
Those belong to the next step (see "What the install step needs").

## Observations (Claude Code 2.1.328)

1. **The terminal dialog and the hook run at the same time.** When a tool needs permission, Claude Code shows its own
   dialog ("Do you want to proceed?") and starts the `PermissionRequest` hook in the same instant (the dialog was
   seen 20 ms before the hook's first log line; the status line reads "running PermissionRequest hook"). A hook that
   waits does not hide the terminal prompt. This is what makes a blocking hook safe.
2. **The hook may block up to its `timeout`.** A hook that slept 8 s and then printed an allow decision held the
   request for 8 s; the tool ran only after it printed.
3. **Allow and deny JSON.** On stdout: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":
   {"behavior":"allow"}}}`. The screen then shows "Allowed by PermissionRequest hook", the dialog closes, and the tool
   runs. `behavior` `deny` with `message` shows "Denied by PermissionRequest hook" and the model receives the
   message (it answered "Denied"). The tool does not run. With `"interrupt": true` in the decision the turn stops
   ("Interrupted - What should Claude do instead?") and the model makes no second call.
4. **No output keeps the dialog.** A hook that exits 0 and prints nothing leaves the terminal dialog in charge (also
   seen with the real helper when Rafu does not watch, and after a `dismiss`). Output that is not JSON was not probed.
5. **A timeout kills the hook and keeps the dialog.** With `timeout: 5` and a hook that slept 30 s, the hook got
   SIGTERM at 5.0 s. The dialog stayed and a terminal answer at 12 s ran the command.
6. **An answer in the terminal does not stop the hook.** The user pressed Return in the dialog 14 s into a 30 s hook.
   The command ran at once and the hook process was not signalled: it ran to its own end (30.1 s). So a waiting
   helper must end itself, or Rafu must tell it to (dismiss).
7. **A late hook decision does not touch a later request.** Hook A (20 s) was still running when the user answered
   dialog A in the terminal, and Claude showed dialog B (a second tool call, hook B). When hook A printed `deny` at
   20 s the dialog B stayed open. Only hook B's own output (at its 20 s) decided B.
8. **`PermissionRequest` stdin.** Keys: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `effort`,
   `prompt_id`, `scratchpad_dir`, `hook_event_name`, `tool_name`, `tool_input`, `permission_suggestions`. There is no
   `tool_use_id`. Bash `tool_input` is `{command, description}`; Write is `{file_path, content}`. The event id for
   Rafu comes from the helper, not from Claude.
9. **Non-interactive mode** (`claude -p`) was not probed: the documented behaviour is that `PermissionRequest`
   hooks do not run there. Rafu's Ensemble terminals run the interactive UI.

## The design that follows

- A separate hook entry, only for `PermissionRequest`: `'<helper>' claude '<spool>' --answer` with `timeout` 300
  (`AgentAnswerChannel.hookTimeoutSeconds`). The normal 1 s entry for the same event stays: it records the state flag
  as before. The two entries write two events for one request (different ids); folding is state based, so that is
  harmless.
- The helper reads all of stdin, builds the event with a bounded `requestSummary` and writes it to the spool. It
  prints a decision only when Rafu answered `allow` or `deny`. It prints nothing (Claude keeps its dialog) when
  Rafu is not watching, the tool is not Bash, Edit, MultiEdit or Write, the summary is empty, Rafu sent `dismiss`,
  Rafu stopped watching, or 285 s passed (`waitSeconds`). A 290 s alarm is the last resort (`alarmSeconds`).
- **"Rafu is watching" is a held `flock`.** The app holds an exclusive lock on `AgentTracking/answers/watcher.lock`
  (`AgentAnswerWatchLock`). The helper takes a shared lock without waiting; a refusal means a live holder. The kernel
  drops the lock when the app quits or crashes, so there is no stale "watching" flag. The helper checks it before it
  writes the event and on every poll.
- **Answers are files.** `AgentTracking/answers/<EVENT ID>.json` (folder 0700, file 0600) holds `{eventID, verdict,
  interrupt}` and no text. The app writes it under a hidden name and renames it (the first answer for an event wins).
  The helper polls every 0.2 s, reads it once (`lstat`: regular file, owned by the user, no group/other bits, at most
  1 KiB, event id equal to the name), and deletes it, valid or not. A file for another event id is never read.
  The answers folder is the spool's sibling, so the release app and Rafu Lightning never share a channel.
- **The fixed denial text.** A `deny` carries `The user denied this request in Rafu.` No user text travels.
- **The request key is the event id.** `ClaudePermissionAnswerBridge.request(for:)` sets
  `CanvasAgentRequest.key = event.id`, so the store's `CanvasAgentRequestAnswer.key` is the answer file name.
- **Options.** Run or Apply, Deny, Deny and stop. "Allow for this session" is not offered
  (`offersSessionAllow == false`): the hook could only grant it through `updatedPermissions`, which Rafu does not send.
  Deny and stop maps to `interrupt: true`.
- **What the row shows is what runs.** A command over 2 KiB, a path over 480 bytes, or text that sanitizing changed
  makes the request terminal-only (`isComplete == false`): the row shows "Open terminal" only.
- **Spool size.** `AgentHookSpool.maximumFileBytes` rose from 8 KiB to 16 KiB, and the spool encoder no longer
  escapes `/`, so the largest summary (2 KiB of escaped command, 512 of description) fits a file.

## Rules

- **No request or answer text in any log.** The helper prints only the decision JSON, and only to stdout.
- **The helper never answers for the user.** There is no default allow: a missing answer, an unreadable file, a
  timeout and a stopped Rafu all print nothing.
- **Dismiss when Rafu will not answer.** The app must write `dismiss` for an event whose session matches no Rafu
  terminal, and when the person answered in the terminal (the next event of that session). Otherwise the helper
  waits until its timeout. The terminal prompt is never affected.
- **Prune stale files.** `AgentAnswerChannel.prune()` removes answer files older than 10 min (a helper that timed out
  never reads its file). `write` calls it.

## What the install step needs

1. `AgentHookConfiguration`: a second `PermissionRequest` entry for Claude with the command
   `command(helper:provider:spool:) + " --answer"` and `timeout` `AgentAnswerChannel.hookTimeoutSeconds`.
   `isRafuCommand` already matches it (same quoted helper prefix); the "already connected" test and the exact-entry
   merge must treat it as a separate, opt-in entry, and Disconnect must remove it. Show it in the review preview.
2. A Settings switch and an explicit Connect step (a trust transition: Rafu can now allow a tool for Claude).
3. `AgentActivityStore`: hold one `AgentAnswerWatchLock` while the switch is on and a Claude hook is connected.
   Release it when the switch goes off or the app quits. Never hold it otherwise: a held lock makes every helper wait.
4. On a drained event with `ClaudePermissionAnswerBridge.isAnswerable`: match the session to a Rafu terminal. If it
   matches, open `ClaudePermissionAnswerBridge.request(for:)` in `AgentRequestStore` under that controller. If not,
   `dismiss(eventID:)`.
5. Poll or observe `AgentRequestStore.pendingDecision(for:)` and call `submit(_:)`. Close the request when the next
   event of the session shows the tool ran or was answered, and `dismiss(eventID:)` so the helper stops.
6. Clear requests and release the lock on the same events as the Codex requests (release, suspend, terminal exit).

## Reproduce

A stand-in hook script logged its stdin, slept, and printed one decision. The run used a pseudo-terminal (Python
`pty`), `claude --model haiku --setting-sources project --settings <temp file> --permission-mode default`, a clean
environment (no Rafu variables), and the prompt "Use the Bash tool to run exactly this command: touch spike-made.txt".
(`echo` alone is auto-allowed and never asks.) The first run in a new folder shows a trust dialog: press Down, then
Return. The end-to-end check used the built helper with a stand-in app (a script that held the lock, drained the
spool and wrote the answer file) for allow, deny with stop, dismiss, and no Rafu at all. Never edit the real
`~/.claude/settings.json`: `--settings` adds a file for one run.

## Verification

```bash
swift test --filter "Agent answer|Agent permission|Claude permission|Agent hook"
```

## Related

- [`codex-app-server-approvals.md`](codex-app-server-approvals.md): the Codex side of the same Up next answer path.
- [`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md): the normal hook helper, the spool and the merge.
