# ADR 0048: Meeting capture and on-device speech

- **Status:** Accepted (2026-11-23), amended 2026-11-23 (three times: the speech engines, the "Me" capture method,
  then the echo mark for each word). See "Amendment 2026-11-23", "Amendment 2026-11-23: the capture method of Me"
  and "Amendment 2026-11-23: the echo mark is set for each word". Capture behaviour is measured on
  one Mac only (session 1 of the capture check); see the note about meeting audio capture
  ([`meeting-audio-capture.md`](../references/meeting-audio-capture.md)).
- **Date:** 2026-11-22
- **Related:** the decision about a meeting agent with no visible terminal
  ([`0046-meeting-agent-without-visible-terminal.md`](0046-meeting-agent-without-visible-terminal.md)), the decision
  about Meetings scope, app-data storage and agent access
  ([`0047-meetings-scope-app-data-storage-and-agent-access.md`](0047-meetings-scope-app-data-storage-and-agent-access.md)),
  the Meetings phase ([`meetings.md`](../plans/phases/meetings.md)).

## Context

Rafu must record a call and write a transcript on the Mac, with no cloud speech service. It needs the user's own
voice and the other people's voices as separate sources, and it needs to tell speakers apart.

### History: the speech spike of 2026-11-22

A speech spike measured the candidates on synthetic sets and on one real meeting. These numbers led to the first
version of this record (Apple speech and SpeakerKit only). They stay here as history. The amendment below replaces
the decision that they led to.

- **Apple speech:** 4.67 to 5.06 percent word error on three synthetic sets, 106 to 130 times real time, no model
  download.
- **SpeakerKit** (argmax-oss-swift 1.1.1): 926 MB peak memory on a file of 1526 s. On the one real meeting with four
  people it had 35 percent speaker error and found 5 speakers.
- **Nemotron:** it failed the word-error rule (6.60 percent on the 3-speaker set) and the speaker-count rule on the
  5-speaker set.
- **WhisperKit:** cold load of 57.5 to 79.7 s.

The Mac used for the spike runs macOS 27.2.1 (Xcode 27.2, Swift 6.4.2). It has no Mac on macOS 26 or 15, and no
code-signing identity (ad-hoc signing only). The package minimum is macOS 15.

### Bench of 2026-11-23: the user's own voice

A second bench ran each text engine on the user's own recordings (90 words, one speaker). It is the reason for the
amendment. Source: branch `spike/meeting-speech-bench`, commit `fb95bba`, script
`Spikes/MeetingSpeech/bench/run_bench.sh`. That branch is not merged.

Words wrong, on the user's voice with the Mac microphone:

| Engine | Words wrong |
|---|---|
| Apple speech | 34.4% |
| Nemotron English, 1120 ms tier | 21.1% |
| Nemotron English, 560 ms tier | 23.3% |
| WhisperKit large-v3 | 23.3% (17.6% with numbers made equal) |

- On a clean far-side voice, all engines are within 1 to 2.6 points of each other.
- On the AirPods call-mode microphone, each engine fails: Apple 71%, Nemotron 1120 ms 81%, Nemotron 560 ms 92%,
  WhisperKit 73%. The audio is the limit, not the engine.
- Apple live text is about the same as Apple text made from a file.
- Speed, warm: Apple 90 to 127 times real time, Nemotron 1120 ms 82 to 87, Nemotron 560 ms 47, WhisperKit 15 to 23.
- Load time: Apple 49 ms; Nemotron 7.4 s cold, 0.12 s warm; WhisperKit 58 s cold, 0.8 s warm. A +12 dB gain helps
  only WhisperKit.
- Nemotron was worse on synthetic speech (6.60 percent against 4.67 percent for Apple). The real voice gives the
  opposite result. 21 percent wrong words is still many.

## Decision

This list is the current decision. It already includes the amendment.

1. **Two tracks.** The microphone is "Me", recorded through a Core Audio IO block on the selected input device (see
   "Amendment 2026-11-23: the capture method of Me"). "Them" is all sound that the Mac plays, except Rafu's own. This is the
   global call-audio tap that the capture check measured. A tap for one call app is later work. (The wording "all
   sound that the Mac plays" is decided by the advisor for the user on 2026-11-23, to be confirmed.)
2. **Platform.** Meetings needs macOS 26. The package minimum stays macOS 15. On macOS 15 Meetings is not available:
   the entry points show, are not active, and say "Meetings needs macOS 26". There is no capture, no helper and no
   permission prompt.
3. **Three text engines** (decided by the user on 2026-11-23): Nemotron English 1120 ms through FluidAudio (the
   default), Apple speech, and WhisperKit large-v3 626 MB (final text only). The user selects in Settings ▸
   Meetings. Until the default model is installed, Rafu uses Apple speech.
4. **Two speaker engines:** Nemotron 3 `fast32` (the default) and SpeakerKit. The user selects in Settings ▸
   Meetings. (Decided by the advisor for the user on 2026-11-23, to be confirmed. The user can change it. The reason
   is in the amendment.)
5. **One helper process, `RafuMeetingsWorker`.** It links FluidAudio and `argmax-oss-swift`. The app links neither.
   The text models of Nemotron and WhisperKit, and both speaker engines, run in this helper. Apple speech runs in
   the app, off the main actor.
6. **The app downloads models, only on a user action.** Each file has a pinned revision and a SHA-256. The helper has
   no network use. The licence of the Nemotron text model (NVIDIA Open Model License) is shown before the download.
   (The licence rule is decided by the advisor for the user on 2026-11-23, to be confirmed.)
7. **The final text always comes from the stored audio after Stop.** Live text is a preview. A bad live result never
   becomes the stored text.
8. **English only** in version 1.
9. **Permission check at each meeting start.** If a permission is missing, Rafu shows a clear message. It never
   records silently with an empty track.
10. **Labels stay "Speaker 1", "Speaker 2", "Speaker 3"** until the user names them. When no speaker model is
    installed, each far turn has the label "Them", and the Transcript sidebar offers the speaker model download.
    (Decided by the advisor for the user on 2026-11-23, to be confirmed.)
11. **Capture rules** (see the amendment): no voice processing; an echo mark in the text; the Automatic microphone
    rule.

## Amendment 2026-11-23

The user said, on 2026-11-23: build the rest of the meeting note-taker; bring Nemotron into version 1; offer three
text engines; give the user a choice. For each decision that the user did not take, the advisor answered as the user
would, from the recorded decisions. Each such answer is marked "decided by the advisor for the user on 2026-11-23, to
be confirmed". The user can find and change each one.

This amendment replaces three lines of the first version: "Text engine. Apple speech", "Speaker engine. SpeakerKit"
and "Nemotron later".

### Text engines

Decided by the user on 2026-11-23: Nemotron English 1120 ms is the default, Apple speech and WhisperKit large-v3 are
the other two choices. The reason is the bench above.

**Changed by the user later on 2026-11-23, after real calls:** WhisperKit large-v3 is the default text engine. In real
Teams calls, Nemotron gave text with no punctuation and two turns for six minutes; WhisperKit gave accurate text.
Nemotron and Apple speech stay as choices. The first-use sheet is now "Choose a speech model", with WhisperKit first and
marked "Recommended", and one "Done" button. A user who never chose an engine gets WhisperKit; until its model is
installed, the final text uses Apple speech.

- At the first use of Meetings, Rafu shows one sheet: "Download Nemotron (613 MB)" with the licence line, and the
  buttons Download and "Use Apple speech for now". Rafu never downloads with no user action.
- WhisperKit makes the final text after Stop only. It works on 30 s windows, and no live path is measured. When
  WhisperKit is selected, the live preview comes from Nemotron when its model is installed, else from Apple speech.
  The live view names that engine. (The live source is decided by the advisor for the user on 2026-11-23, to be
  confirmed.) The first load after an install takes about 58 s. The meeting shows "Preparing model" with a Cancel
  control.
- Live Nemotron text comes from the helper (two streams, 1120 ms chunks). The helper has a footprint limit of 1.0 GB.
  At the limit, the app starts a new helper at a chunk boundary. (Decided by the advisor for the user on 2026-11-23,
  to be confirmed.) Measured: 268 MB peak for two streams in 5 minutes; a warm load of 0.08 to 0.13 s; growth of 126
  to 303 MB in 25 minutes with an unknown owner. If the gate of the speech worker package fails, the live view says
  "Text comes after Stop" for Nemotron, and Apple speech keeps live text.
- The NVIDIA Open Model License is accepted for a download that the user starts in Settings. Settings shows the
  licence name, the size and the line "Licensed by NVIDIA Corporation under the NVIDIA Open Model License" before the
  download. A copy of the licence text stays in the model folder. (Decided by the advisor for the user on 2026-11-23,
  to be confirmed.)

### Speaker engines

Nemotron 3 `fast32` is the default. SpeakerKit stays as the second choice. **Answered for the user by the advisor on
2026-11-23; the user can change it.**

The user's sentence "Apple's speakerkit is not working well, bring nemo in phase 1" is about the text engine that
the user saw fail on the real voice. SpeakerKit belongs to Argmax, not to Apple. No speaker engine ran in the live
tests of that night. The speaker numbers were already measured, and they point the same way.

On diarization error (strict collar), Nemotron 3 `fast32` against SpeakerKit:

| Set | Nemotron 3 | SpeakerKit |
|---|---|---|
| NUM | 1.71% | 5.34% |
| S2 | 1.68% | 9.41% (found 3 speakers of 2) |
| S3 | 2.16% | 30.52% |
| S5 | 21.14% | 54.24% (both counts wrong: 4 of 5, 3 of 5) |
| R1, the one real meeting | 9.62% | 35.34% (found 5 of 4) |

- With Apple text, the speaker-attributed word error on S3 is 4.83% with Nemotron 3 and 27.70% with SpeakerKit.
- Peak memory on the 25-minute file is 517 MB against 926 MB. SpeakerKit reaches 1.64 GB at 2 hours.
- SpeakerKit is better in two cases only: S8 (8 speakers: 35.61% and a correct count, against 60.41% and 4 of 8) and
  the count on S2-similar (2 of 2 against 1 of 2; the error is the same, 44% to 47%).
- **The R1 number for Nemotron 3 is probably optimistic.** AMI (the real meeting set) is common training data for
  speaker models. The synthetic sets do not have that problem and show the same direction.

So Nemotron 3 is the default because it is better for a call with 2 to 5 far speakers and uses about half the
memory. SpeakerKit stays as the choice for large calls and as the fall-back if Nemotron 3 is worse on real calls.
Keeping both costs 11 MB of download and about 1.8 MB of helper binary. Not measured: Nemotron 3 memory at 2 hours.
The speech worker package must measure it.

### The helper, the models and the downloads

- One helper executable, `RafuMeetingsWorker`, links FluidAudio (0.18.4, with the Diarizer trait) and
  `argmax-oss-swift` (1.1.1). `RafuApp`, `RafuCore` and `RafuCLI` link neither. A check of the app binary with
  `otool -L` and `nm` proves it. Size measured: 7.03 MB stripped for FluidAudio and SpeakerKit; with WhisperKit not
  measured. (Decided by the advisor for the user on 2026-11-23, to be confirmed.)
- The app starts the helper with an executable and an argument array. The arguments hold no private text and no
  model path from a user input. One helper process does one kind of work: live text, final text, or speakers. The
  helper reads and writes bounded messages on standard input and output.
- The app ends a helper when its job ends, on Cancel, on critical memory pressure (the audio is kept and the
  meeting shows "Processing stopped, try again"), and when the app quits.
- Each model file has a pinned revision, a SHA-256 and an exact size. The app checks each file before the folder
  becomes visible. One wrong byte removes the staged folder. The install is atomic: stage a folder, then rename it.
  The helper gets the model folder path only.
- A meeting records which engine and which model revision made its text and its speakers. "Make the text again with
  the other engine" is a user action. It keeps the old result until the new one is ready.

### Capture findings (session 1 of the capture check)

Measured on macOS 27.2.1, on one Mac, with a throw-away check app. The details are in the note about meeting audio
capture. Behaviour on macOS 26 is not measured.

- **Prompt order.** macOS asks for the microphone first, then for system audio.
  `NSSpeechRecognitionUsageDescription` is not needed for on-device Apple speech.
- **The Swift 6 tap-block trap.** A `installTap` block that is formed inside a `@MainActor` class inherits main-actor
  isolation. The block runs on the audio thread, and the check app crashed on the first microphone buffer
  (`EXC_BREAKPOINT` in the isolation check). Fix: build the block in a `nonisolated` static function that returns a
  `@Sendable` closure. The tree already has this pattern in `VoiceAudioIO.installTap`. Meetings no longer uses
  `installTap` (see the amendment about the capture method of "Me"); the rule stays for Voice, which keeps
  `AVAudioEngine`.
- **The global tap.** It works on the built-in speakers and on AirPods. It gives no buffers until sound plays: the
  first buffer of "Them" came 12.65 s after Start in one run, and 15.0 s in another.
- **The 24 kHz rule.** When AirPods are in call mode, the output runs at 24 kHz, but the tap format said 48 kHz. The
  buffers then sounded as 2x speed audio, and the text was wrong. Fix: read `kAudioDevicePropertyNominalSampleRate`
  of the aggregate device and use it. Read it again on each device change.
- **Host-time alignment.** Each chunk has the host time of its first sample. The meeting clock is the host time of
  the chunk minus the host time of Start. Never align the two tracks by the start of each file.
- **Echo on the Mac speakers.** With the built-in speakers and the built-in microphone, the microphone follows the
  tap sound. Correlation 0.88 at a microphone delay of 30 ms. The user saw the same text in "Me" and "Them".
- **Voice processing is not used.** With voice processing on, the tap gave 0 buffers, the other sound became
  quieter (voice-processing ducking, not AirPods call mode), and the microphone input became 3 channels at 24 kHz.
  With voice processing off, the tap worked on the same AirPods.
- **The grants after a rebuild.** Rebuild 1 (a new ad-hoc signature hash) kept both grants. Rebuild 2 made macOS ask
  again for both. The rule is not yet clear. See "Open".

### Capture rules

- **No voice processing.** It stops the call-audio tap and makes other sound quieter.
- **The echo mark in the text.** *(The turn rule that is written here is replaced by a word rule; see "Amendment
  2026-11-23: the echo mark is set for each word" below.)* A "Me" turn that repeats a "Them" turn in the same time
  window is marked "echo" and is hidden by default. It is never deleted. The rule needs 0.8 word overlap, 3 words
  or more, and the built-in speakers or a correlation flag. At the start, when the output is the built-in speakers, the view says "Use
  headphones for a clean Me track". The "Me" level meter stays honest. (Decided by the advisor for the user on
  2026-11-23, to be confirmed.)
- **The Automatic microphone rule.** Settings ▸ Meetings ▸ "Microphone": Automatic (the default), System default, or
  a named device. Automatic is the system default input, but the built-in microphone when the default input is a
  Bluetooth device. Rafu leaves the output on the headset. The start view names the microphone in use. When a
  Bluetooth microphone is in use, it says "A headset microphone gives poor text. Use the Mac microphone." (Decided by
  the advisor for the user on 2026-11-23, to be confirmed. The reason is the AirPods numbers in the bench.)
- **"Them" is all sound that the Mac plays** in version 1. The start view says "Records all sound that this Mac
  plays". Music or a video that plays during the call is also recorded.

## Amendment 2026-11-23: the capture method of Me

**Decision (taken in the work package "Meetings capture without AVAudioEngine", after a live crash).** "Me" is
recorded through a Core Audio IO block on the selected input device
(`AudioDeviceCreateIOProcIDWithBlock`), the same path as "Them". Meetings capture does not use `AVAudioEngine`,
`installTap` or `inputNode`. A test enforces it for every file under `Sources/RafuApp/Meetings`.

**Why.** With a Bluetooth headset as the default input and a browser call running, the Automatic microphone rule set the
built-in microphone on the input audio unit of the engine. The engine did not see that change. Its format did not match
the hardware, `installTap` raised an `NSException`, Swift could not catch it, and the whole app aborted. A path that has
no engine has no such mismatch. The evidence is in the note about meeting audio capture
([`meeting-audio-capture.md`](../references/meeting-audio-capture.md)).

**What stays the same.** The Automatic microphone rule, the 16 kHz mono output, the journal format, no voice processing,
the `MeetingAudioSource` protocol and the recorder state machine.

**What is new.**

- The format comes from the first input stream of the device. The rate label is the device nominal rate, read before and
  after the start (at most two passes). A format that is not Float32 fails the Start with a clear error.
- The AVFoundation calls that stay (the converters in Meetings and in Apple speech, and `installTap` in Voice) are
  wrapped by a small Objective-C exception guard, one call per guarded block
  ([`objc-exception-guard.md`](../references/objc-exception-guard.md)).
- At launch, a cut-off meeting with no audio, no journal, no recovered seconds and no turns is deleted. Before, each
  crash left a "Failed" row with no audio. A meeting with any audio or text is kept.

**Status.** Merged on `main`. Both test modes passed. The live checks with a Bluetooth headset are **pending**; the
decision stands unless they show a fault.

**Consequence.** The recorder was not changed. If a live check shows that "Me" fails to rebuild during a Bluetooth route
change (the recorder tries three times, 500 ms apart), report it with the diagnostics before changing the restart rule.

## Amendment 2026-11-23: the echo mark is set for each word

**Decision.** The echo mark is set for each "Me" word, not for a whole "Me" turn. This replaces the turn rule in
"Capture rules" (0.8 word overlap over a whole turn, 3 words or more, start window of -0.3 to 2.0 s).

**Why.** One meeting of 6 min 17 s on the built-in microphone and speakers (Teams) showed that the turn rule misses
echo and counts it as the user's talk time: a Nemotron turn with 79.7 percent matched words got no mark (the rule
needs 80), and two echo turns started 8 s and 11 s after the far-side turn, outside the 2.0 s window. The far-side
sound is as loud as the user's own voice, so no loudness test can separate
them; text match is the only usable signal. The numbers are in
[`meeting-transcript-quality.md`](../references/meeting-transcript-quality.md).

**The rule.**

- The mark is only set when the output was the built-in speakers. With headphones no word is marked.
- A "Me" word matches a "Them" word with the same normalised text when their start times are at most 1.5 s apart.
  Each "Them" word is used once.
- A run of 3 or more "Me" words with no pause between them is a stretch. A stretch of fewer than 3 words is never
  echo. In a stretch, a matched word is echo when at least 50 percent of the words within 3 places on each side are
  matched; an unmatched word is echo at 60 percent. A run of 1 or 2 words that is not echo, with echo on both sides in
  the same stretch, is echo too.
- The words stay in the turns. Turns are cut where the echo flag changes, so an echo turn holds only echo words. Echo
  turns are hidden by default and never deleted. Talk time and share count the speech time of non-echo words only.

**What stays.** No voice processing. The start-view line "Use headphones for a clean Me track". The level meter stays
honest.

**Status.** Merged on `main`, with unit tests on made-up words. The thresholds are design values taken from the one
meeting. They are not yet checked on a re-processed real meeting.

## Alternatives considered

- **Apple speech only.** Rejected on 2026-11-23: 34.4 percent words wrong against 21.1 percent for Nemotron on the
  user's voice.
- **Voice processing for echo.** Rejected: it stops the call-audio tap and makes other sound quieter.
- **The Nemotron 560 ms tier.** Rejected: 23.3 percent words wrong, no measured gain over the 1120 ms tier.
- **A vocabulary list.** Rejected: Apple's contextual strings gave no change in the bench.
- **Nemotron as the default** (first version of this record). Rejected on 2026-11-22 for two measured failures on
  synthetic sets. Replaced on 2026-11-23: the user chose Nemotron after the bench on the user's own voice.
- **WhisperKit as the default download.** Rejected. The cold load is 57.5 to 79.7 s. It is a user choice for the
  final text only.
- **One mixed track.** Rejected. It loses the difference between "Me" and "Them".
- **A separate capture path for macOS 15.** Rejected. The user chose one path.
- **Keep `AVAudioEngine` for "Me" and only catch the exception.** Not chosen. The engine does not see a device that is
  set on its input audio unit, so the mismatch stays, and the engine can be in a bad state after an exception. The
  engine is removed from Meetings capture, and the guard covers only the calls that stay.

## Consequences

- The speaker labels are a help, not a fact. The user can rename them. Nemotron 3 may do worse on real calls than on
  the AMI set.
- Three text models are about 1.4 GB of downloads. Each download is a user action with the size shown. Settings
  has a "Remove" action.
- The two speech packages link only into the helper. A helper crash or a memory peak does not stop the app or the
  recording.
- Permissions may be lost after an update with an ad-hoc signature. Rafu checks both permissions at each start and
  shows a message that names the Privacy pane.
- A headset microphone in call mode gives poor text for every engine. The Automatic rule avoids it, and the start
  view tells the user.

## Revisit trigger

A better measured speaker result. A Mac on macOS 26 that shows different capture behaviour. A wish for a language
other than English. A tap for one call app. Live text with WhisperKit. A Nemotron 3 result on real calls that is
worse than SpeakerKit.

## Open

Only what is not measured yet:

- Behaviour on macOS 26. It is not measurable on the Mac used for the spike.
- The permission rule after a rebuild (rebuild 1 kept the grants, rebuild 2 asked again).
- Real calls in each call app (Zoom, Teams, Google Meet in Chrome, FaceTime).
- AirPods output quality when the Mac microphone is the input.
- Helper memory at 2 hours, for each of the four models.
- The live checks of the new "Me" path with a Bluetooth headset (eight checks, in the note about meeting audio
  capture), including a USB headset with input and output streams.

## Related paths

- [`docs/references/meeting-audio-capture.md`](../references/meeting-audio-capture.md)
- `Sources/RafuCore/Meetings/`, `Sources/RafuApp/Meetings/` (planned)
- `Sources/RafuMeetingsWorker/` (planned; its target needs a change of `Package.swift` in the shared contracts
  package)
