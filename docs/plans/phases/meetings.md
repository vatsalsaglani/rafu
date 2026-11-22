# Meetings

- **Status:** Planned (2026-11-22). The first stage, "decide and check first", is open. No Meetings code exists yet.
- **Depends on:** the three decision records listed below; the two checks in the first stage.
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
10. Speech engines, version 1: Apple speech and SpeakerKit. Nemotron comes later, as a user choice.
11. Who builds it: Opus at medium effort for work across several parts of the app, Sonnet at high effort for smaller
    groups.
12. English only. Meetings needs macOS 26. The package minimum stays macOS 15.

## Scope

In version 1:

- Two-track recording (microphone and call audio), with a recording HUD.
- Transcript on the Mac with Apple speech, speaker labels with SpeakerKit after Stop, user-confirmed speaker names.
- A meeting library in the app data, with Markdown export on a user action.
- A standalone Meetings window, a Welcome view entry, a workspace editor tab and an activity strip entry (see the
  work packages).
- The agent access switch, the meeting tools for agents, and the Rafu skill text.
- Questions about one stopped meeting, and speaker-name suggestions, through the hidden meeting agent.

Not in version 1:

- Questions during a live meeting.
- Agents that use an API key (OpenAI, Anthropic).
- Nemotron.
- Languages other than English.
- Any export format other than Markdown.
- A macOS 15 capture path.

## Decision records

- The decision about a meeting agent with no visible terminal
  ([`0046`](../../decisions/0046-meeting-agent-without-visible-terminal.md)). Accepted in principle. It is the only
  exception to the visible-terminal rule.
- The decision about Meetings scope, app-data storage and agent access
  ([`0047`](../../decisions/0047-meetings-scope-app-data-storage-and-agent-access.md)). Proposed.
- The decision about meeting capture and on-device speech
  ([`0048`](../../decisions/0048-meeting-capture-and-on-device-speech.md)). Proposed.

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
     agent limits.
2. **Shared contracts and wiring points.** One package. It lands the shared models (meeting, track, turn, speaker),
   the store interface, the access switch interface, the settings key, the menu and command entries, and any change
   to `Package.swift`. After this package, no other package edits shared files.
3. **Wave 1** (file-disjoint packages that run in parallel):
   - Meeting library and Markdown export.
   - Turns and speaker names.
   - Two-track capture.
   - Apple speech and the SpeakerKit helper.
4. **Wave 2** (file-disjoint packages that run in parallel):
   - Agent access switch, agent tools and the Rafu skill text.
   - Meetings window, Welcome view card, workspace editor tab and activity strip entry.
   - Status surfaces (menu bar item, island or notch card, recording HUD).
   - Questions and name suggestions through the hidden meeting agent.
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
- Not claimed until measured: behaviour on macOS 26 (the development machine runs macOS 27.2.1; no Mac on macOS 26 or
  15 is available there), permission behaviour after an ad-hoc signed rebuild (the machine has no code-signing
  identity), and memory at 2 hours of audio.

## Security review points

- Hidden agent limits: read-only, one meeting only, no write, no shell, no web, no MCP tools; the allow-listed
  environment; the argument array built in one place.
- No Rafu-held credential reaches the hidden agent or any Ensemble agent.
- Agent tools take meeting ids, never paths.
- The access switch is checked on every tool call, in the app.
- No transcript text, speaker name or audio path in logs.
- App data is never shown in workspace files, Git changes, search results, Quick Open or restoration data.
- Export runs only on a user action.
- Permission checks at each meeting start; no silent empty recording.
- Crash-safe audio: a crash during a recording keeps the audio written so far.
- Process cleanup on quit: the hidden agent and the SpeakerKit helper end when the app quits.

## Open questions

Each one is open and is not decided. The owner closes it, in a decision record or a reference note.

| Question | Closes it |
|---|---|
| Who writes the summary, and when (an automatic send at Stop is against "keep AI explicit") | The user, then the record about the meeting agent |
| The exact argument arrays for the hidden agent; whether a stricter "no tools, text on standard input" run is the default | The hidden meeting agent limits check |
| A per-meeting "Let agents read this meeting" switch, or the Settings switch only | The user, then the record about Meetings scope |
| "Open Folder..." in the Meetings window: new window, or the same window | The user |
| How long to keep audio and transcripts | The user |
| Command-Shift-M from the menu only, or system-wide | The user |
| Meetings on macOS 15: "Needs macOS 26" message, or hidden | The user |
| Which Rafu terminals get the Rafu tools for meetings | The user, then the record about Meetings scope |
| SpeakerKit memory at 2 hours | The call audio and live speech check |
| Live text on two streams | The call audio and live speech check |
| Permission behaviour after a rebuild | The call audio and live speech check |
| Behaviour on macOS 26 | A Mac on macOS 26 (not available on the development machine) |
| The NVIDIA model licence answer for the later Nemotron option | The user, before Nemotron work starts |

## Required references

Notes to come (the first stage creates them):

- `docs/references/meeting-audio-capture.md`: capture of call audio and microphone, permissions, live speech.
- `docs/references/meeting-hidden-agent-limits.md`: the argument arrays and the limit test per CLI version.

Speech spike results (summary of the measurements; the full results file is not tracked in the repository):

- Apple speech: 4.67 to 5.06 percent word error on three synthetic sets, 106 to 130 times real time, no model
  download.
- SpeakerKit (argmax-oss-swift 1.1.1): 926 MB peak memory on a file of 1526 s; on the one real meeting with four
  people, 35 percent speaker error and 5 speakers found.
- Nemotron: failed the word-error rule (6.60 percent on the 3-speaker set) and the speaker-count rule on the
  5-speaker set.
- WhisperKit: cold load of 57.5 to 79.7 s.

Machine for the spike: macOS 27.2.1, Xcode 27.2, Swift 6.4.2; no code-signing identity (ad-hoc signing only).

## Later work

- Agents that use the user's API key (OpenAI, Anthropic), with their own decision about the key and the text sent.
- Nemotron as a user choice, after the licence answer and a better measured result.
- Questions during a live meeting.
- Other languages and other export formats.
- A macOS 15 capture path, if the user asks for it.
