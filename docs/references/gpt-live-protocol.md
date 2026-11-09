# GPT-Live protocol and the Rafu Voice audio path

- **Applies to:** `Sources/RafuCore/Voice/**`, `Sources/RafuApp/Voice/**`, and
  any change to the voice socket, audio engine, push-to-talk key, or voice tool
  surface ([ADR 0035](../decisions/0035-voice-through-gpt-live.md)).
- **Last verified:** protocol facts 2026-11-07 against the live service with
  the user's key (Phase 0 spike, native Swift `URLSessionWebSocketTask`).
  Implementation facts 2026-11-07, Apple Swift 6.4.2 (swiftlang-6.4.2.1.9),
  macOS 27 SDK 27.2, deployment target macOS 15. Phase 1b facts the same
  day and toolchain. The "stuck on Thinking" facts 2026-11-09, same
  toolchain, by tests with fakes. The microphone, echo cancellation, spoken check-in,
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

Close reasons seen: `close_requested` (the answer to Rafu's `session.close`)
and `expired` (the server ended a session by itself 30 s after start, in a
session that sent no input audio; the cause is unconfirmed, so recheck after
the capture fix 56ef2fd). Rafu shows any server-started close other than
`user` and `close_requested` as "The voice service closed the session
(<reason>)." in the status item (Voice off, with Dismiss); the reason is cut
to 40 plain characters.
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
- **Turn voice processing on after the graph exists (verified 2026-11-09,
  macOS 27, MacBook Air built-in mic and speakers, Swift 6.4.2).** Calling
  `inputNode.setVoiceProcessingEnabled(true)` on a fresh `AVAudioEngine`
  *before* `attach(source)` / `connect(source, to: mainMixerNode)` succeeds,
  but the output hardware format then reads 0 ch / 0 Hz and `start()` throws
  `com.apple.coreaudio.avfaudio -10875` (`PerformCommand(*outputNode,
  kAUInitialize)`). The session showed "Audio is unavailable". Building the
  graph first and then enabling voice processing starts cleanly (output
  2 ch / 48 kHz). Tapping or connecting the input node first does not help.
  With voice processing the input node reports 9 channels at 48 kHz (all
  nine carry the same processed signal). **An `AVAudioConverter` from that
  9-channel format to 24 kHz mono PCM16 writes only zeros**, with
  `downmix = true` (`channelMap [0]`) or false (`channelMap [-1]`), although
  the raw channels carry speech; GPT-Live then hears silence, never detects
  speech, and the session goes to "Still there?" with an empty timeline.
  `VoiceCaptureFramer` therefore copies channel 0 into a preallocated mono
  Float32 buffer and converts that (measured: converted RMS 0.006–0.014 while
  `say` played, against 0.0000 before); `VoiceCaptureFramerTests` covers 1,
  2 and 9 channels. `VoiceAudioIO.startPlayback`
  builds the graph first and, when the engine still does not start, builds a
  new engine without voice processing (barge-in off). Voice writes no logs
  (`VoiceSourcePolicyTests`); the only report is the status-item tooltip
  ("Rafu voice: <reason>"). The timeline now stays after close (it is
  cleared when the next session opens), so the popover shows the last
  session; ask the user to hover over "Voice off". Reproduce with a standalone `swiftc -O`
  program that enables voice processing before and after connecting an
  `AVAudioSourceNode` to the main mixer.
- **Capture starts at the key press, not at `session.started`.** The socket
  needs ~1.2 s warm, but much more on the first open after launch (see
  "Stuck on Thinking" below). The capture stream buffers the newest 15 s
  (`VoiceAudioIO.bufferedFrames` = 750 frames, about 720 KB, freed when the
  stream ends) and is sent after `session.started`, even when the key was
  already released. It was 2 s (100 frames) until 2026-11-09. Each capture stream has one sender, chained
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
- **A spoken confirmation counts only in a later user turn.** A single
  backend response can hold a sensitive call and `voice_confirm` together.
  Rafu counts `session.delegation.created` and accepts `voice_confirm` only
  from a turn that started after the card appeared (`not_heard` otherwise);
  `voice_cancel` counts in any turn. Residual risk, accepted: a latched
  session can get a server-detected turn on noise.
- **`parallel_tool_calls: false`** is sent inside `delegation.responses`.
  Verified 2026-11-07: the server accepts it and `session.started` echoes
  `"parallel_tool_calls":false` (spike probe `probes/ptc.json`). The server
  rejects unknown fields, so if `session.start` starts failing with
  `responses_validation_failed`, this key is the first suspect. The turn rule above is
  the gate, not this flag. `VoiceDelegationConfig.parallelToolCalls = nil`
  omits it.
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
- **Agent updates reuse the commentary event (2026-11-10).** Rafu sends the
  finished-or-waiting sentence of an agent terminal as
  `session.commentary.append` with no `delegation_id`, like the check-in. Same
  caveat: unverified under Responses delegation. An `error` reply to it is
  swallowed (`checkInPending`), so the user hears nothing and sees no error;
  the timeline row "Agent update" and the debug transcript entry
  `agent_update` still show what Rafu tried to say. Audio that follows within
  15 s of the send does not reset the silence clock. Record the manual result
  (voice-control checks 28 to 30) here. Tests: `VoiceAgentUpdatePolicyTests`,
  `VoiceAgentUpdateSessionTests` (fake source, scripted transport).
- **Hardened runtime.** A notarized build needs the
  `com.apple.security.device.audio-input` entitlement. Rafu Lightning is
  ad-hoc signed without hardened runtime and needs only
  `NSMicrophoneUsageDescription` (added in `script/build_and_run.sh`).

### Debug transcript and argument cleanup (2026-11-09)

Verified 2026-11-09, same toolchain, by `VoiceDebugTranscriptTests` and
`VoiceArgumentsAndTranscriptTests` (no live run yet; manual check 17).

- **The backend fills optional fields.** In a live session the user said
  "start a Claude session"; GPT-Live sent `terminal_create` eight times with
  `invalid_arguments`, then fell back to `node_create` + `terminal_start` (a
  plain shell). The model sends `""` or `null` for optional fields
  (`prompt: ""` is refused, `title: ""` too), says the agent as
  `"Claude Code"` (no such key in `CanvasAgentLaunch.executables`), and may
  send an absolute `cwd` (refused: only workspace-relative paths).
  `VoiceToolExecutor.cleanedArguments` fixes this **in the voice path only**,
  before `CanvasAgentToolCall.parse`: it drops `NSNull`, drops empty or
  blank strings except `text`, `markdown` and `source` (an empty body has
  its own meaning), drops an empty `command`, maps agent aliases (`claude
  code`, `claude-code`, `claude_code`, `claudecode` → `claude`; `codex cli`
  → `codex`; `gemini cli` → `gemini`; `cursor agent` → `cursor-agent`; a
  known name in another case is lowercased), and makes an absolute or `~`
  `cwd` relative when it is inside `session.rootURL` (string work only; the
  equal root gives `.`). `CanvasAgentActions.startingFolder` still resolves
  symlinks and checks containment. MCP `parse`/`validate` are unchanged.
- **Failure text on the timeline.** `VoiceToolOutcome.message` carries
  Rafu's own error message; the tool row reads `code: message` (for example
  `invalid_arguments: Invalid value for "width".`), cut to 120 scalars.
  `summary` stays the code, so tests that assert it still hold.
- **Voice Timeline capsules.** (`docs/references/voice-presence.md` does not
  exist in this tree, so the notes live here.) The popover shows capsules in
  session order, not five lanes. Pure grouping is
  `VoiceTimelineGrouping.items(events:sessionOpen:)` in RafuCore: You and
  Rafu rows stay top level; tool and board rows go under a delegation by
  `delegationID` when set, else by time (from one delegation's start to the
  next). `VoiceSession` does not set `delegationID` on tool rows and never
  finishes a delegation row, so the end of a delegation is inferred: its last
  step's end, the next delegation's start, or the latest known time when the
  session is closed; it is running while the session is open and any step is
  open (or it has no steps yet and no newer delegation). A step that
  finishes after its group ended makes the group run again.
  `VoiceTimeline.finish(_:endMS:detail:outcome:)` takes an optional
  `VoiceTimelineEvent.Outcome` (`.ok`, `.failed`); a row with no outcome shows
  Completed once finished, so the failure pill is right only where the writer
  passes `outcome:`. A group is Failed when any step failed.
  The session's millisecond clock is private, so a running row's "Working
  N s" counts from the newest time the events know plus wall time since the
  popover saw it (`VoiceTimelineClock`); a popover opened long after the last
  event undercounts the gap until the next event. Animation: the ring (20 Hz)
  and `VoicePixelLoader` (8 Hz) each own one `Task.sleep` loop keyed on
  "running and `\.rafuMotionAllowed` and not Reduce Motion"; the elapsed text
  redraws at 4 Hz from one popover loop keyed on "a group is running and
  `\.rafuMotionAllowed`". No loop runs for a finished timeline. Colours are
  theme tokens only (`accent`, `success`, `error`, `chipBackground`,
  `cardBackground`, `borderSubtle`, text tokens). The ring and loader are
  `accessibilityHidden`; a capsule reads `VoiceTimelineFormat.spoken` plus
  the outcome word, and a running group leaves the seconds out so its label
  does not change 4 times a second. Do not name a type `...TimelineView`: the
  source-policy scan bans that substring.
- **Debug transcript (opt-in).** Settings ▸ Voice ▸ Debugging ▸ "Keep a
  debug transcript" (`voice.debugTranscript`, default off; read when a
  session opens). File: `~/Library/Logs/<Rafu | Rafu Lightning>/Voice/voice-yyyyMMdd-HHmmss-<4 hex>.jsonl`.
  One JSON object per line, sorted keys: `t` (ISO 8601 with fractional
  seconds, the time Rafu recorded the entry) and `type`:

  | `type` | Fields |
  |---|---|
  | `session_opened` | `persona`, `backend`, `voice` |
  | `session_started` | `session_id` |
  | `session_closed` | `reason` (`user`, `idle`, `remote`, `quit`, or the server's reason) |
  | `session_failed` | `reason` (the blob text) |
  | `server_error` | `code`, `message` |
  | `user_said` | `text` (one per user turn: written at `session.delegation.created`, at a pause of more than 1500 ms in the input transcript, or at close) |
  | `rafu_said` | `text` (one per reply: written when the reply audio has been silent for 600 ms, at `response.completed` when no reply audio is playing, at a pause of more than 1200 ms in the output transcript, when the user speaks again, or at close) |
  | `delegation` | `delegation_id`, `target` |
  | `call` | `call_id`, `name`, `arguments` (the raw JSON string) |
  | `call_result` | `call_id`, `name`, `summary`, `message`, `output`, `is_error` |
  | `confirm` | `tool`, `answer` |
  | `audio_engine` | `voice_processing`, `fallback` (the engine with voice processing did not start), `start_ms`, `input_channels`, `sample_rate`; after every engine start |
  | `turn_audio` | `held`, `frames` (sent), `max_rms`, `loud_frames` (≥ 600 RMS), `heard_speech`, `buffered_before_start`, `dropped`, `unmute_ms`, `mute_ms` (ms from the open; -1 = did not happen); one per capture stream, after its `mute` |
  | `silent_turn` | `frames`, `max_rms`, `held_ms`; a held turn that went to Paused (below) |
  | `no_response` | `after_ms` (from the start of Thinking), `had_delegation`; the Thinking limit fired |
  | `capture_failed` | `domain`, `code` (the `NSError` of the second failed tap start) |
  | `truncated` | none; the file reached 2 MiB and nothing follows |

  The audio entries hold numbers and type names only: never audio bytes and
  never words.

  Turn boundaries: `session.input_transcript.delta` and
  `session.output_transcript.delta` carry `start_ms` and `end_ms`; Rafu splits a
  turn when a delta starts more than 1500 ms (user) or 1200 ms (reply) after
  the last `end_ms`. Output transcript deltas trail the audio by 0.2 to
  0.3 s, so `response.completed` does not close a reply that is still audible.
  A pending reply is written before pending user words, which keeps the file
  in speaking order. Without `start_ms` the old rules apply.

  ```bash
  cd ~/Library/Logs/"Rafu Lightning"/Voice
  ls -t | head -1                                        # newest session
  jq -c 'select(.type=="call_result" and .is_error)' "$(ls -t | head -1)"
  jq -r 'select(.type=="user_said" or .type=="rafu_said") | "\(.type): \(.text)"' "$(ls -t | head -1)"
  ```

  Privacy and limits: folder 0700, file 0600; `VoiceOutputScrubber.redactSecrets`
  replaces the specific secret shapes but, unlike `scrub`, not the generic
  40-character token rule, so paths stay readable; each field at most
  16 KiB (`…[truncated N bytes]`); the newest 20 files are kept (about 40 MiB
  at worst). The key, headers and audio never reach `VoiceDebugTranscript`.
- **Transcript ordering and loss.** `record` yields to one `AsyncStream`
  (`.bufferingNewest(1_024)`) from the main actor, so entries stay in order
  and the main actor never waits for the disk; one `@concurrent` drain task
  owns the `FileHandle`. Never a task per write. `terminateNow()` cannot
  await the drain, so the last lines can be lost at quit. Only a stalled
  disk fills the buffer, and then the oldest entries go. GPT-Live has no
  "transcript done" event, so output deltas that arrive after
  `response.completed` are written with the next turn or at close.
- **Source policy.** The new file must not contain the banned logging
  strings or `Authorization`, comments included; the word `Logs` may appear
  only in `VoiceDebugTranscript.swift` (the Settings footer reads
  `VoiceDebugTranscript.displayPath()`).

### Stuck on Thinking after the first press (2026-11-09)

Verified 2026-11-09, same toolchain, by `VoiceSilentTurnTests`,
`VoiceBlobStateTests`, `VoiceCaptureFramerTests` and
`VoiceDebugTranscriptTests` (fakes; no live run yet, manual checks 25–27 in
`voice-control.md`).

- **Symptom.** The first session after launch went Connecting → Thinking at
  once and stayed there; the user said "hey" a few times and nothing
  happened, with the macOS microphone indicator on. Debug transcripts:
  `voice-20261109-180609-a01f.jsonl` open → `session.started` 3.1 s, then
  nothing for about 109 s, close `user`; `voice-20261109-134114-9103.jsonl`
  started in 11.7 s, no `user_said`, server close `expired` after 30 s. The
  next (warm) session started in 2.1 s and worked.
- **Cause.** Connecting → Thinking happens only when the key is held past
  `session.started` and then released (`.holdEnded` from `.listeningHeld`).
  Thinking means the microphone is **off** (`.holdEnded` sets `mic = .off`
  and the tap is removed), so words said while it shows Thinking are never
  captured. With no speech in that hold the server got `unmute`, silence,
  `mute`: no turn, no reply, and nothing ever left Thinking (it had no time
  limit). The engine stays on until the 10 s quiet suspend, so the orange
  indicator stays on too. The 2 s pre-start buffer also lost the start of
  speech on a cold 3.1 s or 11.7 s open.
- **Push-to-talk rule.** Each sender counts speech in its own stream (3
  frames in a row at or above `VoiceAudioFormat.localSpeechRMS`, the barge-in
  rule) and decides only after it sent `mute`, so frames buffered before
  `session.started` count. A **held** stream with no local speech, while the
  blob still shows Thinking with the mic off, and with no server event
  (input transcript, delegation, function call, `response.completed`,
  audible output) since the stream began, sends `.noResponse`: Thinking →
  Paused (latched → Listening). The status-item tooltip and the blob's hint
  read "Hold ⌃⌥Space while you talk, or choose Start Listening.", and one
  Voice-lane row reads "Rafu did not hear you". A latched stream never
  triggers it. Nothing is cancelled on the server: a late reply goes
  Paused → Speaking, a late delegation Paused → Thinking. We chose this over
  "latch on the first press" to keep the microphone under explicit control.
- **Thinking limit (safety net).** `tick(at:)` ends Thinking after
  `thinkingNoHearLimit` (8 s) with no server event, or `thinkingNoReplyLimit`
  (20 s) after a delegation or call result; every server event in the turn
  moves the limit forward. A running call or a waiting Confirm card holds it.
  Rows: "Rafu did not hear anything" (no server event) or "No reply". The
  limit starts on every entry to Thinking because all blob transitions go
  through `VoiceSession.apply(_:)`.
- **Silent capture failure.** `startCapture` used `try?` and returned with
  nothing recorded while the blob showed Listening. It now stops and
  restarts the engine and tries once more; a second failure shows a
  "Microphone did not start" row and a `capture_failed` entry.
  `VoiceAudioIO.startPlayback` still falls back to no voice processing
  silently; `audio_engine.fallback` now records it.
- **Audio-thread counters.** `VoiceCaptureFramer` counts yielded and
  dropped frames (`continuation.yield(_:)` returns `.dropped` when the
  buffer is full) in two `Atomic<Int>` values: the tap thread adds with
  relaxed ordering, the main actor takes them with `exchange(0)`. No lock on
  the tap thread.
- **Not verified.** A 15 s burst sent faster than real time after a slow
  start has not been tried against the server (2 s bursts work).

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
