# ADR 0048: Meeting capture and on-device speech

- **Status:** Proposed (2026-11-22). Capture behaviour is not measured; see the note about meeting audio capture
  (`docs/references/meeting-audio-capture.md`, to come).
- **Date:** 2026-11-22
- **Related:** the decision about a meeting agent with no visible terminal
  ([`0046-meeting-agent-without-visible-terminal.md`](0046-meeting-agent-without-visible-terminal.md)), the decision
  about Meetings scope, app-data storage and agent access
  ([`0047-meetings-scope-app-data-storage-and-agent-access.md`](0047-meetings-scope-app-data-storage-and-agent-access.md)),
  the Meetings phase ([`meetings.md`](../plans/phases/meetings.md)).

## Context

Rafu must record a call and write a transcript on the Mac, with no cloud speech service. It needs the user's own
voice and the other people's voices as separate sources, and it needs to tell speakers apart.

A speech spike measured the candidates. Results:

- **Apple speech:** 4.67 to 5.06 percent word error on three synthetic sets, 106 to 130 times real time, no model
  download.
- **SpeakerKit** (argmax-oss-swift 1.1.1): 926 MB peak memory on a file of 1526 s. On the one real meeting with four
  people it had 35 percent speaker error and found 5 speakers.
- **Nemotron:** it failed the word-error rule (6.60 percent on the 3-speaker set) and the speaker-count rule on the
  5-speaker set.
- **WhisperKit:** cold load of 57.5 to 79.7 s.

The Mac used for the spike runs macOS 27.2.1 (Xcode 27.2, Swift 6.4.2). It has no Mac on macOS 26 or 15, and no
code-signing identity (ad-hoc signing only). The package minimum is macOS 15.

## Decision

1. **Two tracks.** The microphone is "Me". The audio of the call app is "Them".
2. **Platform.** Meetings needs macOS 26. The package minimum stays macOS 15. On macOS 15 Meetings is not available.
3. **Text engine.** Apple speech.
4. **Speaker engine.** SpeakerKit, in a helper process, after Stop.
5. **Nemotron later.** It may come as a user choice in a later stage.
6. **English only** in version 1.
7. **Permission check at each meeting start.** If a permission is missing, Rafu shows a clear message. It never
   records silently with an empty track.
8. **Labels stay "Speaker 1", "Speaker 2", "Speaker 3"** until the user names them.

## Alternatives considered

- **Nemotron as the default.** Rejected. Two measured failures (word error and speaker count).
- **WhisperKit as a default download.** Rejected. The cold load is 57.5 to 79.7 s, and version 1 has no table of
  model sizes.
- **One mixed track.** Rejected. It loses the difference between "Me" and "Them".
- **A separate capture path for macOS 15.** Rejected. The user chose one path.

## Consequences

- SpeakerKit error is high (35 percent on the one real meeting). The labels are a help, not a fact. The user can
  rename them.
- SpeakerKit memory grows with the length of the audio. A length limit may be needed.
- Permissions may be lost after an update with an ad-hoc signature. This is inferred, not measured. The capture
  check measures it.
- The speaker work runs in a helper process, so a memory peak does not stop the app.

## Revisit trigger

A better measured speaker result. A Nemotron release or licence answer. A Mac on macOS 26 that shows different
capture behaviour. A wish for a language other than English.

## Open

Nothing here is decided.

- SpeakerKit memory at 2 hours.
- Live text on two streams.
- Permission behaviour after a rebuild.
- Behaviour on macOS 26. It is not measurable on the Mac used for the spike.
- The NVIDIA model licence answer for the later Nemotron option.

## Related paths

- `docs/references/meeting-audio-capture.md` (to come, from the check)
- `Sources/RafuCore/Meetings/`, `Sources/RafuApp/Meetings/` (planned)
- A helper executable for SpeakerKit (planned; its target needs a change of `Package.swift` in the shared contracts
  package)
