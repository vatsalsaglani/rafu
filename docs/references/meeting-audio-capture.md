# Meeting audio capture: call-audio tap, microphone, live Apple speech

- Applies to: the planned Meetings capture path: call audio through a CoreAudio process tap, the microphone, and two
  live Apple speech streams (Me and Them). Also the capture rules in the decision about meeting capture and
  on-device speech ([`0048`](../decisions/0048-meeting-capture-and-on-device-speech.md)). The check code is
  throw-away, in `Spikes/meetings/capture/` on branch `spike/meetings-capture`, and is never merged.
- Last verified: macOS 27.2.1 (build 26B8132), Xcode SDK 27.2, Apple Swift 6.4.2, Apple silicon. Steps 1 to 8 of the
  capture check were run on 2026-11-22. Session 1 (a person at the Mac) ran after that; its notes record times only
  (00:01 to 00:18) and no date.
- **Verified on macOS 27.2.1 only; macOS 26 is not measured.** Meetings keeps macOS 26 as its minimum (user decision,
  2026-11-22). No macOS 26 Mac is available here.
- **Status:** session 1 is done and its results are below. Sessions 2 and 3 (real calls in each call app; the rule
  for permissions after a rebuild) are hand checks for the user. Each row that they would fill says "not measured
  (morning hand check)".
- No transcript text is in this note. No account names are recorded.

## Rule or observed behavior

### Session 1 results (a person at the Mac, built-in speakers and AirPods)

Source: the coordinator notes of session 1 (check code on branch `spike/meetings-capture`). One Mac, one ad-hoc
signed check app. CHECKED unless marked.

| Topic | Result |
|---|---|
| Prompt order at the first run | The microphone prompt comes first: title `Allow "<app>" to access your microphone?`, with the `NSMicrophoneUsageDescription` text as body, and the buttons "Don't Allow" and "Allow". The system-audio prompt comes second: `"<app>" would like access to record your system audio.`, with the `NSAudioCaptureUsageDescription` text as body and a red record icon. The second prompt was on screen while the first crash happened (see the next row). Its text was captured on the later prompt (rebuild 2). |
| Swift 6 trap on the microphone tap | A crash at the first microphone buffer: `EXC_BREAKPOINT` in `_swift_task_checkIsolatedSwift` / `dispatch_assert_queue`, on queue `RealtimeMessenger.mServiceQueue`, in a closure in `LiveSession.startMicrophone`. Cause: an `installTap` block that is formed inside a `@MainActor` class inherits main-actor isolation (Swift 6), and the block parameter is not `@Sendable`. Fix: build the block in a `nonisolated` static function that returns a `@Sendable` closure. The tap callback of `ProcessTap` was already `@Sendable` and did not crash. The tree already has this pattern: `VoiceAudioIO.installTap` (`private nonisolated static func`, `Sources/RafuApp/Voice/VoiceAudioIO.swift`). |
| Global tap, built-in speakers | Works. Tap `OSStatus` 0. Tap format 48 kHz, 2 channels, 32-bit float, interleaved. The aggregate device main sub-device was the built-in speaker. Microphone: 48 kHz, 1 channel. |
| Global tap, AirPods Pro (Bluetooth, default input and output) | Works, with voice processing off (1,841 buffers in one run). |
| First tap buffer | The tap gives no buffers until output sound starts. Run after rebuild 1: first buffer of "Them" at 12.65 s after Start, first buffer of "Me" at 0.16 s, 0 dropped speech buffers. AirPods run: first buffer at 15.0 s. So the two tracks must be aligned by host time, never by file start. |
| Sample rate on AirPods in call mode | The output runs at 24 kHz, but `kAudioTapPropertyFormat` said 48 kHz. The tap gave 24,007 frames per second of wall time (3,311 buffers, 1,589,280 frames, first buffer at 15.0 s, last at 81.2 s). Buffers labelled 48 kHz were then 2x speed audio, and the text of "Them" was wrong. Fix: read `kAudioDevicePropertyNominalSampleRate` of the aggregate device and use it. After the fix, in the run with the aggregate rate 24000 against the tap's 48000, the text of "Them" was correct and complete for about 105 s of one speaker, with two wrong words. Read the rate again on each device change. |
| Echo on built-in speakers and built-in microphone (no voice processing) | The microphone envelope follows the tap envelope: correlation 0.88 at a microphone delay of +30 ms. Per 5 s correlation 0.6 to 0.86 while a video played. The microphone level was as loud as the tap level (for example -24 against -31 dBFS). The user saw the same text in "Me" and "Them". |
| Echo on AirPods (headphones) | None: correlation 0.11. |
| Voice processing | With voice processing on, the tap gave 0 buffers (AirPods run), the other sound became quieter, and the microphone input became 3 channels, non-interleaved, at 24 kHz. Channels 1 and 2 held the voice (identical, RMS -43 dB). Channel 3 was silent. The converter could not down-mix 3 channels, so live text gave nothing until the check app used channel 0. A run with voice processing off, on the same AirPods, showed normal volume and a working tap. So the quieter sound came from voice-processing ducking ("other audio ducking" is on by default), not from AirPods call mode, and the 0 buffers came with voice processing on. Rafu does not use voice processing. |
| Permission after rebuild 1 (new CDHash `77ef3a07…`) | No prompt. Both switches (microphone and system audio) were already on. |
| Permission after rebuild 2 (new CDHash `e284566f…`) | macOS asked again for both, microphone first, then system audio. The user allowed both. So rebuild 1 kept the grants and rebuild 2 lost them. The rule is not clear. Session 3 must repeat it. |
| Microphone on AirPods in call mode | 24 kHz, 1 channel. Level mean -40 dBFS, peak -12 dBFS. The live text of "Me" had many wrong words. |

Capture rules that follow (see the decision record for the full list): no voice processing; read the nominal rate;
align by host time; check both permissions at each start; mark echo in the text; use the built-in microphone when the
default input is Bluetooth.

### Bench result for the two microphones

Source: the engine bench on the user's recordings (90 words, one speaker): branch `spike/meeting-speech-bench`,
commit `fb95bba`, script `Spikes/MeetingSpeech/bench/run_bench.sh` (not merged). Words wrong.

| Engine | Mac microphone | AirPods call-mode microphone |
|---|---|---|
| Apple speech | 34.4% | 71% |
| Nemotron English, 1120 ms | 21.1% | 81% |
| Nemotron English, 560 ms | 23.3% | 92% |
| WhisperKit large-v3 | 23.3% (17.6% with numbers made equal) | 73% |

The audio is the limit on the AirPods call-mode microphone, not the engine. So Rafu records "Me" from the built-in
microphone when one is available, and leaves the output on the headset. Apple live text was about the same as Apple
text made from a file. The coordinator summary of the first Apple live test gave about 36% on the Mac microphone and
about 71% on the AirPods microphone; the far side (a video) was nearly correct.

### APIs and their minimum macOS

From the SDK headers and Swift interfaces (SDK 27.2) and Apple's documentation JSON. CHECKED.

| API | Minimum macOS | Source |
|---|---|---|
| `AudioHardwareCreateProcessTap(_:_:)`, `AudioHardwareDestroyProcessTap(_:)` | 14.2 | `CoreAudio.framework/Headers/AudioHardwareTapping.h` lines 42-54; Apple docs |
| `CATapDescription` class (Objective-C) | 12.0 (class), usable only with the 14.2 tap calls | `CATapDescription.h` line 44 |
| `CATapDescription` Swift initialisers `init(stereoMixdownOfProcesses:)`, `init(stereoGlobalTapButExcludeProcesses:)`, `init(monoMixdownOfProcesses:)`, `init(processes:deviceUID:stream:)` and `processes: [AudioObjectID]` | 14.0 (Swift overlay extension) | `CoreAudio.swiftmodule/arm64e-apple-macos.swiftinterface` line 453 |
| `CATapDescription.bundleIDs`, `CATapDescription.isProcessRestoreEnabled` (tap follows an app by bundle id across restart) | **26.0** | `CATapDescription.h` lines 135-136, 166-167 |
| `CATapDescription.muteBehavior` (`.unmuted`), `isPrivate`, `uuid`, `name` | 13.0 enum / 12.0 class | `CATapDescription.h` |
| `kAudioTapPropertyFormat`, `kAudioTapPropertyUID`, `kAudioAggregateDeviceTapListKey`, `kAudioAggregateDeviceTapAutoStartKey`, `kAudioSubTapUIDKey`, `kAudioSubTapDriftCompensationKey` | not marked in the header (ship with the 14.2 tap API) | `AudioHardware.h` |
| `AudioHardwareCreateAggregateDevice`, `AudioDeviceCreateIOProcIDWithBlock` | 10.9 / 10.7 | `AudioHardware.h` |
| `AudioHardwareSystem.shared.processes`, `AudioHardwareProcess.pid/.bundleID/.isRunningOutput` (process list) | 15.0 (Swift overlay) | swiftinterface lines 12-30, 155-175 |
| `SpeechAnalyzer`, `SpeechTranscriber`, `AnalyzerInput(buffer:)`, `AssetInventory`, `SpeechTranscriber.ReportingOption.volatileResults` | **26.0** (`@available(anyAppleOS 26, *)`) | `Speech.swiftmodule/arm64e-apple-macos.swiftinterface` lines 11, 31, 226, 344; Apple docs |
| `AnalyzerInput(buffer: CMReadySampleBuffer)`, `bufferDuration`, `bufferFormat` | 27.0 (not used) | same file lines 16-27 |
| `NSAudioCaptureUsageDescription` (Info.plist) | 14.2 | Apple docs JSON for the key |

Every API the capture path needs is available on macOS 26. The bundle-id tap (`bundleIDs` + `isProcessRestoreEnabled`)
and Apple speech set the macOS 26 floor.

Exact initialisers used by the check:

```swift
let transcriber = SpeechTranscriber(
    locale: locale,                       // SpeechTranscriber.supportedLocale(equivalentTo: en-US)
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [.audioTimeRange])
let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.prepareToAnalyze(in: format)
try await analyzer.start(inputSequence: asyncStreamOfAnalyzerInput)
// end: continuation.finish(); try await analyzer.finalizeAndFinishThroughEndOfInput()
```

`bestAvailableAudioFormat` returned **16 000 Hz, 1 channel, Int16, interleaved** (CHECKED, `synthetic-results.json`
field `analyzerFormat`).

### Info.plist keys

| Key | Needed for | Evidence | Proposed Rafu text |
|---|---|---|---|
| `NSMicrophoneUsageDescription` | Me track | Rafu has it already (`script/build_and_run.sh` line 252); text must cover Meetings too. Session 1: the prompt shows this text as its body. | "Rafu listens to your microphone only while you use Voice or record a meeting you started." |
| `NSAudioCaptureUsageDescription` | Them track (process tap) | Apple docs: "A message that tells people why your app is requesting access to capture system audio on macOS", macOS 14.2. The key string is in `/System/Library/PrivateFrameworks/TCC.framework/Support/tccd` (`strings`), next to the service name `kTCCServiceAudioCapture`. TCC's prompt text: "“%@” would like access to record your system audio." (`TCC.framework/Resources/Localizable.loctable`, key `REQUEST_ACCESS_SERVICE_kTCCServiceAudioCapture`). Session 1 showed this prompt with the key text as its body. Behaviour without the key (variant `...meetingcapture.nokey`, tap on `afplay` at volume 0.02, 10 s): tccd logged "No usage string found (key:NSAudioCaptureUsageDescription)" and replied `auth_value=0` (denied); **no prompt**. Every tap call still returned 0 (`AudioHardwareCreateProcessTap`, aggregate device, IO proc, `AudioDeviceStart`), and buffers arrived at the full rate (501 248 frames in 10.44 s, 48 kHz), but **all 979 buffers were exact digital silence**. So a missing key fails silently, not with an error. CHECKED (`work/nokey/autotap-results.json`, tccd log 21:55:54) | "Rafu records the sound of the call app you choose, only while a meeting recording you started is running." (The text must change to match the global tap: all sound that the Mac plays.) |
| `NSSpeechRecognitionUsageDescription` | not needed | The check app has no such key. Two `SpeechAnalyzer` streams gave live text, and tccd logged no `kTCCServiceSpeechRecognition` request for the app during the run (unified log, `process == "tccd"`). CHECKED for on-device `SpeechAnalyzer` only | none |

### Permissions (TCC)

| Observation | Result |
|---|---|
| TCC service names | `kTCCServiceMicrophone`, `kTCCServiceAudioCapture` (tccd strings and unified log). `tccutil` service names: `AudioCapture`, `Microphone`, `SpeechRecognition` are accepted (`tccutil reset AudioCapture <bundle id>` prints "Successfully reset AudioCapture approval status", exit 0); an unknown name exits 70. The bundle id must be known to Launch Services (launched once), else exit 64 "No such bundle identifier". CHECKED on the spike variants |
| Who is "responsible" when the app starts with `open` from a terminal inside Rafu | The check app itself (`Resp:{TCCDProcess: identifier=dev.vatsalsaglani.rafu.spike.meetingcapture.synth ...}` in the tccd log). The `open` process itself is attributed to Rafu. CHECKED |
| What happens at launch | `coreaudiod` makes preflight checks (`preflight=true`) for Microphone, ScreenCapture and AudioCapture for the app when it lists audio processes. No prompt. CHECKED (tccd log, 21:28:22) |
| First run prompts (order, exact text, Privacy pane names) | Order and text: measured in session 1 (see the first table). The Privacy pane names are not recorded in the notes: not measured (morning hand check) |
| Denial: OSStatus, silent buffers, detection within 5 s | not measured (morning hand check). The no-key run shows that a denial can look like silent buffers with every call returning 0, so Rafu must check the permission state, not only the call results |
| Rebuild 1 and rebuild 2 with a new ad-hoc CDHash | Session 1: rebuild 1 kept both grants, rebuild 2 asked again for both. The rule is not known. Session 3 (hand check) repeats it with a changed string |

Ad-hoc signature of the check app, first stage (`codesign -dvvv`): `Identifier=dev.vatsalsaglani.rafu.spike.meetingcapture`,
`Signature=adhoc`, `TeamIdentifier=not set`, `CDHash=2006ead5f0137fda0225c0f56a3bade480206f83`. A clean rebuild of the
**same** source (`rm -rf .build`, `swift build -c release`, `./make_app.sh`) gave the **same** CDHash (CHECKED). So only a
source or Info.plist change gives a new CDHash; session 3 must change one string (`./make_app.sh --string-tag <text>`).
In session 1, the CDHash values were `2006ead5…` (first run), `77ef3a07…` (rebuild 1) and `e284566f…` (rebuild 2).

### Live speech (synthetic files at real-time pace)

Input: 16 kHz mono files from the speech spike (`work/S3/them.wav` 255.4 s as Them, `work/ME/them.wav` 232.0 s as Me),
looped to 10 minutes, fed in 100 ms buffers. Buffer k carries audio from k×0.1 s to (k+1)×0.1 s and is sent at feed
start + (k+1)×0.1 s, the moment a capture device would deliver it. "End of speech to final" uses the reference segment
ends (`ref.stm`, columns 4 and 5 only): the delay from a segment end to the first final result whose audio range reaches
that end.

Both runs: variant `...meetingcapture.synth` (no speech key), headless (no Dock icon), 600 s of audio per stream,
30-second resource samples (21 samples). CPU is percent of one core, averaged over 600 s from the cumulative CPU time
(`getrusage` for the app, `ps -o time=` for the speech service). CHECKED (`work/run1-1stream/synthetic-results.json`,
`work/run1-2streams/synthetic-results.json`). Zoom and Teams were running in the background during both runs.

| Measure | 1 stream (Them) | 2 streams, Me | 2 streams, Them |
|---|---|---|---|
| Analyzers start | yes, 0.11 s setup | yes, both, 0.17 s setup for the two | (same) |
| Time to first volatile text (speech starts at 0.0 s in the file) | 4.02 s | 4.04 s | 4.03 s |
| Time to first final text | 4.06 s | 4.08 s | 4.09 s |
| End of speech (reference segment end) to final text, median / p95 / max | 3.41 / 6.87 / 8.99 s (n=185) | 2.42 / 4.10 / 5.99 s (n=179) | 3.40 / 6.86 / 8.98 s (n=185) |
| Final arrival after the end of its own audio range, median / p95 | 2.32 / 3.83 s | 2.25 / 3.85 s | 2.32 / 3.80 s |
| Volatile arrival after the end of its own audio range, median / p95 | 0.03 / 0.09 s | 0.04 / 0.09 s | 0.04 / 0.09 s |
| Volatile / final results | 2071 / 185 | 2309 / 182 | 2068 / 185 |
| Buffers sent / dropped / late more than 20 ms (max late) | 6000 / 0 / 0 (6.8 ms) | 6000 / 0 / 0 (6.8 ms) | 6000 / 0 / 0 (6.8 ms) |
| App CPU, average | 0.88 % | 1.48 % (whole app) | |
| `localspeechrecognition` CPU, average | 2.34 % | 5.47 % (one process for both streams) | |
| App footprint, max sample (`task_info`) | 26.9 MB | 45.8 MB | |
| `localspeechrecognition` footprint, max sample / `phys_footprint_peak` (`footprint -p`) | 19.0 / 24.0 MB | 31.0 / 37.0 MB | |
| `localspeechrecognition` `vmmap -summary` peak | 23.8 MB | 37.4 MB | |
| `localspeechrecognition` Neural Engine memory (`neural`, "nofootprint") | 156 MB | 156 MB (not doubled) | |

Observations:

- **Two analyzers run at once; the second does not fail.** Both started and gave live text for 10 minutes.
- **One `localspeechrecognition` process serves both analyzers of one app.** One new PID appeared per run (12664 for 1
  stream, 18452 for 2 streams); three older instances from other clients stayed at about 5 MB. CHECKED
  (`speechServicePIDsBefore` / `After`). Its Neural Engine reservation stays 156 MB for two streams.
- The first volatile text comes about 4 s after audio starts, even though later volatile results arrive 0.03-0.09 s
  after their audio. INFERRED: the engine waits for about 4 s of audio before its first result.
- The Me file ends its segments differently from Them, so the end-of-speech delay differs by file (2.4 s vs 3.4 s
  median), not by stream count: Them gave the same numbers alone and next to Me.
- `NSSpeechRecognitionUsageDescription` is not needed: see the Info.plist table.

### Findings from the Meetings build (2026-11-23)

Found while the capture, Apple speech and integration packages were built. Both test modes were green on the merged
tree, and the app launched. macOS 27.2 as before; the handoff gives no other version.

- **`AVAudioConverter` takes at most 4096 input frames in one call and drops the rest.** Feed it pieces of 1024 frames.
- **An actor that appends to its own optional stored collection while it reads that collection in the same call
  crashes at run time** with an exclusivity access conflict.
- **Apple speech asset status on macOS 27.2.** `AssetInventory.status(forModules:)` reports `.supported` for a
  `SpeechTranscriber` made with no reporting options, while en-US is installed. Rafu treats `installedLocales` as
  the truth for "installed".
- **Final audio files start at meeting time 0.** The speech adapters rely on this.
- **A level alone cannot clear a "no audio" warning.** When no audio arrives, the recorder keeps the last level.

## Why it matters

- The process tap is the only way to get the Them track without a virtual audio driver. It needs its own privacy key
  and its own TCC service, separate from the microphone. Without the key, the tap fails silently with silent buffers.
- Ad-hoc signing changes the CDHash on every source change. Session 1 showed that a changed CDHash sometimes keeps the
  grants and sometimes loses them, so Rafu Lightning must check both permissions at each start.
- A wrong sample rate does not give an error. It gives wrong text. Read the nominal rate of the aggregate device.
- Voice processing looks like the cure for echo, but it stops the tap and makes other sound quieter. Rafu marks echo
  in the text instead.
- An `installTap` block formed in a `@MainActor` class crashes on the audio thread under Swift 6.
- Live text for two streams must fit next to Rafu's memory budget. The speech model runs in a system process and its
  Neural Engine memory is not counted in any footprint.

## Reproduction or evidence

All output stays in `Spikes/meetings/capture/work/` (never committed, deleted at the end).

```bash
cd Spikes/meetings/capture
swift build -c release
./make_app.sh --variant synth            # bundle id ...meetingcapture.synth, keeps the main id clean
W=<speech spike worktree>/Spikes/MeetingSpeech/work
open -W -n ./dist/MeetingCaptureSpike-synth.app --args --out "$PWD/work/run1-1stream" \
  --synthetic - $W/S3/them.wav --ref - $W/S3/ref.stm --minutes 10
open -W -n ./dist/MeetingCaptureSpike-synth.app --args --out "$PWD/work/run1-2streams" \
  --synthetic $W/ME/them.wav $W/S3/them.wav --ref $W/ME/ref.stm $W/S3/ref.stm --minutes 10
```

No-key proof (quiet test sound, 10 s tap, no person):

```bash
./make_app.sh --no-audio-capture-key --variant nokey
afplay -v 0.02 work/nokey/clip20.wav & APID=$!
open -W -n ./dist/MeetingCaptureSpike-nokey.app --args --out "$PWD/work/nokey" --autotap 10 --tap-pid $APID
kill $APID; tccutil reset AudioCapture dev.vatsalsaglani.rafu.spike.meetingcapture.nokey
```

The app writes `synthetic-results.json`: per-stream timings, 30-second samples of its own CPU time (`getrusage`) and
footprint (`task_info` `phys_footprint`), and for each `localspeechrecognition` process that started after launch:
`ps -o time=`, `footprint -p` (Footprint, `phys_footprint_peak`, `neural`), and `vmmap -summary` (Physical footprint,
peak).

Session 1 evidence: the coordinator notes in `Spikes/meetings/capture/work/session1/` (untracked, on the capture check
worktree) and the saved runs next to them. Audio and text files of the runs are not part of this note.

### Working tap setup (from `ProcessTap.swift`, error handling shortened)

The snippet shows the per-process tap that the check used first. Session 1 found two corrections: take the sample rate
from the aggregate device (`kAudioDevicePropertyNominalSampleRate`), not from `kAudioTapPropertyFormat`, and keep every
audio-thread block `@Sendable` and `nonisolated`.

```swift
let tapDescription = CATapDescription(stereoMixdownOfProcesses: [callProcessObjectID])
// macOS 26: follow the app across restarts instead of one process object
// let tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
// tapDescription.bundleIDs = ["us.zoom.xos"]; tapDescription.isProcessRestoreEnabled = true
tapDescription.uuid = UUID()
tapDescription.muteBehavior = .unmuted      // the user still hears the call
tapDescription.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)

var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var format = AudioStreamBasicDescription()
var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)

var tapUID: CFString = "" as CFString
size = UInt32(MemoryLayout<CFString>.size)
address.mSelector = kAudioTapPropertyUID
status = withUnsafeMutablePointer(to: &tapUID) {
    AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0) }

let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Meeting tap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: defaultOutputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: defaultOutputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                       kAudioSubTapUIDKey: tapUID as String]],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)

let avFormat = AVAudioFormat(streamDescription: &format)!
var procID: AudioDeviceIOProcID?
status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, tapQueue) { _, input, _, _, _ in
    guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input,
                                        deallocator: nil) else { return }
    sink.consume(buffer)                    // copy before returning; buffer is only valid here
}
status = AudioDeviceStart(aggregateID, procID)
// stop: AudioDeviceStop, AudioDeviceDestroyIOProcID,
//       AudioHardwareDestroyAggregateDevice, AudioHardwareDestroyProcessTap
```

Tap format for one `afplay` process on the built-in speakers: **48 000 Hz, 2 channels, 32-bit float, interleaved**
(`kAudioTapPropertyFormat`, CHECKED in the no-key run; the format is reported even when the content is silenced). The
same format was reported in session 1 on the built-in speakers.

### Per call app

Installed on 2026-11-22 (CHECKED with `mdfind kMDItemCFBundleIdentifier` and each `Info.plist`; nothing in
`~/Applications`):

| App | Path | Bundle id | Version |
|---|---|---|---|
| Zoom | `/Applications/zoom.us.app` | `us.zoom.xos` | 7.2.5 (90525) |
| Microsoft Teams | `/Applications/Microsoft Teams.app` | `com.microsoft.teams2` | 26289.204.5281.6363 |
| Google Chrome | `/Applications/Google Chrome.app` | `com.google.Chrome` | 158.0.8127.37 |
| FaceTime | `/System/Applications/FaceTime.app` | `com.apple.FaceTime` | 36 |

Teams desktop runs its UI in `Microsoft Teams WebView.app` (an Edge WebView2 helper) beside the main `MSTeams` process
(CHECKED, `pgrep -lf`). Which of these owns the call audio is not measured.

Version 1 uses the global tap (all sound that the Mac plays), so the owning process matters less. These rows stay for
the later tap for one app.

| App | Owning audio process | Tap has only call sound | Other tab or app leaks | Far voice in Me track on speakers (dB) | Survives output device change | Bundle-id tap follows restart |
|---|---|---|---|---|---|---|
| Zoom desktop | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) |
| Microsoft Teams desktop | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) |
| Google Meet in Chrome | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) (second tab) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) |
| Teams on the web in Chrome | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) |
| FaceTime | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) | not measured (morning hand check) |

Reason for every "not measured": a real call needs a person at both ends (capture check session 2).

### Tap behaviour after the grant

| Item | Result |
|---|---|
| Tap format on the built-in speakers | 48 000 Hz, 2 channels, float32, interleaved (session 1, CHECKED) |
| Tap format with AirPods in call mode | The tap said 48 000 Hz, but the real rate was 24 000 Hz (session 1, CHECKED; see the rate row) |
| Second sound source leaks into a per-process tap | not measured (morning hand check). The global tap takes all sound by design |
| Sample count against wall time over 10 min (drift) | not measured (morning hand check). Session 1 measured 24,007 frames per wall second on AirPods over about 66 s of sound |
| Playback stays audible (`muteBehavior = .unmuted`) | not measured (morning hand check). Session 1: with voice processing off, the volume was normal |
| System recording indicator shown | not measured (morning hand check) |

## Verification

```bash
swift build -c release                          # in Spikes/meetings/capture, 0 errors
./make_app.sh && codesign --verify --deep --strict dist/MeetingCaptureSpike.app
codesign -dvvv dist/MeetingCaptureSpike.app     # CDHash, Signature=adhoc
footprint -p <localspeechrecognition pid>       # Footprint, neural (nofootprint)
/usr/bin/log show --info --debug --predicate 'process == "tccd"' --last 5m   # use /usr/bin/log: zsh has a `log` builtin
```

## Related code, ADRs, and phases

- The decision about meeting capture and on-device speech
  ([`0048-meeting-capture-and-on-device-speech.md`](../decisions/0048-meeting-capture-and-on-device-speech.md)): the
  capture rules and the open items.
- The decision about Meetings scope, app-data storage and agent access
  ([`0047-meetings-scope-app-data-storage-and-agent-access.md`](../decisions/0047-meetings-scope-app-data-storage-and-agent-access.md)).
- The Meetings phase ([`meetings.md`](../plans/phases/meetings.md)).
- Microphone listing rule: [`microphone-permission-listing.md`](microphone-permission-listing.md).
- Bundle and signing: [`build-and-run.md`](build-and-run.md),
  [`app-variants-and-state-isolation.md`](app-variants-and-state-isolation.md).
- The speech spike results and the capture check brief are in the primary checkout under `.rafu/` (not tracked).
- Code pattern for a `nonisolated` tap block: `Sources/RafuApp/Voice/VoiceAudioIO.swift` (`installTap`).
