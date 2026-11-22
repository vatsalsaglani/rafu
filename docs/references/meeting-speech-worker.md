# Meeting speech worker: the helper process, its wire, and its memory

- Applies to: the Meetings speech helper `RafuMeetingsWorker` (`Sources/RafuMeetingsWorker/`), its wire types
  (`Sources/RafuCore/Meetings/Worker/`), and the app-side client and the four engine adapters
  (`Sources/RafuApp/Meetings/Speech/Worker/`): Nemotron English text (live and after Stop), WhisperKit large-v3 text
  (after Stop only), Nemotron 3 speakers and SpeakerKit speakers (after Stop, "Them" track only). Related: the
  decision record about meeting capture and on-device speech
  ([`0048`](../decisions/0048-meeting-capture-and-on-device-speech.md)), the Meetings phase document
  ([`meetings.md`](../plans/phases/meetings.md)), and the capture note
  ([`meeting-audio-capture.md`](meeting-audio-capture.md)).
- Last verified: macOS 27.2.1 (build 26B8132), Apple Swift 6.4.2, Apple M5 Pro with 24 GB, on 2026-11-23.
  FluidAudio 0.18.4 (commit `e0c6103b`), argmax-oss-swift 1.1.1 (commit `1bbc57cb`).
- **macOS 26 is not measured.** All numbers are from one Mac. All audio is synthetic (macOS `say` voices, see
  "Reproduction"); no real meeting audio and no transcript text is in this note.

## Rule or observed behavior

### Process and wire (protocol 1)

- One helper process does one job and exits. The app starts it with an executable and an argument array:
  `RafuMeetingsWorker --mode <live-text|final-text|speakers> --protocol 1`. Nothing else is in the arguments: no
  path, no text. Each other argument shape exits 64.
- Environment: `PATH`, `HOME` and `TMPDIR` only (`MeetingWorkerProcess.helperEnvironment`). Standard error goes to
  `/dev/null`; it is never shown and never logged.
- Standard input, first line: one JSON request, at most 16 KB:
  `{"protocolVersion":1,"engine":"nemotron-en|whisperkit|nemotron-3|speakerkit","modelFolder":"/abs/path",
  "audioFile":"/abs/path","clockOffsetSeconds":0,"chunkMilliseconds":1120}`. `audioFile` is present in the file
  modes only. The helper refuses (exit 65) a relative path, a `.` or `..` part, a symbolic link in **any** part of
  either path, a model folder that is not a folder, an audio path that is not a regular file, and an engine that does
  not fit the mode. A missing model folder or a missing required model file is exit 66 (checked before any library
  call, so a library never falls back to a download).
- `live-text` (Nemotron only): after the request, binary frames: 1 byte track (0 me, 1 them), 8 bytes meeting-clock
  time of the first sample (little-endian `Double`), 4 bytes sample count (little-endian `UInt32`), then Int16
  little-endian samples at 16 kHz. A frame is at most 1 s (16,000 samples). The end of input means "finish".
- In the file modes the end of input means "cancel" (exit 75), until the helper has sent `done`. The client keeps
  standard input open during a job and closes it after `done`.
- Standard output: JSON lines, each at most 64 KB, with a `type` key: `ready` (`loadMs`, `cold`), `preparing`,
  `volatile` (`track`, `text`, `start`, `end`), `final` (`track`, `words`), `progress` (`fraction`), `segments`,
  `stats` (`peakFootprintBytes`, `chunkP50Ms`, `chunkP95Ms`), `done` (`audioSeconds`), `error` (`domain`, `code`).
  A long word or segment list comes as several lines (400 words or 800 segments a line). The client ends the
  session on an unknown `type`, a line that is not JSON, or a line over 64 KB.
- In `final-text`, the `track` field of a `final` line is not meaningful: the client uses the track of its own
  request.
- `cold` in `ready` is a rule of thumb: the load took 2 s or more. The helper cannot ask Core ML whether its cache
  was warm.
- Exit codes: 0 done, 64 usage, 65 bad request, 66 model missing, 70 engine error, 75 cancelled (also: the parent
  ended, or standard output is closed).
- The helper exits when its job ends, when the app that started it ends (a `DispatchSource` process source on the
  parent pid), and on a write error to standard output (SIGPIPE is ignored, so the write returns `EPIPE`).

### Model folder layouts that each local load call needs

| Engine | Folder content the helper checks | Load call |
|---|---|---|
| Nemotron English 1120 ms | flat: `metadata.json`, `tokenizer.json`, `decoder.mlmodelc`, `joint.mlmodelc`, `encoder/encoder_int8_v2.mlmodelc` (`decoder_joint.mlmodelc` used when present) | `StreamingNemotronAsrManager.loadModels(from:)` |
| WhisperKit large-v3 626 MB | flat: `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, `TextDecoder.mlmodelc`, `config.json`, **`tokenizer.json` directly in the folder** | `WhisperKitConfig(modelFolder:…, load: true, download: false)` |
| Nemotron 3 `fast32` | flat: `Nemotron3Diarizer_fast32.mlmodelc` and `learnable_sil_emb.bin` side by side | `Nemotron3Models.load(config: .fast32, directory:)` |
| SpeakerKit | the repository's nested tree: `speaker_segmenter/…`, `speaker_embedder/…`, `speaker_clusterer/…` | `PyannoteConfig(modelFolder:…, download: false, load: true)` |

### Engines in the helper

- Each job is one nonisolated async function. `Nemotron3Models` and `Nemotron3Diarizer` are not `Sendable`; they are
  made, used and dropped in `runNemotron3Speakers`. The helper target builds with 0 warnings and with no
  `@unchecked Sendable` or `@preconcurrency` on Rafu's own types.
- Live text: one `StreamingNemotronAsrManager` for each track. After each processed chunk the helper reads
  `getTokenTimings()`; a word becomes `final` as soon as the next word starts (the token list of the streaming model
  only grows), and the unfinished last word is `volatile`. Token times are seconds of fed audio; a per-track clock
  map turns them into meeting-clock times (a gap in the frame times, for example a pause, adds one anchor). At the
  end of input, `finishWithTokenTimings()` gives the last words. A `stats` line comes each 10 s with the
  `phys_footprint` peak (`task_vm_info.ledger_phys_footprint_peak`, the same number as `/usr/bin/time -l` "peak
  memory footprint") and the p50 and p95 chunk processing time of the window.
- Final text, Nemotron: the file is read in 10 s blocks (AVAudioFile, converted to 16 kHz mono Float) and fed to one
  manager; words come from `finishWithTokenTimings()` grouped at the SentencePiece word-start mark.
- Final text, WhisperKit: `preparing` before the load; `transcribe(audioPath:audioInputOptions:
  .incremental, decodeOptions: language "en", wordTimestamps: true)`, so the library reads the file in bounded
  chunks and gives its own windows. Progress is one step for each 30 s window.
- Speakers, Nemotron 3: the file is read in 10 s blocks through the diarizer's streaming path (`appendAudio`,
  `processBufferedAudio`, `finishStream`; FluidAudio documents it as frame-exact with `processComplete`). The frame
  probabilities go straight into `MeetingStreamingSpeakerSegmenter`, which gives the same segments as
  `Nemotron3Diarizer.segments(threshold: 0.5, minDurationSeconds: 0)` on the whole list (tested against a copy of
  that function), so the helper never keeps all frame probabilities. The speech spike kept them, and that made its
  memory grow.
- Speakers, SpeakerKit: automatic speaker count. SpeakerKit has no streaming form: it takes the whole track as one
  `[Float]` (about 230 MB for one hour of audio). Its memory grows with the meeting length.
- No speaker embedding, no audio and no result is written to disk by the helper (source-scan test).

### Client (`MeetingWorkerProcess`, `MeetingWorkerLiveHub`)

- The helper is `Contents/Helpers/RafuMeetingsWorker` in the app (`MeetingWorkerProcess.bundledHelperURL()`). When
  it is missing, each engine's `availability()` is `.unavailable` with "The Meetings speech helper is missing.
  Reinstall Rafu."
- Writes to standard input go through one serial queue per helper with a raw `write(2)` and `F_SETNOSIGPIPE`, so a
  full pipe never blocks a caller or the cooperative pool, and a dead helper gives `EPIPE`, not a signal. When live
  frames wait for the pipe, more than 8 waiting frames drop the oldest frame (counted). A request line is never
  dropped.
- One after-Stop job runs at a time (a FIFO slot in the actor); a live helper can run beside it.
- Cancel: closing the task terminates the helper (SIGTERM, SIGKILL after 2 s). App quit:
  `NSApplication.willTerminateNotification` sends SIGTERM to each running helper through a lock-protected registry
  (no await at quit). Critical memory pressure (`DispatchSource.makeMemoryPressureSource(.critical)`) stops the
  after-Stop job; the caller gets `MeetingWorkerError.memoryPressure`, whose message says the audio is kept.
- Exit mapping: 64 or 65 → `badRequest`, 66 → `modelMissing`, 70 → `engineFailed(domain, code)` from the `error`
  line, 75 → `cancelled`, a signal → `crashed`, 0 without `done` or an unknown line → `protocolViolation`.
- Live: both tracks share one helper. Audio waits in the hub (at most 2 MB, the oldest is dropped first) until the
  helper's `ready` line, so a cold model load does not fill the pipe. **Footprint guard:** when a `stats` line
  shows 1.0 GB (1,000,000,000 bytes) or more, the hub starts a new helper, keeps sending audio to the old one until
  the new one sends `ready`, then sends the next frame to the new one and closes the old one's input; the old one
  gives its last `final` lines and exits. Each frame goes to exactly one helper. A crashed live helper is started
  again. Two failed restarts (a launch that fails, or a new helper that ends before `ready`) give each session
  `.unavailable("Live text stopped. The text comes after Stop.")`; the recording goes on.
- Diagnostics (typed events only, no text, no path): `helperStarted`, `helperExited` (exit code or signal, wall
  time, peak footprint), `helperRestarted` (the footprint guard and critical memory pressure both use the reason
  `memoryPressure`, the nearest case in the contract), `textEngineLoaded` (load ms, cold), `liveTextWindow` (its
  "delay" fields hold the helper's chunk **processing** time p50 and p95, not the delay from speech to text),
  `finalTextDone`, `speakersDone` (speaker count, segment count), `engineError` (domain and code). The model
  revision in diagnostics and in `MeetingTrackTranscript.modelRevision` is the last part of the model folder path
  (the catalog installs to `…/Models/<model id>/<revision>/`).

## Measurements

Release helper, `/usr/bin/time -l` "peak memory footprint" (bytes / 1,000,000 = MB), one process at a time, warm
model load unless the row says cold. Speed = audio seconds / wall seconds of the whole process (load included).
Audio: L30 (1,526.7 s, "25 min"), H1 (3,600 s), H2 (7,200 s). Each number is one run.

### After Stop (one helper process for each run)

| Engine | 25 min: peak / wall / speed | 1 hour: peak / wall / speed | 2 hours: peak / wall / speed | Words or speakers (2 hours) |
|---|---|---|---|---|
| Nemotron English text | 48.1 MB / 18.1 s / 84x | 48.1 MB / 42.5 s / 85x | 48.4 MB / 85.9 s / 84x | 17,486 words |
| WhisperKit large-v3 text | 161.5 MB / 75.5 s / 20x | not measured (time; stopped to finish the package) | not measured (same reason) | 3,683 words at 25 min |
| Nemotron 3 speakers (`fast32`) | 99.3 MB / 7.1 s / 217x | 99.2 MB / 15.3 s / 235x | 109.5 MB / 29.6 s / 243x | 5 speakers found (the file has 3), 2,217 segments |
| SpeakerKit speakers (automatic count) | 764.5 MB / 10.7 s / 143x (cold load 7.9 s) | 1,116.5 MB / 6.6 s / 549x | 1,660.4 MB / 13.0 s / 555x | 3 speakers found (the file has 3), 2,066 segments |

- Nemotron English text, final pass: the peak does **not** grow with the meeting length (48 MB at 25 minutes and at
  2 hours). The speech spike measured 491 MB at 25 minutes and a growth of 126 to 303 MB "with an unknown owner";
  the spike fed the whole file in one `process(audioBuffer:)` call, so the manager's own `audioBuffer` held the whole
  file (and `removeFirst` copied it for each chunk). The helper feeds 10 s blocks, and the growth is gone.
- Cold load (first run of a new helper build): Nemotron English 6.7 s, 48.8 MB peak on a 15 s file.
- Cold load (first run of a new helper build): WhisperKit 57.5 s (60.5 s wall, 120.9 MB on a 15 s file); the next run
  of the same binary loaded in 0.73 s. A cold load shows as "Preparing model" (the `preparing` line).

### Live Nemotron text, two streams, 2 hours

| Run | Peak footprint | Peak over time | Chunk p95 (1120 ms chunk) | Footprint restarts | Words |
|---|---|---|---|---|---|
| H2 on both tracks, frames fed faster than real time (214 s wall) | 89.5 MB | flat: 22 `stats` lines, RSS 111 to 114 MB during the run, never near 1.0 GB | max window p95 26 ms, median window p95 15 ms | 0 | 17,486 for each track (the same count as the final pass) |

- The run fed the 2-hour file as fast as the helper took it (back pressure through the pipe), so it measures memory
  over 2 hours of audio and processing time under continuous load. **A paced (real-time) 2-hour run was not
  measured** (it takes 2 hours). The speech spike's paced 5-minute run had p95 106 ms for two streams.
- Verdict for the live gate: chunk p95 26 ms is far below 560 ms, the footprint stays at 90 MB (the 1.0 GB guard
  did not fire), and the fake-helper test shows that no chunk is lost at a restart. Live Nemotron text passes; the
  fall-back "Text comes after Stop" is not needed.

### Meeting length limits (a peak over 2.0 GB)

- Nemotron English text (live and final) and Nemotron 3 speakers: flat peaks (48 to 110 MB) up to 2 hours; no
  limit is needed.
- WhisperKit: 161.5 MB at 25 minutes; 1 hour and 2 hours **not measured** (the runs were stopped to finish the
  package). The library reads the file in bounded chunks, so growth is not expected, but it is not proven.
- SpeakerKit: 764 MB at 25 minutes, 1.12 GB at 1 hour, 1.66 GB at 2 hours (about 0.55 GB more for each hour). By
  that line it passes 2.0 GB at about 2 hours 40 minutes (**not measured**). Limit: for meetings longer than
  2.5 hours, use Nemotron 3 (the default) or show a warning before SpeakerKit runs.


## Why it matters

- The helper keeps FluidAudio, WhisperKit, SpeakerKit and Core ML memory out of the app. A crash or a memory peak
  in the helper does not stop the app or the recording.
- The no-symbolic-link rule refuses a path below `/var`, `/tmp` or `/etc` (each is a link to `/private/…` on
  macOS). Model folders and meeting audio live in `~/Library/Application Support`, which has no link part. A test
  that makes a temporary folder must resolve it with `realpath(3)`: `URL.resolvingSymlinksInPath()` maps
  `/private/var` back to `/var`.

## Failure modes found while building it

- `AVAudioFile.read(into:)` throws at the end of the file instead of giving 0 frames. Check
  `framePosition < length` before each read (`AudioBlockReader`).
- libdispatch traps (`EXC_BREAKPOINT` in `_dispatch_semaphore_dispose`) when a `DispatchSemaphore` is freed with a
  value below the value it was made with. The input pump makes its semaphore with 0 and signals it N times.
- In the file modes, the end of input after `done` must not count as "cancel": the helper sets a flag before it
  writes `done`, else a client that closes input at once races the helper's own exit 0 into exit 75.
- The Core ML compile cache did not carry over between two different builds of the helper: a new binary loaded
  Nemotron in 6.7 s and WhisperKit in about 57 to 63 s, then warm on the next run of the same binary. Each new
  Rafu build will show one cold load per model.
- The module `SpeakerKit` and its class `SpeakerKit` have the same name: `SpeakerKit.DiarizationResult` does not
  resolve, and `DiarizationResult` alone is ambiguous with FluidAudio's type. Let the type be inferred.

## Reproduction and verification

- Synthetic audio: `make_testset.py` and the `scripts/*.tsv` from branch `spike/meeting-speech`
  (`git show spike/meeting-speech:Spikes/MeetingSpeech/testset/make_testset.py`), run with Python and `ffmpeg` in a
  work folder outside the repository: `--set NUM`, `--set S3`, `--set L30` (L30 is 1,526.7 s, about 25 minutes).
  The 1-hour and 2-hour files join L30 with
  `ffmpeg -stream_loop 2 -i L30/them.wav -t 3600` and `-stream_loop 4 … -t 7200`. Never commit audio.
- Models: fetched at the pinned revisions of the Meetings plan's model catalog; the SHA-256 of each Nemotron 3
  `fast32` file and of the four SpeakerKit weight files matched the recorded values on 2026-11-23.
- Release helper: `swift build -c release --product RafuMeetingsWorker`. Each number above is one
  `/usr/bin/time -l` run of the release helper, one process at a time, driven by a small local script that writes
  the request, keeps standard input open until `done`, and reads the lines (for live text it writes two tracks of
  frames).
- Tests: `swift test --filter "MeetingWorker|speech worker"`. The tests that start the real helper need the built
  helper (`.build/debug/RafuMeetingsWorker` or `RAFU_MEETINGS_WORKER_BINARY`); the engine tests also need
  `RAFU_MEETINGS_MODEL_DIR` (one sub-folder for each model id) and can take `RAFU_MEETINGS_TEST_AUDIO` (a short
  synthetic speech file). Without them, those tests are skipped.
- Link checks: `otool -L` and `nm` on `Contents/MacOS/RafuLightning` show no FluidAudio, WhisperKit or SpeakerKit
  symbol; `otool -L Contents/Helpers/RafuMeetingsWorker` shows system frameworks only (the packages link
  statically).
