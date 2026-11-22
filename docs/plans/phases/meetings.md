# Meetings

- **Status:** Version 1 implemented on 2026-11-23 (shared contracts, wave 1, wave 2 and integration are merged on
  `main`; both test modes were green; the launch was verified). The hand checks for the user and the "fix soon" list
  are in "Status log" below. The three decision records are accepted. Session 1 of the capture check is done (see the
  note about meeting audio capture). The Codex standard-input re-check is done and passed (see the note about hidden
  meeting agent limits).
- **Depends on:** the three decision records listed below; the checks in the first stage.
- **Gate:** the proof stage at the end of this document.

Meetings is an app-level feature that is not tied to a workspace. Rafu records a call on two tracks, writes the
transcript on the Mac, and keeps the meeting in its app data. The user can read it, rename speakers, export it as
Markdown and ask questions about it.

This document stands alone. It does not link to scratch files.

## User decisions

Decisions of the user on 2026-11-21:

- Speakers ("Speaker 1, 2, 3") are in version 1.
- Version 1 is English only. If another language is only a model swap, a later version offers a model and language choice in Settings.
- Meetings needs macOS 26 or later (one capture path).
- There is no Developer ID yet (ad-hoc signature). Rafu checks the microphone and audio-capture permission at the start of each meeting, shows a clear message, and never records silently to an empty file.
- Turns come from the Me and Them tracks, the speaker labels, and a speaker change or a pause of about 1 second or more.

Decisions of the user on 2026-11-22:

1. The Meetings question box and the speaker-name suggestions may run an agent with no visible terminal. The limit is
   the files of one meeting, read-only. This is an exception to "processes start only in visible terminals" and to
   "Rafu embeds no agent".
2. The HUD shows only while a recording runs. An idle start comes from the menu bar item, the island or notch card,
   the Welcome view and Command-Shift-M.
3. Agent access to meetings is one Settings switch, "Allow agents to read your meetings", off by default. The user
   can turn it on or off. The Rafu skill (the agent-facing skill that ships with Rafu's MCP tools) lets any agent
   check whether it has access. If it has none, the agent says so plainly when it is asked to do something from a
   meeting.
4. Export format: Markdown.
5. Ask box, version 1: Claude Code and Codex. Later: OpenAI with the user's API key, and Anthropic with the user's API
   key.
6. No questions during a live meeting in version 1.
7. The standalone Meetings window shows one meeting at a time, with no tabs. While a meeting is processing, the user
   can move on and start a new recording.
8. A recording belongs to the app. If a folder opens during a recording, the meeting is not tied to that folder.
9. Command-Shift-M opens Meetings. Record on the Welcome view opens the Meetings window.
10. Speech engines, version 1: Apple speech and SpeakerKit. Nemotron comes later, as a user choice. **Replaced on
    2026-11-23: see "Decisions of the user on 2026-11-23".**
11. Who builds it: Opus at medium effort for work across several parts of the app, Sonnet at high effort for smaller
    groups.
12. English only. Meetings needs macOS 26. The package minimum stays macOS 15.

Decisions of the user on 2026-11-23:

1. **Three text engines in version 1.** Nemotron English (the default, through FluidAudio), Apple speech, and
   WhisperKit large-v3 (final text only; no live path unless a spike shows one). The user selects in Settings ▸
   Meetings. Until the Nemotron model is installed, Rafu uses Apple speech. The reason is a bench on the user's own
   voice: words wrong 34.4% for Apple speech and 21.1% for Nemotron 1120 ms.
2. **Codex is offered in the ask box in version 1.** The design is the meeting text on standard input in an empty
   folder (see the decision about a meeting agent with no visible terminal).
3. **Meeting diagnostics in version 1.** A diagnostics log for each meeting, and an export action. The user tests on
   another Mac and sends the logs back.
4. **Build to completion.** The user asked to build the rest of the note-taker, and to have the advisor answer each
   open decision as the user would.

Answers by the advisor for the user on 2026-11-23. Each one is decided by the advisor for the user, to be confirmed.
The user can change it. Each has a safe default in place.

- **Speaker engines.** Two: Nemotron 3 `fast32` (the default) and SpeakerKit. The user selects in Settings ▸
  Meetings. Nemotron 3 is better for a call with 2 to 5 far speakers and uses about half the memory.
  SpeakerKit is better for a call with 8 speakers. The Nemotron 3 result on the one real meeting is probably
  optimistic.
- **Live preview with WhisperKit.** The live preview comes from Nemotron when its model is installed, else from Apple
  speech. The live view names the engine.
- **The NVIDIA Open Model License** is accepted for a download that the user starts in Settings.
- **Codex design.** The meeting text on standard input, empty private folder, shell tool off, strict permission
  profile, no user configuration, no network. The Codex choice is active only after a re-check passes.
- **Terminals with the Rafu tools.** Ensemble terminals only, as today.
- **Summary.** None at Stop. A local overview with no AI, and a "Summarize" chip that is a normal question.
- **No switch for each meeting in Share.** The Settings switch only, and a status line in Share.
- **"Open Folder..."** opens a workspace window beside the Meetings window.
- **Retention.** Transcripts until the user deletes them. Audio: "Until I delete" (default), 30 days or 7 days.
- **Command-Shift-M** is a menu command, active only when Rafu is in front.
- **Meetings on macOS 15.** The entry points show, are not active, and say "Meetings needs macOS 26".
- **Echo on the Mac speakers.** No voice processing. An echo mark in the text; echo lines are hidden by default and
  never deleted.
- **Microphone.** Settings ▸ Meetings ▸ "Microphone": Automatic (default), System default, or a named device.
  Automatic uses the built-in microphone when the default input is a Bluetooth device.
- **"Them"** is all sound that the Mac plays, except Rafu's own, in version 1.
- **Live Nemotron text** comes from the helper with a footprint limit of 1.0 GB and a restart at a chunk boundary.
- **Speaker labels with no speaker model.** "Them", with an offer to download a speaker model.
- **Capture check sessions 2 and 3 do not block.** They are hand checks (see "Gates and user hand checks").

## Scope

In version 1:

- Two-track recording (microphone and call audio), with a recording HUD.
- Transcript on the Mac with Nemotron, Apple speech or WhisperKit (the user selects), speaker labels with Nemotron 3 or
  SpeakerKit after Stop, user-confirmed speaker names. The downloaded engines run in one helper process.
- A diagnostics log for each meeting, with a user action that exports it. It holds no transcript text.
- A meeting library in the app data, with Markdown export on a user action.
- A standalone Meetings window, a Welcome view entry, a workspace editor tab and an activity strip entry (see the
  work packages).
- The agent access switch, the meeting tools for agents, and the Rafu skill text.
- Questions about one stopped meeting, and speaker-name suggestions, through the hidden meeting agent.

Not in version 1:

- Questions during a live meeting.
- Agents that use an API key (OpenAI, Anthropic).
- Live text with WhisperKit, a vocabulary feature and the Nemotron 560 ms tier (no measured gain).
- A tap for one call app (version 1 taps all sound that the Mac plays).
- Languages other than English.
- Any export format other than Markdown.
- A macOS 15 capture path.

## Decision records

- The decision about a meeting agent with no visible terminal
  ([`0046`](../../decisions/0046-meeting-agent-without-visible-terminal.md)). Accepted in principle, amended
  2026-11-23 (Codex is offered with a different limit). It is the only exception to the visible-terminal rule.
- The decision about Meetings scope, app-data storage and agent access
  ([`0047`](../../decisions/0047-meetings-scope-app-data-storage-and-agent-access.md)). Accepted (2026-11-23).
- The decision about meeting capture and on-device speech
  ([`0048`](../../decisions/0048-meeting-capture-and-on-device-speech.md)). Accepted (2026-11-23), amended
  2026-11-23.

## Stages and work packages

Folder convention: `Sources/RafuCore/Meetings/<Area>/` for pure domain code, `Sources/RafuApp/Meetings/<Area>/` for
presentation, and mirrored test folders under `Tests/`. Exact paths are fixed per package in the contracts package,
before any fan-out (see `docs/plans/phases/README.md`, "Source-path mapping and ownership lock").

1. **Decide and check first.**
   - The three decision records (this change).
   - Call audio and live speech check: capture of the call app audio and the microphone on a machine that runs
     macOS 26; permission behaviour; the result goes into a reference note about meeting audio capture.
   - Hidden meeting agent limits check: for Claude Code and Codex, the exact argument arrays that give read-only
     access to one folder, and a test per CLI version; the result goes into a reference note about hidden meeting
     agent limits. Done on 2026-11-22.
   - Codex standard-input limits re-check: a result for the Codex design (the meeting text on standard input, an
     empty private folder, shell tool off). It is a new section of the note about hidden meeting agent limits. Done
     on 2026-11-23 (passed).
2. **Shared contracts and wiring points.** One package. It lands the shared models (meeting, track, turn, speaker),
   the engine protocols and ids for text and speakers, the speech preferences, the store interface, the access
   switch interface, the settings key, the diagnostics contract with a no-op recorder, the menu and command entries
   (including "Export Meeting Diagnostics..."), the helper target `RafuMeetingsWorker` with a stub, and any change to
   `Package.swift`. After this package, no other package edits shared files.
3. **Wave 1** (six file-disjoint packages that run in parallel):
   - Meeting library in app data, with Markdown export.
   - Turns, speaker labels, echo marks and name mapping logic.
   - Two-track capture, recorder and crash-safe audio.
   - Apple speech engine, model catalog and downloads.
   - Speech worker: Nemotron text, WhisperKit text, Nemotron 3 speakers and SpeakerKit, in the helper process.
   - Meeting diagnostics log and export.
4. **Wave 2** (file-disjoint packages that run in parallel):
   - Settings ▸ Meetings (access switch, engine pickers, microphone, audio retention, diagnostics export, first-use
     download sheet), agent tools and the Rafu skill text.
   - Meetings window, Welcome view card, workspace editor tab and activity strip entry.
   - Status surfaces (menu bar item, island or notch card, recording HUD).
   - Questions and name suggestions through the hidden meeting agent. The Codex runner waits for the Codex
     re-check.
5. **Integration.** The coordinator merges the packages in order: contracts, implementations, composition, and
   measurements last.
6. **Proof.** Privacy tests, the final security review and release evidence (see "Gates").

## Rules for each package

- One package is one agent in one worktree. It owns only the paths named for it.
- Shared files change once, in the contracts package. A later package that needs a shared change stops and reports
  to the coordinator.
- The implementor's final sequence is: `format --fix`, `format --lint`, build, parallel tests, then commit. Nothing
  changes a file after the parallel run.
- The advisor verifies in serial mode (`./script/test.sh --no-parallel`), and also in parallel mode when the change
  touched concurrency.
- The coordinator merges, runs both test modes on `main`, and launches Rafu Lightning.
- In a worktree, delete `.build` as the last step, as `AGENTS.md` requires.

## Gates and user hand checks

- Each package: build, focused tests and the full parallel run green on its worktree.
- After merge: both test modes green on `main` with the test counts recorded.
- User hand checks on Rafu Lightning: a real call recorded with both tracks; the permission message when a
  permission is missing; stop and process, and a second recording started during processing; speaker rename; Markdown
  export; the access switch off and on with an agent in an Ensemble terminal; the hidden agent answer and its Cancel
  control; quit during a run ends the process.
- User hand checks that an agent cannot do (each one has a safe default in place, and none blocks the build):
  1. Capture check session 2: one real call in each of Zoom, Teams, Google Meet in Chrome and FaceTime. Is the far
     voice in "Them"? Does a device change during the call keep both tracks?
  2. Capture check session 3: two rebuilds with one changed string. Does macOS ask again for the microphone and for
     system audio? (Session 1: rebuild 1 kept the grants, rebuild 2 asked again.)
  3. AirPods for output with the Mac microphone as input (the Automatic rule): does macOS keep the AirPods output in
     high quality during a real call, and is the "Me" text good?
  4. One real meeting from Record to an exported Markdown file, one time with each text engine.
  5. VoiceOver and Full Keyboard Access in the Meetings window; the status surfaces on an island Mac, a notch Mac and
     an external display.
  6. On the other Mac: after each test call, "Export Meeting Diagnostics..." and send the bundle back.
  7. If the Codex re-check fails: may Codex run with a sandboxed shell in an empty folder? The safe default is no;
     Codex then shows "not available".
- Not claimed until measured: behaviour on macOS 26 (the development machine runs macOS 27.2.1; no Mac on macOS 26 or
  15 is available there), the permission rule after an ad-hoc signed rebuild (the machine has no code-signing
  identity), and helper memory at 2 hours of audio for each of the four models.

## Security review points

- Hidden agent limits, for each CLI. Claude Code: read-only, one meeting only, no write, no shell, no web, no MCP
  tools. Codex: the meeting text on standard input, an empty private folder, shell tool off, strict profile, no user
  configuration, no network. The allow-listed environment; the argument array built in one place. No private text in
  process arguments.
- The speech helper is not a second agent. It reads audio and model files that the app names, writes results to
  standard output only, and has no network use. The app downloads models only on a user action, with a pinned
  revision and a SHA-256 for each file.
- No Rafu-held credential reaches the hidden agent or any Ensemble agent.
- Agent tools take meeting ids, never paths.
- The access switch is checked on every tool call, in the app.
- No transcript text, speaker name, title, question, answer or audio path in logs, in the diagnostics files or in the
  diagnostics export. The export leaves the Mac only through a save panel.
- App data is never shown in workspace files, Git changes, search results, Quick Open or restoration data.
- Export runs only on a user action.
- Permission checks at each meeting start; no silent empty recording.
- Crash-safe audio: a crash during a recording keeps the audio written so far.
- Process cleanup on quit: the hidden agent and the speech helper end when the app quits.

## Status log

**2026-11-23: version 1 implemented.** The shared contracts, wave 1, wave 2 and the integration are merged. Both test
modes (parallel and `--no-parallel`) were green on the merged tree, and the launch was verified. The handoff did not
give the test counts of the two runs. New nuances are in
[`repository-policy-tests.md`](../../references/repository-policy-tests.md),
[`meeting-audio-capture.md`](../../references/meeting-audio-capture.md),
[`meeting-speech-worker.md`](../../references/meeting-speech-worker.md) and
[`meeting-hidden-agent-limits.md`](../../references/meeting-hidden-agent-limits.md). One consequence was added to the
decision about Meetings scope and agent access
([`0047`](../../decisions/0047-meetings-scope-app-data-storage-and-agent-access.md)).

Left as hand checks for the user (no agent can do them):

- Real calls in Zoom, Teams, Google Meet and FaceTime.
- The permission prompts after a rebuild.
- AirPods for output with the Mac microphone as input.
- One real question with each CLI (Claude Code and Codex) from the app.
- VoiceOver and keyboard use in the Meetings window.
- How the Settings ▸ Meetings pane looks.

"Fix soon" list from the security review of 2026-11-23 (none of these blocks version 1):

1. The hidden agent is signalled as one process. Signal its process group, so child processes end too.
2. Open the journal, diagnostics and hidden agent writers with `O_NOFOLLOW`, and check the owner and the mode in
   `MeetingFileIO`.
3. Run the `init` check of the Claude Code stream also on `skills`, `slash_commands` and `plugins`.
4. Give the speech helper a sandbox profile with no network.
5. Show the SpeakerKit warning for a meeting longer than 2.5 hours (the limit is in the note about the speech
   worker).
6. The live diagnostics events have no meeting id.

## Open questions

The questions of 2026-11-22 are closed: the user or the advisor answered them (see the decisions above and the three
decision records). Only what is not measured is open. The owner closes each one in a reference note.

| Question | Closes it |
|---|---|
| The result of the Codex standard-input re-check | Closed 2026-11-23: passed (the re-check section of the note about hidden meeting agent limits) |
| Behaviour on macOS 26 | A Mac on macOS 26 (not available on the development machine) |
| The permission rule after a rebuild (rebuild 1 kept the grants, rebuild 2 asked again) | Capture check session 3 (hand check) |
| Real calls in each call app, and a device change during a call | Capture check session 2 (hand check) |
| AirPods output quality with the Mac microphone as input | Hand check 3 above |
| Helper memory at 2 hours, for each of the four models (Nemotron text, WhisperKit, Nemotron 3, SpeakerKit); Nemotron live text at 2 hours | The note about the speech worker |
| Whether the minimum macOS of FluidAudio and `argmax-oss-swift` is above macOS 15 | The shared contracts package (it checks first and stops with a report) |

## Required references

The note about meeting audio capture exists: [`docs/references/meeting-audio-capture.md`](../../references/meeting-audio-capture.md)
(session 1 measured; the rows for real calls and the rebuild rule are "not measured"). The note about hidden meeting
agent limits exists: [`docs/references/meeting-hidden-agent-limits.md`](../../references/meeting-hidden-agent-limits.md)
(checked 2026-11-22; the Codex standard-input re-check of 2026-11-23 and the findings of the build are in it).

Notes that exist: [`meeting-diagnostics.md`](../../references/meeting-diagnostics.md) (the diagnostics events, files,
export and the privacy tests), [`meeting-speech-worker.md`](../../references/meeting-speech-worker.md) (the helper,
its modes, the wire types, the memory numbers) and
[`repository-policy-tests.md`](../../references/repository-policy-tests.md) (source rules that a test enforces, and the
duplicate type name check after a merge).

Speech spike results (summary of the measurements; the full results file is not tracked in the repository):

- Apple speech: 4.67 to 5.06 percent word error on three synthetic sets, 106 to 130 times real time, no model
  download.
- SpeakerKit (argmax-oss-swift 1.1.1): 926 MB peak memory on a file of 1526 s; on the one real meeting with four
  people, 35 percent speaker error and 5 speakers found.
- Nemotron: failed the word-error rule (6.60 percent on the 3-speaker set) and the speaker-count rule on the
  5-speaker set.
- WhisperKit: cold load of 57.5 to 79.7 s.

Machine for the spike: macOS 27.2.1, Xcode 27.2, Swift 6.4.2; no code-signing identity (ad-hoc signing only).

Engine bench of 2026-11-23 on the user's recordings (branch `spike/meeting-speech-bench`, commit `fb95bba`; not
merged). Words wrong, Mac microphone: Apple 34.4%, Nemotron 1120 ms 21.1%, Nemotron 560 ms 23.3%, WhisperKit 23.3%.
AirPods call-mode microphone: Apple 71%, Nemotron 1120 ms 81%, Nemotron 560 ms 92%, WhisperKit 73%. The full table is
in the decision about meeting capture and on-device speech.

## Later work

- Agents that use the user's API key (OpenAI, Anthropic), with their own decision about the key and the text sent.
- A tap for one call app, by bundle id.
- Audio compaction after processing.
- Live text with WhisperKit; a vocabulary feature; the Nemotron 560 ms tier (no measured gain).
- Questions during a live meeting.
- Other languages and other export formats.
- A macOS 15 capture path, if the user asks for it.
