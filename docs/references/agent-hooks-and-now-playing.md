# Agent hooks, activity tracking, and system Now Playing (X11)

- Applies to: `Sources/RafuAgentEventHelper/**` (the `rafu-agent-events`
  hook helper), `Sources/RafuCore/AgentTracking/**` (event model, spool,
  ledger, terminal matching, hook configuration merge and installer),
  `Sources/RafuApp/AgentTracking/**` (`AgentActivityStore`, Settings ▸ Agents
  ▸ Activity tracking, notch "Other agents"), `Sources/RafuApp/Notch/NotchNowPlaying*.swift`,
  `Vendor/MediaRemoteAdapter/**`, `script/build_media_helper.sh`, and the
  `Contents/Helpers` and `Contents/Resources` staging in `script/build_and_run.sh`.
- Initial verification: Swift 6.2 Linux toolchain (swift.org ubuntu24.04), Ubuntu
  24.04, 2026-10-18. Pure logic only (scratch SwiftPM package, 57 Swift
  Testing tests).
- Mac verification: Apple Swift 6.4, macOS 27.0.1 (26A434), arm64,
  2026-10-18. Canonical Lightning build and launch, strict bundle signature
  check, full package tests, and Agents/Ensemble Settings inspection.
  Follow-up runtime checks used the bundled helper with Claude Code 2.1.302
  and Codex 0.163.0. Both emitted SessionStart, UserPromptSubmit, Stop, and
  SessionEnd. Claude used a live reply and temporary `--settings`; Codex used
  a temporary `CODEX_HOME` and a loopback Responses API fixture, with no
  credentials. The user's provider configuration was not changed. Cursor
  2026.07.23-e383d2b returned `Authentication required` before starting its
  temporary-workspace hook test, although `cursor-agent status` reported a
  login. Cursor runtime events and persistent installation into personal
  settings remain unverified.

Helper refresh (2026-11-22, merge 7c13d32): the implementor's parallel run
passed 4,144 tests in 339 suites. Coordinator on `main` (merge 7c13d32): `./script/test.sh` and `./script/test.sh --no-parallel` both passed (4,144 tests in 339 suites and 726 tests in 50 suites). Manual check on Rafu Lightning: the installed helper was made stale on purpose (the 2026-11-21 copy, 6,269,392 bytes); after `./script/build_and_run.sh --verify` the launch refresh replaced it, and `cmp` with `Contents/Helpers/rafu-agent-events` showed the same bytes (6,447,760).

## Mac runtime verification (2026-10-18)

- The actual bundled helper returned exit 0 with no output for malformed,
  oversized, and unknown events. Valid events retained process ancestry and
  used mode 0600. A sentinel in prompt, tool input, and transcript path did
  not appear in the event file. Keeping stdin open triggered the one-second
  alarm and still returned exit 0.
- `AgentActivityStoreTests.watchSpool` uses a real macOS directory watcher,
  an atomic spool write, and an async notification. It verifies that the
  event reaches the store and the consumed file is removed. Its five-second
  deadline fails the test; it is not a synchronization delay.
- Codex hook definitions require trust. For the isolated loopback check only,
  the invocation used `--dangerously-bypass-hook-trust` with a fresh home
  containing only the reviewed Rafu helper commands. Do not add that flag to
  normal terminal launches. In normal use, open `/hooks` and review the Rafu
  entries; installing the JSON file alone does not grant trust. See the
  [official hook trust contract](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).
- The staged MediaRemote adapter started through `/usr/bin/perl` and returned
  a valid `data` envelope with `--no-diff --debounce=150 --no-artwork`. This
  verifies loading and stream output; it does not verify playback controls.
- Full serial verification passed 185 core and 2,402 app tests. Two full
  parallel runs hit `CanvasBridgeIPCTests.typedBridgeRoundTrip` with socket
  read error 35 under suite load. The same test passed alone (0.008 s) and
  in the serial suite. Per the repository's isolation rule, this is recorded
  as scheduler starvation; the unrelated IPC test and its timeout were not
  changed. Hook watcher and redirect tests passed in both modes.

Repeat the automated boundaries with:

```sh
./script/test.sh --filter 'AgentHook|AgentActivity|AgentSession|AgentTerminalMatcher|NotchSystemMedia'
./script/build_and_run.sh --verify
```

For a real Claude event check, write the reviewed hook JSON to a temporary
file, point its commands at the bundled helper and a temporary
`AgentTracking/spool`, then run `claude -p --settings <file> --setting-sources ''
--tools '' --no-session-persistence 'Reply with RAFU_HOOK_CHECK_OK'` from that
temporary folder. Inspect only normalized events, not provider transcripts.

## Sub-agent payloads (Claude Code 2.1.325, 2026-11-15)

Decision and ledger rules: the 2026-11-15 amendment in
[ADR 0029](../decisions/0029-agent-status-vocabulary.md). Verified payload
facts for Claude Code 2.1.325:

- `SubagentStart` carries the base fields plus `agent_id` and `agent_type`.
- `SubagentStop` adds `agent_transcript_path`, `last_assistant_message`,
  `background_tasks` and `session_crons`.
- Base fields: `session_id`, `transcript_path`, `cwd`, `scratchpad_dir`,
  `prompt_id`, `permission_mode`, `agent_id`, `agent_type`, `effort`. There is
  **no `model` field** on any of these events.
- The model and the description exist only in the Agent tool input
  `{description (3 to 5 words), prompt, subagent_type?, model?, effort?}`, which
  arrives as `tool_input` of a `PreToolUse` event. So Rafu links a queued spawn
  (from `PreToolUse`) to the later `SubagentStart` by type; this is a heuristic,
  not an id match.
- The helper reads only `subagent_type`, `model` and `description` from
  `tool_input`, never `prompt`. The description crosses the private spool, as the
  600-character reply preview does.
- Codex 0.169.0: NOT verified. Its binary has the names `SubagentStart` and
  `SubagentStop`, and `agent_type`, `agent_id` and `model` in `spawn_agent`
  arguments. Rafu has no Codex tool-input path.

Build and tests on `main` (Xcode, macOS 27.2 SDK 26B118, Swift 6, Darwin 27.2.0):
build OK; 466 tests in 33 suites (parallel) and 3726 tests in 301 suites
(`--no-parallel`) passed. No on-device check of the sub-agent chip yet.

## Rule or observed behavior

### Hook helper

1. Hook command: `'<AppSupport>/<App>/AgentTracking/bin/rafu-agent-events' <claude|codex|cursor> '<AppSupport>/<App>/AgentTracking/spool'`.
   `<App>` is `RafuAppIdentity.applicationSupportDirectory` ("Rafu Lightning"
   or "Rafu"), so the two apps never share hooks or a spool. Both paths are
   POSIX single-quoted (`AgentHookConfiguration.shellQuoted`), because the
   agent runs the command through `/bin/sh` and "Application Support" has a
   space.
2. The helper must never delay or change the agent: `alarm(1)` with a
   `SIGALRM` handler that calls `_exit(0)`, every path exits 0, nothing goes
   to stdout or stderr. Exit 0 with empty output is "no decision" for Claude
   Code and Codex hooks.
3. Bounds: stdin at most 1 MiB (over that, nothing is written); one spool
   file at most 8 KiB; the helper stops writing at 2048 spool files; the
   assistant message preview is kept only for `Stop`/`AgentResponse` and is
   at most 600 characters; other fields 256 characters, `cwd` 2048. Control
   characters are removed. The preview stays in memory only. Since 2026-11-15
   (companion chrome, commit 9827e21) the notch and menu card agent cards for
   agents outside Rafu show it as "last message" (2 lines); before that only
   voice used it. The card also shows "Last seen Xm ago" from the
   `AgentActivityStore` clock (not `Text(style: .relative)`, to keep work low
   while the panel is hidden), and an 8-character session suffix only when
   title and provider collide. See [`notch-companion.md`](notch-companion.md)
   rule 17. Not checked on a device.
4. The helper keeps only identity and lifecycle: session id, turn id,
   subagent id, event name, `cwd`, tool name, notification type, tool-use id,
   the bounded preview, and its parent PID chain (at most 16 PIDs, read with
   `proc_pidinfo(PROC_PIDTBSDINFO)`; no command lines, no environment).
   Prompts, tool inputs and outputs, and transcript paths are discarded.
   One exception: the `--answer` mode for a Claude `PermissionRequest` keeps a
   bounded summary of the command or file path (see
   [`claude-permission-request-hook.md`](claude-permission-request-hook.md)).
   Unknown event names are dropped.
5. The second argument must be an absolute path that ends in
   `AgentTracking/spool`; otherwise the helper writes nothing.
6. Spool: directory 0700, files 0600, written under a hidden temporary name
   and renamed into place. A spool or `AgentTracking` folder that is a
   symbolic link is refused.

### App side

7. `AgentActivityStore.shared` (`@MainActor @Observable`) watches the spool
   with a `DispatchSource` file-system source only while at least one
   provider is connected. It drains off the main actor (`@concurrent`),
   oldest files first, at most 256 files per pass and 8 passes per drain,
   and deletes every file it read (valid or not). A clock runs every 30 s
   only while sessions exist, to age states and expire sessions.
8. Folding (`AgentSessionLedger`): `UserPromptSubmit`/`PreToolUse`/`PostToolUse`
   → `working`; `PermissionRequest` or `Notification(permission_prompt)` →
   `waitingForPermission`; `PreToolUse` of `AskUserQuestion` or
   `request_user_input`, `Notification(idle_prompt|elicitation_dialog)`, and
   `StopFailure` → `needsInput`; `Stop` → `finished` with a reply;
   `SessionStart` and Codex `Interrupt` → `finished` without a reply;
   `SessionEnd` → `ended`. Subagent events keep the parent `working` and
   never finish it. Duplicates, events older than the session's newest, and
   late events from an earlier turn are ignored. Ended sessions go after
   2 min, silent sessions after 6 h, at most 256 sessions.
9. Matching to Rafu terminals (`AgentTerminalMatcher`): a session belongs to
   the terminal whose shell PID (`WorkspaceTerminalController.shellProcessID`)
   is in the helper's parent chain. Only a session with no chain may match
   by folder plus provider. A session whose chain does not hold any terminal
   PID runs outside Rafu ("Other agents" in the notch), unless the chain
   holds Rafu's own PID.
10. Surfaces keep their output-based fallback. Notch: a matched terminal uses
    the hook phase for work and attention; "reply ready" still needs the
    terminal's own bell, because opening the terminal is what clears it.
    Outside agents show "reply ready" for 2 min. Titlebar attention is hook
    attention OR the bell. The Ensemble terminal node header shows
    "Working", "Needs approval", "Needs input", "Reply ready", or "Waiting"
    (one line in `CanvasCardChrome.stateWord`).
10a. Turn-end trigger for usage (2026-11-15). `AgentActivityStore.apply`
    collects providers from events the ledger accepted that are `Stop`,
    `SubagentStop`, `StopFailure`, or `SessionEnd` and at most 60 s old (the
    freshness guard, `UsageRefreshSchedule.maximumEventAge`), then calls the
    `onTurnEnded` closure once per fold. It is a closure, not observed state, so
    no view re-renders. A spool replayed at launch holds old events and so
    starts no usage read burst. The schedule that consumes it is in
    [`usage-rings-and-pace.md`](usage-rings-and-pace.md) (Refresh schedule). No
    new hook entries are written; Codex hooks still need the user's trust
    through `/hooks`, and until then usage uses only its fallback.

### Hook installation

11. Connect and Disconnect are explicit and two-step: `AgentHookInstaller.prepare`
    reads the file and builds an `AgentHookChange` (exact path and the exact
    entries as JSON); the review sheet shows it; only Confirm writes. No
    provider file is written at launch. `refresh()` on the Settings pane reads
    the provider files; its only write is the helper refresh in rule 15a.
12. Files: Claude Code `$CLAUDE_CONFIG_DIR` or `~/.claude/settings.json`;
    Codex `$CODEX_HOME` or `~/.codex/hooks.json` (as Cider); Cursor
    `~/.cursor/hooks.json` (flat entries, `"version": 1`). A relative
    `CLAUDE_CONFIG_DIR`/`CODEX_HOME` is ignored.
13. The merge appends one `{"hooks":[{"type":"command","command":…,"timeout":1}]}`
    entry per event and never removes, edits, or reorders another hook. Rafu's
    entries are the command hooks whose command starts with the quoted helper
    path. Connect is idempotent and replaces a stale Rafu entry (an older
    spool path). Disconnect removes only Rafu's entries, keeps other hooks in
    a shared entry, and drops an event key or `hooks` only when it becomes
    empty. Keys are written sorted (JSONSerialization), array order is kept.
    Claude Code's opt-in answer entry (command ends in ` --answer`, timeout
    300) is a separate scope: the activity Connect and "connected" test ignore
    it, the activity Disconnect removes it too, and its own Connect and
    Disconnect touch only it. See
    [`claude-permission-request-hook.md`](claude-permission-request-hook.md).
14. Refusals, with nothing written: a symbolic-link file or folder, invalid
    JSON or a non-object top level, `hooks` or an event list of another
    shape, a file over 1 MiB, Cursor `version` other than 1, and a file that
    changed between review and confirm (byte comparison).
15. Write: the bundled `Contents/Helpers/rafu-agent-events` is copied to
    `AgentTracking/bin/` (0700) first; then the old file is copied to
    `<name>.rafu-backup-YYYYMMDD-HHMMSS` (0600, unique suffix if needed); then
    the new file is written to a hidden temporary file and `rename(2)`d over
    the old one, keeping its permission bits. `rename` also lets a running
    helper keep its old inode.
15a. Refresh of the installed helper (2026-11-22). The helper holds RafuCore
    code (`AgentHookEvent`, `AgentPermissionRequestSummary`, `AgentHookSpool`,
    `AgentAnswerChannel`), so an old copy behaves like an old app. Connect was
    the only copy, so an app update left the old helper in place. Now
    `AgentHookInstaller.refreshHelper` replaces it:
    - Triggers: at launch, after `AgentActivityStore.shared.start()`, and only
      when a provider is recorded as connected
      (`AgentHookSetupModel.refreshHelperAtLaunch`); and at the end of the
      Settings ▸ Agents status read (`refresh()`), which does not use that
      gate, so a stale recorded state is repaired there.
    - Only when a provider file refers to this variant's helper:
      `AgentHookConfiguration.referencesHelper` is true when any hook command
      starts with this variant's quoted helper path. It uses the same
      traversal as `hasRafuEntries` and covers Cursor. It does not need every
      event entry, so a future hook event cannot make a connected helper look
      "not connected". With no such file the result is `notConnected` and
      nothing is written or created.
    - Compare, then copy: file size first, then a byte comparison. Not a hash
      and not a version stamp: a Rafu Lightning rebuild keeps the version
      number while the helper bytes change (ad hoc signing), so a stamp can
      disagree with the real file. A missing installed helper is copied too.
    - The copy is `stageHelper`: 0700, symbolic-link refusal, hidden
      temporary file, atomic `rename`. A running helper keeps its old inode.
    - Results: `notConnected`, `bundledHelperMissing` (raw `swift run` or a
      test; a quiet skip), `current`, `updated`.
    - It never writes a provider file and never touches the other app
      variant's helper. The rule that provider files change only after review
      (rule 11) is unchanged, so no new decision record was needed.
    - Failure: one log line with the result name only, one fixed sentence in
      Settings, no alert. No message on success.
    - Cost: a Lightning rebuild changes the helper bytes, so the next launch
      copies about 6 MB once. A downgrade puts the older helper back on
      purpose: the helper must match the app that reads the spool.
    - Evidence: on 2026-11-22 a Claude Code `mcp__` request showed "Answer in
      the terminal" in Up next instead of a card in the approval peek. The
      installed helper dated 2026-11-21 was older than the MCP summaries, so
      in `--answer` mode it exited without spooling. Release users updating
      from 0.1.24 to 0.1.25-beta had the same fault.
    - Diagnostic: `cmp` the installed helper against the bundled one:
      `cmp "$HOME/Library/Application Support/<App>/AgentTracking/bin/rafu-agent-events" "<App>.app/Contents/Helpers/rafu-agent-events"`.
      No output means the same bytes.

### System Now Playing (MediaRemote adapter)

16. The user chose (round 2) to use the private MediaRemote framework the way
    Cider does: the BSD-3 `ungive/mediaremote-adapter` at commit `73f14ab`,
    vendored through Cider in `Vendor/MediaRemoteAdapter` with its `LICENSE`.
    `/usr/bin/perl mediaremote-adapter.pl <framework> stream --no-diff --debounce=150 --no-artwork`
    streams one JSON line per change; `send 2|4|5` is play/pause, next,
    previous. Every process gets an argument array.
17. `script/build_media_helper.sh <out>` compiles the framework with
    `xcrun clang` and ad-hoc signs it. When `xcrun clang` is missing or the
    compile fails it prints one line and exits 1; `build_and_run.sh` then
    skips staging and the app build continues. Staged files:
    framework and `rafu-agent-events` in `Contents/Helpers`;
    `mediaremote-adapter.pl` and `MediaRemoteAdapter-LICENSE` in
    `Contents/Resources`. Nested code is signed before the bundle.
    `Helpers` is a nested-code location: placing the plain licence there
    caused `codesign --deep` to reject the app with “code object is not signed
    at all.” The canonical launcher now fails on that error for structured
    SwiftPM resource bundles and checks the completed signature. The existing
    flat SwiftPM bundle compatibility exception remains explicit.
18. `NotchSystemMediaBridge`: generation token per stream (output and exits
    of a stopped stream are inert), bounded line buffer (256 KiB per line; a
    longer line is dropped and the buffer resynchronises at the next
    newline), stderr to `/dev/null`, command processes ended after 5 s.
    Pipe and exit handlers are built in a `nonisolated` static function and
    hop to the main queue, so they are never main-actor-inferred.
19. `NotchNowPlaying` uses system media when Settings ▸ General ▸ Notch ▸
    "Now Playing: read what any app plays" is on (default on, key
    `notchNowPlayingSystemMedia`) and the adapter files are in the bundle.
    When the adapter process ends it falls back to the Music/Spotify public
    path for the rest of the run; `stop()` resets that.

## Why it matters

- A hook that blocks or prints can change what an agent does. The 1 s alarm,
  silent exit 0, and bounded stdin keep the observer passive.
- Hook configuration files belong to the person. A merge that reorders,
  drops, or rewrites other hooks, or that writes without review, breaks
  trust; the backup and the byte comparison make Connect reversible and safe
  against concurrent edits.
- Under `RafuApp`'s default `MainActor` isolation, a closure written inside
  a main-actor method and handed to `DispatchSource` or `Process` can be
  inferred main-actor-isolated and trap when Foundation calls it on its own
  queue (see [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md)
  and [`concurrency.md`](concurrency.md)). Build such handlers in a
  `nonisolated` context.
- `URL.resolvingSymlinksInPath()` cannot be the symlink check: on macOS it
  strips `/private` only when the result exists, so a not-yet-created folder
  under `/var/folders` (every test temporary directory) looks like a link.
  Rafu checks the specific file and folders with `attributesOfItem` (which
  does not follow the final link) instead.
- MediaRemote is private API: a macOS update can break it. The fallback and
  the Settings switch keep Now Playing working.

## Reproduction or evidence

- Scratch package (session scratchpad) with `RafuCore/AgentTracking`, the
  helper target, and the Foundation-only app files plus small Linux
  stand-ins for `TerminalSessionStatus`, `ConductorCLIID`,
  `WorkspaceTerminalController`, `DispatchSourceFileSystemObject`, and the
  AppKit types `NotchNowPlaying` uses: `swift test` passed 57 tests in 10
  suites (the new RafuCore suites, `AgentActivityStoreTests`,
  `NotchSystemMediaTests`, and the existing `NotchNowPlayingTests`).
- The helper binary, run with sample payloads: one 0600 file in a 0700
  spool for a valid `Stop`; nothing for an unknown event, invalid JSON, a
  spool path of the wrong shape, an unknown provider, or a 2 MB stdin; exit
  0 every time; the prompt text was not in the file.

## Verification

```bash
swiftc -parse -swift-version 6 <changed .swift files>
swift-format lint --strict <changed .swift files>
bash -n script/build_and_run.sh script/build_media_helper.sh
swift test --filter "Agent hook|Agent session|Agent terminal|Agent activity|Agent tracked|Notch system media"
./script/build_and_run.sh --verify   # macOS: stages Contents/Helpers
ls "dist/Rafu Lightning.app/Contents/Helpers"
```

Manual (macOS): Settings ▸ Agents ▸ Activity tracking ▸ Connect Claude Code;
check the sheet path and entries; confirm; check the `.rafu-backup-*` file;
start `claude` in a Rafu terminal and in another terminal app; check the
notch, the titlebar, and an Ensemble terminal node header; Disconnect and
diff the file against the backup.

## Related code, ADRs, and phases

- `Sources/RafuAgentEventHelper/main.swift`, `AgentEventHelper.swift`,
  `ProcessAncestry.swift`
- `Sources/RafuCore/AgentTracking/AgentHookEvent.swift`, `AgentHookSpool.swift`,
  `TrackedAgentSession.swift`, `AgentTerminalMatcher.swift`,
  `AgentHookConfiguration.swift`, `AgentHookInstaller.swift`
- `Sources/RafuApp/AgentTracking/AgentActivityStore.swift`,
  `AgentTrackingPresentation.swift`, `AgentHookSetupModel.swift`,
  `AgentTrackingSettingsSection.swift`, `TrackedAgentsNotchView.swift`
- `Sources/RafuApp/Notch/NotchNowPlaying.swift`,
  `NotchNowPlayingSystemMedia.swift`, `NotchSettingsSection.swift`
- Reference implementation: Cider `Sources/CiderEventHelper`,
  `CiderDomain/AgentTracking.swift`, `CiderData/AgentHookSetup.swift`,
  `CiderPlatform/Media/SystemMediaBridge.swift`, `script/build_media_helper.sh`
- Phase: [`ensemble-canvas.md`](../plans/phases/ensemble-canvas.md),
  Addendum 2, workstream X11
- [`notch-companion.md`](notch-companion.md),
  [`linux-swift-verification.md`](linux-swift-verification.md)

## Agent card status vocabulary (2026-10-19)

The seven published states, their precedence, and every refusal (no cost, no
sub-agent count, no tab badge, no persisted read/unread, Failed never from an
exit code) are the decision in
[ADR 0029](../decisions/0029-agent-status-vocabulary.md). The engineering
facts worth repeating here:

- **Stopped is derivable only because the runtime kind survives exit.**
  `TerminalPaneSnapshot.runtimeKind` (`.directAgentTerminal`) is carried
  through the live → exited transition by `TerminalGroupRuntime.withStatus`.
  Without that, an exited pane would be indistinguishable from a shell pane
  and no card could say Stopped. Do not drop `runtimeKind` when rebuilding a
  snapshot for an exited pane.
- **No new ticker was added.** `AgentActivityStore.now` already ticks every
  30 s while sessions exist; elapsed-time and the 30-minute `inactive`
  threshold both read it. Adding a faster timer for smoother elapsed text
  would be new idle work.
- **Marking read is funnel-based.** `WorkspaceTerminalController.clearAttention()`
  calls `AgentActivityStore.markReplyRead`, which is why every focus path is
  covered by one call site. The one gap it cannot cover — a reply arriving on
  an already-focused card — is handled by an `onChange`.
- **`AgentTrackedPhase.stateWord` now delegates to `AgentCardStatus.word`**
  and is no longer used by Canvas. Treat it as the legacy spelling of the same
  vocabulary; change both or neither.
- Reduce Motion replaces the working spinner with a static three-quarter arc;
  elapsed text is dropped when `card.rect.width × scale < 260`.

Verified on `main` at ba00643 (Apple Swift 6.4 (swiftlang-6.4.0.34.1),
macOS 27.0.1 (26A434)), commit 9c6c095 (merge a257e8d): format lint clean;
build with 0 warnings; parallel suite 250 + 2631 tests passed;
`--no-parallel` (CI mode) 250 + 2631 passed; `./script/build_and_run.sh
--verify` launched Rafu Lightning. No person has checked the pills, the
spinner, or the board summary bar on screen yet.
