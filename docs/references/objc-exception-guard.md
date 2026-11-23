# Objective-C exception guard (`RafuObjCSupport`)

- Applies to: the small Objective-C target `Sources/RafuObjCSupport/` and each Swift call site that wraps an
  Objective-C call in `RafuObjCExceptionGuard.perform { ... }`.
- Last verified: macOS 27.2.1, Xcode SDK 27.2, Apple Swift 6.4.2, Apple silicon (2026-11-23). Both test modes passed on
  `main` after the change (4,442 app tests and 1,071 core tests, in parallel and in serial mode).

## Rule or observed behavior

**Why the target exists.** Swift cannot catch an `NSException`. When an AVFoundation call raises one, nothing in Swift
handles it and the whole app aborts. A live crash showed it: a Bluetooth headset was the default input (a browser call
was running), the Automatic microphone rule set the built-in microphone on the input audio unit directly
(`kAudioOutputUnitProperty_CurrentDevice`), `AVAudioEngine` did not see that change, `outputFormat(forBus: 0)` then
disagreed with the hardware, and `installTap` raised. The frames were `AVAudioEngineGraph::InstallTapOnNode`, then
`-[AVAudioNode installTapOnBus:bufferSize:format:error:block:]`, then `MeetingMicrophoneSource.installTap`, then
`start`, then `MeetingRecorder.performStart`. The fix for "Me" removed `AVAudioEngine` from Meetings capture (see
[`meeting-audio-capture.md`](meeting-audio-capture.md)). This target guards the AVFoundation calls that stay.

**The API.** `RafuObjCExceptionGuard.performBlock(_:error:)`, imported in Swift as `perform(_:)` (it throws):

```swift
try RafuObjCExceptionGuard.perform { /* one Objective-C call */ }
```

The Objective-C implementation is `@try { block(); return YES; } @catch (NSException *) { ... return NO; }`. The error
has domain `RafuObjCException` (`RafuObjCExceptionErrorDomain`), code 1, and in `userInfo` the exception name
(`RafuObjCExceptionNameKey`), the reason (`RafuObjCExceptionReasonKey`) and the localized description. The guard does
not log.

**Rules for a guarded block.**

1. **One Objective-C call per block.** Nothing else in the block.
2. **No `defer`, no lock and no `inout` access to class or global state inside the block.** An exception that crosses a
   Swift frame skips that frame's cleanup (`defer`, lock release, `inout` write-back). Under these rules there is no
   cleanup to skip.
3. **After a caught exception, treat the object as bad.** The converter or the engine can be in a bad state. The call
   site reports an error and discards the result; it does not reuse the object.
4. **A captured box can leak after a caught exception.** The small box that carries a result out of the block can leak
   when the exception crosses its frame. This is accepted. The target does not use `-fobjc-arc-exceptions`: ARC gave no
   warning, and the flag would need `unsafeFlags` in `Package.swift` (the brief warned that `unsafeFlags` can break the
   release build of a dependent product).

**The three call sites** (the only places that use the guard):

| Call site | Guarded call | On a caught exception |
|---|---|---|
| `MeetingPCMConverter.convert` in `Sources/RafuApp/Meetings/Capture/MeetingCapturePipeline.swift` | `converter.convert(to:error:withInputFrom:)` | returns false; counted as a converter error |
| `AppleSpeechPCM.buffer` in `Sources/RafuApp/Meetings/Speech/Apple/SystemAppleSpeechAnalyzer.swift` | the `AVAudioConverter` call | returns nil |
| `VoiceAudioIO.installTap` in `Sources/RafuApp/Voice/VoiceAudioIO.swift` | `input.installTap` | `installTap` throws; `startCapture` finishes the continuation, clears `framer` and throws `VoiceAudioError.noInput` |

Voice keeps `AVAudioEngine` because it needs voice processing. The Voice source policy test forbids logs in Voice
sources, so the Voice site logs nothing and adds no stored state.

**Not a general tool.** Do not wrap other calls "to be safe". A guard that hides a fault is worse than a crash with a
report. Add a call site only for an AVFoundation call that can raise from a state that the app does not control (a
device or format that changes under it), and add it to the table above.

## Why it matters

- One uncaught exception in an audio call ended the whole app and the recording with it.
- `swift format` does not read `.m` or `.h` files. Keep the target tiny and review it by hand.

## Reproduction or evidence

- `Tests/RafuAppTests/Meetings/Capture/MeetingObjCExceptionGuardTests.swift`: a block that raises
  `NSInternalInconsistencyException` makes `perform` throw and the process continues; a clean block returns normally.
- A source-policy test in `MeetingCaptureConversionTests.swift` ("Meeting capture source rules") forbids
  `AVAudioEngine`, `installTap(` and `inputNode` under `Sources/RafuApp/Meetings`.

## Verification

```bash
./script/test.sh --filter MeetingObjCExceptionGuard
./script/test.sh --filter "Meeting capture source rules"
./script/build.sh        # 0 warnings expected
```

## Related code, ADRs, and phases

- `Package.swift` (target `RafuObjCSupport`; a dependency of `RafuApp` and `RafuAppTests`),
  `Sources/RafuObjCSupport/include/RafuObjCSupport.h`, `Sources/RafuObjCSupport/RafuObjCExceptionGuard.m`.
- [`meeting-audio-capture.md`](meeting-audio-capture.md) (the crash and the new "Me" path).
- The decision about meeting capture and on-device speech
  ([`0048`](../decisions/0048-meeting-capture-and-on-device-speech.md)).
- The Meetings phase ([`meetings.md`](../plans/phases/meetings.md)).
