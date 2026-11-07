# GPT-Live protocol and the Rafu Voice audio path

- **Applies to:** `Sources/RafuCore/Voice/**`, `Sources/RafuApp/Voice/**`, and
  any change to the voice socket, audio engine, push-to-talk key, or voice tool
  surface ([ADR 0035](../decisions/0035-voice-through-gpt-live.md)).
- **Last verified:** protocol facts 2026-11-07 against the live service with
  the user's key (Phase 0 spike, native Swift `URLSessionWebSocketTask`).
  Implementation facts 2026-11-07, Apple Swift 6.4.2 (swiftlang-6.4.2.1.9),
  macOS 27 SDK 27.2, deployment target macOS 15. Phase 1b facts the same
  day and toolchain. The microphone, echo cancellation, spoken check-in,
  spoken confirm and the global hot key at run time are **not** verified yet
  (manual checks below).

## Rule or observed behaviour

### Connection

- URL `wss://api.openai.com/v1/live/sessions`, no query. Header
  `Authorization: Bearer <key>` and nothing else.
- The first message is `session.start` with `event_id` and a `session` object.
  **Unknown fields are rejected.** The working shape, which
  `VoiceSessionConfig` encodes with sorted keys:

  ```json
  {"type":"session.start","event_id":"evt_x","session":{
    "model":"gpt-live-1","instructions":"…",
    "audio":{"output":{"voice":"marin"}},
    "delegation":{"type":"responses","responses":{
      "model":"gpt-6.1-terra","instructions":"…","tool_choice":"auto",
      "tools":[{"type":"function","name":"note_create","description":"…",
        "parameters":{"type":"object","properties":{…},"required":[…],
        "additionalProperties":false}}]}}}}
  ```

- `audio.output.voice` defaults to `marin`; `delegation` defaults to
  `{"type":"client"}`. Audio is fixed at `audio/pcm`, 24 000 Hz, mono, PCM16
  little-endian, base64; `session.started` echoes it.
- `session.started` arrives 1.1–1.4 s after connect (median ~1.2 s). Rafu
  waits at most 10 s.
- Close: send `session.close`, wait for `session.closed` (0.5–1 s measured);
  Rafu waits at most 15 s, then drops the socket.

### Events

| Event | When | Fields |
|---|---|---|
| `session.started` | 1.1–1.4 s after connect | `client_event_id`, `session{id, expires_at, model, instructions, audio, delegation, status, input}` |
| `session.output_audio.delta` | continuous from ~0.8 s after start until close | `delta` only (no `start_ms`/`end_ms`, despite the docs); 100 ms = 4800 bytes per event |
| `session.input_transcript.delta` | 1–3 s behind the audio | `delta, start_ms, end_ms` |
| `session.output_transcript.delta` | 0.2–0.3 s after the audio | `delta, start_ms, end_ms` |
| `session.delegation.created` | ~1 s after speech end | `offset_ms, delegation{id, type, target, response_id}` |
| `response.event` | after delegation | `delegation_id, event{type, …}`: a full Responses event, often with large reasoning blobs and config echoes |
| `session.commentary.appended` | 0.8 s after `commentary.append` | `client_event_id, start_ms, end_ms` |
| `session.updated` | 230–360 ms after `session.update` | `client_event_id, session` |
| `session.usage.updated` | about every 15 s | `usage.seconds` (float), `context_window.usage_ratio` |
| `session.closed` | after `session.close` | `reason`, `usage.seconds` (**int**), `session` |
| `error` | on a refused command | `error{type, code, message, param, client_event_id}` |

`VoiceLiveServerEvent` keeps only what Rafu uses. Nested `response.event`s
other than `response.output_item.done` with `item.type == "function_call"` and
`response.completed` decode to `.other` and are dropped.

### Tool flow (mandatory order)

1. `response.event` / `response.output_item.done` with a `function_call` item
   gives `call_id`, `name`, `arguments` (a JSON string).
2. Rafu sends `response.item.create` with
   `{"type":"function_call_output","call_id":…,"output":…}`.
3. Rafu sends `response.create`. **It is mandatory**: without it the model only
   says "Okay." It may be sent eagerly; Rafu sends one per finished response,
   after every call of that response answered (correct for "make three
   terminals").

### Audio

- In: 20 ms chunks (960 bytes) at real-time pace, no acknowledgement.
- Out: real-time paced, continuous, **silence is real zero samples**. Audible
  speech needs an RMS check: 150 on the Int16 scale (Phase 0).
- There is no "output done" and no "interrupted" event. A barge-in stopped the
  server's audio ~1.4 s after the first chunk; the app must flush its own
  player on local speech.
- Turn-end detection is server-side only; no VAD setting is documented.

### `session.update`

- Replacing the **whole** `delegation` object works (tools, tool choice,
  instructions, backend model) and applies on the next turn.
- A partial nested patch fails: `missing_required_parameter:
  session.delegation.type`.
- `delegation.type` is immutable (`immutable_field_update`); `instructions`,
  `audio` and `model` give `unknown_parameter`. The voice cannot change after
  start.

### Accepted values

- Voices (all 25 accepted): marin, cedar, alloy, verse, quartz, ripple,
  vesper, willow, stone, gleam, meridian, bossa, tempo, beacon, delta, cinder,
  nuri, juni, flitz, brise, sillage, nira, harema, shida, noeul. A fake name
  fails with a misleading `forbidden` / "Voice session access denied.", so the
  picker offers only these.
- Backends at `session.start`: `gpt-6.1-terra` and `gpt-6-luna` exercised end
  to end; `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6-astra` accepted at start only.
  `gpt-live-transcribe` and unknown models fail with
  `responses_validation_failed`.
- The `decisions` delegation type exists (schema leaked through errors) but
  delivered nothing in 25 s; it bills idle time. Not used.

### Latency and cost

- Speech end → spoken tool confirmation: Terra median 4550 ms, Luna 4710 ms
  (n=6 each). Speech end → function call: Terra 2182 ms, Luna 2679 ms. The
  "Okay." filler arrives at ~1.3 s. Build UI feedback for the ~4.5 s gap.
- $0.05 per minute, billed per second, for the whole open session: idle
  costs the same as talking. Backend tokens (~900 in, 10–60 out per turn) are
  negligible. `expires_at` is ~2 h after start.

### Implementation nuances found while building Phase 1a

- **Audio blocks are non-Sendable and run on audio threads.**
  `AVAudioNodeTapBlock`, `AVAudioSourceNodeRenderBlock` and
  `AVAudioConverterInputBlock` are `NS_SWIFT_NONSENDABLE`. In the
  default-`MainActor` `RafuApp` target a closure literal written inside a
  main-actor method is main-actor isolated, and calling it on an audio thread
  traps at run time. Build those closures in `nonisolated static` functions
  (`VoiceAudioIO.makeSource`, `installTap`) and give them only
  `nonisolated` helpers (`VoiceCaptureFramer`, `VoicePlaybackRing` with
  `Atomic` indices).
- **A `nonisolated` class that conforms to a main-actor protocol** gets its
  witnesses inferred main-actor; its own nonisolated code (a `deinit`, a
  helper) then cannot call them. Keep the engine owner on the main actor and
  isolate only the closures.
- **One engine for both directions.** Voice processing (echo cancellation) on
  the input node needs the playback on the same engine. Consequence: the
  macOS microphone indicator is on for the whole open session; frames are captured
  only while the key is held or the session is latched. `setVoiceProcessingEnabled(true)` may
  fail on some devices; Rafu then runs without it and disables barge-in
  (Rafu's own voice from the speakers would cut itself).
- **Capture starts at the key press, not at `session.started`.** The socket
  needs ~1.2 s; a push-to-talk user speaks at once. The capture stream buffers
  the newest 2 s (100 frames) and is sent after `session.started`, even when
  the key was already released. Each capture stream has one sender, chained
  after the previous one, so the socket always sees `unmute`, frames, `mute`
  in that order; a `mute` never overtakes speech.
- `installTap(onBus:bufferSize:format:block:)` is deprecated in the macOS 27
  SDK in favour of a throwing variant that exists only on macOS 27. With the
  macOS 15 deployment target there is no warning; switch when the floor moves.
- **Receive loop without a task.** `AsyncStream(unfolding:)` around
  `URLSessionWebSocketTask.receive()` is pull-driven: no receive task exists,
  so nothing outlives the consumer, and a transport error ends the stream.
  The spike's `Task.detached` loop is not needed.
- **`NSEvent` local monitor.** Do not wrap the handler in
  `MainActor.assumeIsolated { … return event }`: `NSEvent` is not `Sendable`
  and the value cannot leave that closure. Write the handler directly, as the
  rest of Rafu does.
- **⌃⌥Space** is macOS's "Select next source in Input menu" when more than one
  input source is enabled; the system then takes the chord before Rafu. The
  menu item uses ⌃⌥⇧Space so it never competes with push-to-talk.

### Implementation nuances found while building Phase 1b

- **Carbon hot key from Swift 6.** `import Carbon.HIToolbox` compiles on this
  toolchain with no package change. `InstallEventHandler` on
  `GetApplicationEventTarget()` for `kEventHotKeyPressed` and
  `kEventHotKeyReleased`, and `RegisterEventHotKey` on
  `GetEventDispatcherTarget()`, give press and release in any app with no
  Accessibility permission. The handler is a file-private `nonisolated func`
  (a closure literal in the default-`MainActor` target fails the
  `@convention(c)` conversion, as with FSEvents); Carbon calls it on the main
  thread, so it enters the main actor with `MainActor.assumeIsolated`. Match
  the event by its `EventHotKeyID.signature` ("RfVc"). Runtime press/release
  in another app is a manual check.
- **Detecting the input-source collision.** Read
  `CFPreferencesCopyAppValue("AppleSymbolicHotKeys", "com.apple.symbolichotkeys")`.
  Ids 60 and 61 are "previous" and "next input source"; each entry is
  `{enabled, value: {parameters: [char, keyCode, modifiers]}}` with
  `NSEvent.ModifierFlags` raw values (⌃⌥ = `0xC0000`). A missing "61" means
  the default, which is ⌃⌥Space and on. The shortcut only acts when
  `TISCreateInputSourceList` (keyboard sources, select-capable) has more than
  one entry, so Rafu shows the notice only then.
- **Confirm card and the call queue.** Voice tool calls run one at a time, in
  order. A sensitive call waits on the card inside that queue, so
  `voice_confirm` / `voice_cancel` bypass the queue and resolve the waiting
  continuation directly; otherwise the answer would wait behind the call it
  answers until the 60 s timeout. The session clock does not run while a card
  waits (the card's own timeout ends it). Whether GPT-Live starts a second
  delegation while the first waits for a function output is unverified; the
  card works by click regardless.
- **`RafuPopupPresenter.presentSheet` returns nothing.** Its content closure
  receives the dismiss closure; keep it in a small box so a spoken answer or
  the timeout can close a card the user did not click.
- **Engine restart.** Stopping the engine (`stopAll`) and building a new one
  (`startPlayback`) is how a quiet session puts the microphone indicator out;
  the next press, a delegation, or the first audible delta restarts it. While
  stopped, the server's continuous silence deltas are dropped, not queued.
  Measured output-only restart cost is below (Measurements).
- **Source-policy scan is a substring match.** `VoiceSourcePolicyTests` bans
  the text `TimelineView` anywhere in `Voice/`, so a type named
  `VoiceTimelineView` fails it. The popover is `VoiceTimelinePopover`.
- **Quit.** `applicationShouldTerminate` already replies later; voice chains
  `closeForQuit(limit: 2 s)` before the persistence flush. A watchdog drops
  the socket at the limit, so a `send` that never returns cannot hold quit.
  `applicationWillTerminate` calls the synchronous `terminateNow()`, which
  keeps a reference to the transport because the client actor cannot be
  awaited there; `URLSessionWebSocketTask.cancel(with: .normalClosure)` sends
  the close frame.
- **Spoken check-in is unverified.** `session.commentary.append` without a
  `delegation_id` was tested only under client delegation. Under Responses
  delegation Rafu sends it with the key omitted; on an `error` reply only the
  check-in glyph shows. Record the manual result here.
- **Hardened runtime.** A notarized build needs the
  `com.apple.security.device.audio-input` entitlement. Rafu Lightning is
  ad-hoc signed without hardened runtime and needs only
  `NSMicrophoneUsageDescription` (added in `script/build_and_run.sh`).

## Why it matters

The server rejects unknown fields, refuses partial updates, needs a manual
`response.create`, and bills idle time; each of these silently breaks voice or
costs money if forgotten. The audio-thread isolation trap compiles cleanly in
some shapes and crashes only with a real microphone.

## Reproduction or evidence

- Phase 0 spike (outside the repository, not committed): `run.sh <name>
  converse --delegation responses --backend gpt-6.1-terra --utt 1`; logs
  `m-*.log` hold the measured runs. It read the key from its own Keychain item;
  Rafu reads only the AI provider store.
- Phase 1a tests drive `VoiceSession` with `ScriptedLiveTransport` and
  `FakeVoiceAudio` (no network, no microphone).

## Verification

```bash
swift test --filter Voice
rg -n "print\(|NSLog\(|Logger\(|os_log|TimelineView|makeKey\(" Sources/RafuApp/Voice Sources/RafuCore/Voice
rg -n "Authorization" Sources/RafuApp/Voice     # only VoiceLiveTransport.swift
./script/build_and_run.sh --verify              # NSMicrophoneUsageDescription staged
plutil -extract NSMicrophoneUsageDescription raw "dist/Rafu Lightning.app/Contents/Info.plist"
```

Manual (Rafu Lightning, real microphone): see
[`voice-control.md`](../plans/phases/voice-control.md) "Manual checks".

### Measurements (Phase 1b)

Measured 2026-11-07 on this 8 GB Mac, macOS 27, Swift 6.4.2, with no GUI
input (agents never speak or click; ADR and AGENTS.md rules).

- **Release bundle: not built.** `script/build_and_run.sh` stages only the
  debug configuration (it runs `swift build` without `-c release`), and a
  release build of the whole app on this machine would hold the build lock
  for many minutes during the gates. The numbers below are Debug; the
  session numbers need the user.
- **Idle, Debug, staged Rafu Lightning** (`./script/build_and_run.sh
  --verify`, no workspace interaction): `top -l 6 -s 3 -pid <pid> -stats
  pid,cpu,mem` showed 0.0 % CPU for five samples and 0.7 % on the sixth;
  `vmmap --summary` physical footprint 77.2 MB (peak 103.7 MB during launch).
  Voice adds nothing to idle by construction: no engine, socket, task or
  timer before the first press; the Carbon hot key and the key monitor are
  passive registrations.
- **Engine restart cost (output-only lower bound).** A standalone
  `AVAudioEngine` with one `AVAudioSourceNode` → main mixer, built,
  prepared and started 8 times in one process (`swiftc -O`, no input node,
  so no microphone prompt and no voice processing): first start in a fresh
  process 93 ms (2.56 s on the very first run after the audio server was
  cold), warm restarts median 17.5–18.2 ms, max 19.4 ms. Rafu restarts a
  warm engine, so the output side costs about 18 ms; voice processing on
  the input node adds an unmeasured amount (manual check 13 in
  `voice-control.md` asks whether a first word is clipped).
- **Open session (to do, manual).** Process name is `RafuLightning` (no
  space; `pgrep -x 'Rafu Lightning'` finds nothing). With a session latched
  and silent, then while talking:

  ```bash
  P=$(pgrep -x RafuLightning)
  top -l 10 -s 2 -pid "$P" -stats pid,cpu,mem
  vmmap --summary "$P" | grep -i "physical footprint"
  ```

  Budget: session ≤ +25 MB over idle, listening ≤ 8 % CPU. For a Release
  number, build with `swift build -c release --product RafuApp` and run the
  same commands against that binary inside a staged bundle; the script has
  no release mode today.

## Related code, ADRs, and phases

- `VoiceLiveEvents.swift`, `VoiceSessionConfig.swift`, `VoiceToolSchema.swift`,
  `VoiceAudioLevel.swift` (RafuCore); `VoiceLiveTransport.swift`,
  `VoiceLiveClient.swift`, `VoiceAudioIO.swift`, `VoiceSession.swift`,
  `VoiceHotkey.swift`, `VoiceConfirm.swift`, `VoiceTimelinePopover.swift`
  (RafuApp); the quit hooks in `App/ExternalOpenRequests.swift`.
- [ADR 0035](../decisions/0035-voice-through-gpt-live.md),
  [`voice-control.md`](../plans/phases/voice-control.md),
  [`concurrency.md`](concurrency.md),
  [`motion-gate-and-idle-cpu.md`](motion-gate-and-idle-cpu.md).
