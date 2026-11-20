# Answering Claude Code permission requests through a blocking hook

Applies to: `Sources/RafuAgentEventHelper/AgentEventHelper.swift` and `main.swift` (the `--answer` mode),
`Sources/RafuCore/AgentTracking/AgentAnswerChannel.swift` (the private answer files, the watch lock, the wait loop and
the decision JSON), `AgentPermissionRequestSummary.swift` (the bounded `tool_input` summary), `AgentHookEvent.swift`
(`requestSummary`), `Sources/RafuCore/CanvasBridge/CanvasAgentRequest.swift` (`offersSessionAllow`), and
`Sources/RafuApp/AgentTracking/ClaudePermissionAnswerBridge.swift` (event to request, decision to answer, write and
dismiss), `Sources/RafuCore/AgentTracking/AgentHookConfiguration.swift` and `AgentHookInstaller.swift` (the answer
entry, `scope: .answers`), `Sources/RafuApp/AgentTracking/ClaudePermissionAnswerCoordinator.swift` (request lifetime and
the watch lock), `AgentActivityStore.swift`, `AgentHookSetupModel.swift` and `AgentTrackingSettingsSection.swift` (the
switch and the Connect step). Tests: `Tests/RafuCoreTests/AgentAnswerChannelTests.swift`,
`AgentPermissionRequestSummaryTests.swift`, `AgentHookConfigurationTests.swift` (suite "Agent hook answer entry"),
`Tests/RafuAppTests/ClaudePermissionAnswerBridgeTests.swift`, `ClaudePermissionAnswerCoordinatorTests.swift`.

Last verified: Swift 6.4.2, macOS 27.2.1, 2026-11-20, Claude Code 2.1.328 (live probes below, with the real `claude`
in a pseudo-terminal, model `haiku`, a temporary settings file, and the real helper binary). The install step was
verified with unit tests only (temporary folders, a fixed clock); no live probe of the full app path yet.

Status: the helper mode, the answer channel, the app mapping, the hook entry, the Settings switch, the Connect step
and the request lifetime exist and are tested. The Up next row that shows and answers a request is built separately;
until it exists, a request opens in `AgentRequestStore` and ends by the rules in "The install step (built)".

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

## The install step (built)

- **Two scopes in one file.** `AgentHookScope.activity` is the normal entry per event; `.answers` is the one Claude
  `PermissionRequest` entry (`AgentHookConfiguration.answerCommand`, `timeout` 300). A command is an answer command
  when it is a Rafu command that ends in ` --answer` (`isAnswerCommand`). The helper uses the same constant
  (`AgentHookConfiguration.answerFlag`).
  - The activity Connect, its stale-entry cleanup and `isConnected` ignore the answer entry. Before this change the
    activity Connect would have dropped the answer entry as a "stale" Rafu command, because its command differs.
  - The activity Disconnect removes every Rafu command, so it removes the answer entry too (without activity
    tracking nothing drains the spool). Its review preview lists the answer entry, and the sheet says so.
  - The answer Connect adds only the answer entry and replaces an older answer entry. The answer Disconnect removes
    only it. `isAnswerConnected` checks only it.
  - The review preview now shows the entries that are really removed (with their own timeouts), not a copy of the
    current command.
- **Settings.** Settings > Agents > "Answers from Up next": the switch "Answer Claude Code permission requests from
  Up next" (off by default, `agentTrackingClaudeAnswersEnabled`) and an "Answer hook" row with its own reviewed
  Connect and Disconnect. Connect is disabled until Claude Code activity tracking is connected. The switch alone
  installs nothing. The last seen state of the entry is kept in `agentTrackingClaudeAnswersConnected`, like the
  activity providers, so the lock can be taken at launch without reading the settings file.
- **The lock.** `AgentActivityStore` takes the `AgentAnswerWatchLock` only when `wantsAnswerWatch` is true: the spool
  watcher runs, the switch is on, the answer entry is connected and Claude Code activity tracking is connected. Any
  change of these (switch, Connect, Disconnect, `stop()`) re-evaluates it. App quit (`applicationWillTerminate`)
  calls `stopAnswering()`. Taking the lock is a few system calls on the main actor (folder, `open`, `flock` without
  waiting), done only on these changes.
- **Request lifetime** (`ClaudePermissionAnswerCoordinator`, rules in `ClaudeAnswerRequestBook`), after each spool
  fold and each 30 s clock tick:
  - Open: an answerable event, while the lock is held, younger than `waitSeconds`. The terminal is the one live Rafu
    terminal that `AgentTerminalMatcher` gives for the event's own process chain (folder rule only without a chain).
    No match, two matches, or a store refusal (`conflict`, `full`) writes `dismiss`.
  - Answer: when `AgentRequestStore.decision(for:key:)` has a decision, write it (`submit`) and close the request
    at once. The store is observed (`withObservationTracking`) while requests are open, so the answer goes out
    without a poll.
  - Done in the terminal: a later event of the same session and the same sub-agent closes the request and writes
    `dismiss`: `PostToolUse` or `PostToolUseFailure` of the same tool, `UserPromptSubmit`, `Stop`, `StopFailure`,
    `SubagentStop`, `SessionEnd`, or a new answerable `PermissionRequest`. A main-session `SessionEnd` ends a
    sub-agent's request too. The normal entry's `PermissionRequest` (no summary), `Notification` and `PreToolUse`
    do not end it. A finished tool of another kind does not either, because parallel tools exist.
  - Expiry: at `receivedAt + waitSeconds`, close and `dismiss`.
  - Cleared elsewhere: when the request is no longer in the store (terminal exit calls `CanvasLiveBridge.remove`,
    which clears the terminal's requests; a new route also clears them), only `dismiss`. A terminal that is no
    longer live closes and dismisses.
  - Switch off or entry gone: release the lock, close every request, `dismiss` each. Quit: release the lock and close
    requests without writing (the free lock stops each helper).
- **File work off the main actor.** Answer and dismiss files are written by `ClaudeAnswerIO.perform` (`@concurrent`).
  Each event id gets at most one write from the coordinator, because the request leaves the book before the write.
- **Not verified live.** Whether Claude Code sends any hook event when the person answers "No" in the terminal was not
  probed. If it sends none, the request stays until the next prompt (`UserPromptSubmit`) or the expiry.

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
swift test --filter "AgentAnswer|AgentPermission|ClaudePermission|AgentHook|AgentActivity"
```

`--filter` matches the test type and function names (`ClaudePermissionAnswerCoordinatorTests/opensMatched()`), not
the Swift Testing display names: a filter like `"Claude permission"` runs no test and only prints "No matching test
cases were run" (seen with Swift 6.4.2).

## Related

- [`codex-app-server-approvals.md`](codex-app-server-approvals.md): the Codex side of the same Up next answer path.
- [`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md): the normal hook helper, the spool and the merge.

## Claude Code questions use a different hook

Verified with Claude Code 2.1.329 and Haiku in an interactive terminal on
2026-11-20. A blocking `PreToolUse` hook for `AskUserQuestion` hides the
question until the hook exits. Do not use this hook to wait for an Up next
answer. A user at the terminal would have to wait for the helper to exit
before they could select a choice.

To reproduce, use a temporary settings file with a `PreToolUse` command hook
that matches `AskUserQuestion`. Have the hook record its start and end times,
wait 12 seconds, and exit with no output. Run Claude with
`--model haiku --permission-mode default --setting-sources project --settings <temporary-file>`.
Ask it to use the question tool with two choices. Compare the hook times with
the time the selectable choices first appear in the terminal.

The hook received `tool_input.questions`, an array. Each question contained
`question` and `header` strings, an `options` array of objects with `label`
and `description` strings, and `multiSelect: false`. The terminal showed a
running-hook indicator during the wait. The first selectable choices appeared
about 20 ms after hook exit. The safety check ended the probe at that point.
Answer injection and timeout behavior remain unverified for this hook.
