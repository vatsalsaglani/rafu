# Meeting diagnostics: the log, the Logger mirror and the export

## Applies to

Meetings (the app-level call note-taker). The diagnostics record what the capture, speech, helper, model, library and hidden-agent code did, as typed events with numbers and short device facts. It never holds meeting content. The user tests Meetings on another Mac, exports the diagnostics after each call, and sends the zip back.

- Last verified: Swift 6.4.2, macOS SDK 27.2, Darwin 27.2.0 (Apple silicon), on 2026-11-23. The tests do not open an audio device and do not use the network.
- Related code: `Sources/RafuCore/Meetings/Contracts/MeetingDiagnostics.swift` (the event contract), `Sources/RafuCore/Meetings/Contracts/MeetingDiagnosticString.swift`, `Sources/RafuCore/Meetings/Diagnostics/`, `Sources/RafuApp/Meetings/Diagnostics/`, `Tests/RafuCoreTests/Meetings/Diagnostics/`, `Tests/RafuAppTests/Meetings/Diagnostics/`.
- Related decisions: the plan for the Meetings fan-out (decision 20, "Meeting diagnostics", and section 5.4) in `.rafu/plans/meeting-notetaker-fanout-v3.md`; the decision record about Meetings scope (privacy of Meetings data in Rafu's app data); the phase document `docs/plans/phases/meetings.md`.

## Rule: what may be in a diagnostics line

An event has no free text field. Its values are numbers, booleans, fixed enum words, ids, OSStatus and error codes, and a short list of facts that go through `MeetingDiagnosticString` (device name, device UID, bundle id, error domain, version strings). `MeetingDiagnosticString` cuts a value to 128 UTF-8 bytes and removes control characters. The log never holds a transcript word, a meeting title, a speaker name, a question, an answer or an audio path.

Three layers keep the rule:

1. The type. A source-scan test fails when a case of `MeetingDiagnosticEvent` gets a `String`-typed value outside `MeetingDiagnosticString`.
2. The describer. `MeetingDiagnosticEvent.diagnosticDescription` is one `switch` with no `default`, so a new case does not compile until it is described. It replaces a text value that starts with `/`, `~` or `file:` with `[path removed]`. The file and the `Logger` mirror both read this description, so one rule covers both.
3. The marker-word test. A synthetic meeting has the marker `ZEBRAQUARTZ` in its speech text, title, speaker name, question, answer and audio file name. Every event case goes through the public recorder. The marker is in no diagnostics file, not in `header.json`, not in the unzipped export, and not in the log text that a capturing sink gets.

Honest limit: a device name can hold a person's name ("Priya's AirPods"). The save panel says what the bundle holds: "Device names, app identifiers, error codes and timings. No transcript, no audio."

## Where the files are

`RafuAppIdentity.current.applicationSupportRoot()/Meetings/Diagnostics/` (Rafu Lightning and Rafu use different roots).

| File | Holds |
|---|---|
| `<meeting id>.jsonl` | the events of one meeting |
| `<meeting id>.1.jsonl` | the older half of that meeting, after a rotation |
| `app.jsonl` (and `app.1.jsonl`) | events with no meeting (start-up, export, model downloads) |

- The folder is mode 0700; each file is 0600. All writes stay below the folder that the writer got.
- A file rotates at 2 MB: it moves to `.1.jsonl` (replacing an older one) and a new file starts, so a meeting holds 4 MB at most.
- Rafu keeps the files of the newest 20 meetings (by modification time). The check runs when a meeting file is first written. `app.jsonl` is never removed by this rule.
- Each file starts with a `header` line. A new process, and each new file after a rotation, writes the header again.
- The write buffer flushes every 2 s, at `stop()`, when it holds 64 KB, and at once after `recordingStopped`, `helperExited`, `engineError` and `userFacingError`.
- `MeetingDiagnosticsRecorder.deleteDiagnostics(for:)` and `MeetingDiagnosticsFileWriter.delete(meeting:)` delete one meeting's files. The library package must call it when the user deletes a meeting (see "Hook to wire" below).

## Line format

One JSON object on each line, keys sorted:

```
{"clock":12.65,"event":"firstBuffer","frames":480,"t":"2023-11-14T22:13:20.250Z","track":"them"}
```

| Key | Meaning |
|---|---|
| `t` | time, ISO 8601 in UTC with milliseconds |
| `clock` | seconds since the first event of that meeting in this process. Omitted for events with no meeting. This is close to the meeting clock because capture records its permission and device facts at Start; it is not the host-time meeting clock of the audio journal |
| `event` | the case name of `MeetingDiagnosticEvent` |
| `dropped` | only when events were lost since the previous line: the number of events dropped by the full queue plus the lines lost by a failed write |
| other keys | the fields of the event (below) |

Numbers have three decimals at most; a number that is not finite is `null`. A fixed word is the case name of an enum. A device is flattened to `<prefix>.name`, `.uid`, `.transport` (a four-character code such as `bltn` for built-in, `blue` for Bluetooth, or hex), `.rate`, `.channels`; a missing device is `<prefix>: "none"`.

## Events and fields

| Event | Fields | Emitted by |
|---|---|---|
| `header` | `macOSVersion`, `macOSBuild`, `macModel` (`sysctl hw.model`), `rafuVersion`, `rafuBuild`, `rafuVariant` (`release` or `lightning`), `timeZoneOffsetSeconds` | diagnostics (each file) |
| `permissions` | `microphone`, `systemAudio` (`notDetermined`, `denied`, `granted`, `unknown`) | capture |
| `devices` | `input.*`, `output.*` (device fields above) | capture |
| `microphoneChoice` | `kind` (`automatic`, `systemDefault`, `named`), `reason` | capture |
| `playingProcesses` | `count`, `bundleIDs` | capture |
| `coreAudioCall` | `call` (enum of the Core Audio call), `status` (OSStatus, 0 is success) | capture |
| `tapFormat` | `sampleRate`, `channels`, `bits`, `interleaved` | capture |
| `aggregateDeviceRate` | `nominalSampleRate` | capture |
| `sampleRateCorrected` | `from`, `to` | capture |
| `firstBuffer` | `track` (`me`, `them`), `frames` | capture |
| `trackFlow` | `track`, `buffers`, `frames`, `silentBuffers`, `droppedBuffers`, `lateBuffers`, `peakDBFS`, `meanDBFS`, `converterErrors` (each 10 s) | capture |
| `deviceChanged` | `track`, `old.*`, `new.*` | capture |
| `recordingPaused`, `recordingResumed` | none | capture |
| `recordingStopped` | `recordedSeconds` | capture |
| `journalSync` | `bytes`, `ok` | recorder, journal |
| `journalRecovery` | `result`, `recoveredSeconds` | journal |
| `textEngineLoaded` | `engine`, `model`?, `modelRevision`?, `loadMilliseconds`, `cold` | speech |
| `firstLiveText` | `engine`, `track`, `ms` | speech |
| `liveTextWindow` | `engine`, `track`, `delayMedianMs`, `delayP95Ms`, `words` (each 60 s) | speech |
| `liveSessionRestarted` | `engine`, `track`, `reason` | speech |
| `finalTextDone` | `engine`, `track`, `audioSeconds`, `wallSeconds` | speech |
| `engineError` | `engine` (`text:<id>` or `speaker:<id>`), `domain`, `code` | speech |
| `helperStarted` | `mode` (`liveText`, `finalText`, `speakers`), `engine` | speech worker |
| `helperExited` | `mode`, `wallSeconds`, `exitCode`?, `signal`?, `peakFootprintBytes`? | speech worker |
| `helperRestarted` | `mode`, `reason` (`crashed`, `unresponsive`, `memoryPressure`, `protocolError`) | speech worker |
| `speakersDone` | `engine`, `modelRevision`?, `audioSeconds`, `wallSeconds`, `speakers`, `segments` | speech worker |
| `modelDownloadStarted` | `model`, `expectedBytes` | model catalog |
| `modelDownloadFinished` | `model`, `bytes`, `wallSeconds`, `checksum`, `install` | model catalog |
| `libraryWrite` | `result` (`written`, `conflict`, `failed`), `code`? | library |
| `libraryIndexRebuilt` | `meetings`, `wallMs` | library |
| `exportDone` | `kind` (`markdown`, `diagnostics`; never a path) | library, diagnostics |
| `agentRun` | `cli`, `cliVersion`?, `exitCode`?, `wallSeconds`, `replyBytes`, `citations`, `failedCitations`, `outcome` | hidden agent |
| `userFacingError` | `place`, `domain`, `code` | each package |

A key with `?` is left out when the value is nil. The golden lines in `MeetingDiagnosticsEncoderTests` show the exact output of each event, and a test fails when a new case has no golden line.

## Limits and failure behaviour

- `record` never blocks and never throws. The queue holds 1,024 events (`AsyncStream` with `.bufferingNewest`). When it is full the oldest event is dropped and counted; the next written line has `dropped`. Test: 10,000 events from 8 tasks, order kept for each task, written + dropped = 10,000, `record` p99 under 1 ms.
- A write error (disk full, folder missing) never reaches the caller. The lost lines are counted and the next line that gets written reports them as `dropped`. The writer keeps trying at the next flush.
- Do not call `record` from an audio callback. Audio callbacks only add to atomic counters; a timer off the audio thread reads them and records one `trackFlow` event.
- No `print`, `NSLog` or `Logger` call is allowed under `Sources/*/Meetings/` outside `MeetingDiagnosticsLogger.swift` (a source-scan test lists the files that break the rule).

## The Logger mirror

`MeetingDiagnosticsLogger` writes each event to `Logger(subsystem: "dev.vatsalsaglani.rafu", category: "meetings")` at the `info` level: the event name, the first eight characters of the meeting id, then the numbers and fixed words as public text, then each `MeetingDiagnosticString` value (device names, bundle ids) as private text.

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "dev.vatsalsaglani.rafu" AND category == "meetings"'
```

Private text shows as `<private>` in a normal log; the files hold the full facts.

## How to read a log for the common failures

Open the exported `<meeting id>.jsonl` and read from the `header` line down. The order of the events is the order of the work: `permissions`, `devices`, `microphoneChoice`, `playingProcesses`, the `coreAudioCall` lines, `tapFormat`, `aggregateDeviceRate`, `firstBuffer`, then `trackFlow` every 10 s.

- **No "Them" buffers.** No `firstBuffer` with `track: them`, or `trackFlow` for `them` with `buffers: 0`. Check `permissions.systemAudio` first (`denied` or `notDetermined`). Then check each `coreAudioCall` for `createProcessTap`, `createAggregateDevice`, `createIOProc` and `startDevice` with a `status` other than 0. A tap gives no buffers until the Mac plays sound; the first `firstBuffer` can come many seconds after Start, so also compare `clock` and `playingProcesses.count`. `silentBuffers` close to `buffers` means the tap runs and the Mac plays silence.
- **Wrong sample rate (garbled or fast text).** Compare `tapFormat.sampleRate` with `aggregateDeviceRate.nominalSampleRate` and `devices.output.rate`. The plan's rule is to trust the aggregate device rate. A `sampleRateCorrected` line (`from`, `to`) shows the correction ran; its absence with different rates is the bug. A `deviceChanged` line after Start can change the rate.
- **Lost permission.** `permissions` with `denied` or `notDetermined` for `microphone` or `systemAudio`, a non-zero `status` on the first Core Audio call, and a `userFacingError` with `place: capture`. The checks run at each Start, so a rebuilt Rafu Lightning that lost its grant shows here at the next recording.
- **Helper exit.** `helperExited` with `exitCode` or `signal` (for example 9 is a kill), `wallSeconds` and `peakFootprintBytes`; then `helperRestarted.reason` (`crashed`, `unresponsive`, `memoryPressure`, `protocolError`) and `liveSessionRestarted`. A `peakFootprintBytes` near the 1.0 GB limit with `memoryPressure` is the footprint limit working. An `engineError` just before the exit carries the domain and code.
- **Slow or missing live text.** `textEngineLoaded` (`cold`, `loadMilliseconds`), `firstLiveText.ms`, then `liveTextWindow` delay and `words` each 60 s; `words: 0` while `trackFlow` shows loud audio means the engine is not producing text.
- **Lost lines.** A `dropped` key on a line means the queue or the disk lost that many events before it.

## Export

Meetings ▸ Export Meeting Diagnostics… (also in the Help menu; the Settings ▸ Meetings pane button is added by the Settings package) does this:

1. Reads the Mac and Rafu facts, the engine states (`ready`, `needsModel`, `unavailable`, `notRegistered`; the engine's own reason text is not exported), the model install states (`installed`, `notInstalled`, `unknown`), the Settings ▸ Meetings values as fixed words (the microphone choice is `automatic`, `systemDefault` or `namedDevice`, never the device), and the number of meetings.
2. Builds a private temporary folder (mode 0700) `Rafu Meeting Diagnostics <yyyy-MM-dd>/` with `header.json`, `app.jsonl`, and the files of the newest 10 meetings.
3. Shows a save panel with the text "Device names, app identifiers, error codes and timings. No transcript, no audio." and the name `Rafu Meeting Diagnostics <date>.zip`. Nothing is written or sent without the panel.
4. Makes the zip with `/usr/bin/ditto -c -k --keepParent <folder> <zip>` (an executable and an argument array, never a shell string). If `ditto` fails, a Rafu popup offers to save the folder instead (every Rafu dialog uses the popup language; a policy test forbids `NSAlert` outside the popup presenter).
5. Removes the temporary folder on every path (success, Cancel, failure) and records `exportDone(kind: diagnostics)` on success, or a `userFacingError` with `place: export` on failure.

With zero meetings the bundle holds `header.json` and nothing else. The user sends the zip to the coordinator after each test call.

## Hook to wire

The contracts give `record(_:meeting:)` but no "meeting deleted" hook, so nothing calls `deleteDiagnostics(for:)` yet. Until the library calls it, the retention rule (newest 20 meetings) bounds the disk use, but a deleted meeting's diagnostics stay until it falls out of that window. The meeting clock on a line is also not the audio journal's host-time clock for the same reason (see the line format).

## Verification

```bash
./script/test.sh --filter MeetingDiagnostics
./script/test.sh --filter "Meeting diagnostics"
# launch check: ./script/build_and_run.sh, then Meetings > Export Meeting Diagnostics…
/usr/bin/log stream --level info --predicate 'subsystem == "dev.vatsalsaglani.rafu" AND category == "meetings"'
```
