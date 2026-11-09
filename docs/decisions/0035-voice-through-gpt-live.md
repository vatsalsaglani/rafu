# 0035. Voice through GPT-Live

- Status: Accepted (user direction), 2026-11-07. Proposed in the voice plan
  (VPLAN revision 3) the same day.
- Amends: [`AGENTS.md`](../../AGENTS.md) (credential sentence),
  [ADR 0025](0025-workspace-canvas-and-app-previews.md) (credential clause),
  [ADR 0026](0026-canvas-live-session-links.md) (Phase 2 wording, below).
- Phase: [`../plans/phases/voice-control.md`](../plans/phases/voice-control.md)
- Reference: [`../references/gpt-live-protocol.md`](../references/gpt-live-protocol.md)

## Context

The user wants to run Rafu's Ensembles by voice: "we'll only use GPT live and
nothing fuzzy speech to text." Rafu is the orchestrator voice. The user decided
on 2026-11-07:

- GPT-Live (`gpt-live-1`) only. No on-device speech-to-text, no Whisper, no
  Realtime API path.
- One persona and one voice by default; separate voices per Ensemble are a
  later opt-in setting.
- Push-to-talk ⌃⌥Space, a latched session (blob click or "stay with me"), a
  silence check-in, and an idle close, all in Phase 1. Spoken replies always.
- Backend `gpt-6.1-terra` by default, with a switch. Voice `marin` by default.
- The terminal output tail is on by default, in Allow mode only.
  Personalization is opt-in.
- A soft cap of $5 a month. macOS 15 floor.
- Credential wording: "Ensemble agents never receive Rafu-held credentials;
  Rafu features may use the user's provider key from Keychain."

Phase 0 measured the protocol from native Swift with the user's key
([`gpt-live-protocol.md`](../references/gpt-live-protocol.md)): the WebSocket
URL and header, the exact `session.start` shape, the event table, the mandatory
`response.create`, the `session.update` rules, 25 accepted voices, and about
4.5 s from the end of speech to a spoken tool confirmation.

## Decision

1. **GPT-Live only, over a WebSocket from Swift.** `URLSessionWebSocketTask`
   with an ephemeral session and `Authorization: Bearer <key>`. 24 kHz mono
   PCM16 in 20 ms frames in; continuous 100 ms deltas out. No new dependency:
   AVFoundation and Security are system frameworks.
2. **Responses delegation.** GPT-Live speaks; the backend model reads the board
   and calls Rafu's tools. The backend defaults to `gpt-6.1-terra`
   (Settings ▸ Voice switches to Luna, Sol, 6.1 Sol or Astra).
3. **One session, one persona by default.** Rafu is the orchestrator. A later
   persona swap uses `session.update` on the whole `delegation` object.
4. **Execution boundary kept, context boundary removed.** The backend gets the
   whole board (every node, link, selection, focus) and, in Allow mode with the
   setting on, scrubbed viewport text of terminals. It gets no file and no
   command tool: every action is an existing board tool, run through
   `CanvasAgentActions.perform` with a voice caller, visible, logged, marked
   "Rafu (voice)" and undoable. Code work goes to a visible Claude or Codex
   terminal (work orders, Phase 2).
5. **Off / Ask / Allow reused, with voice differences.** Off is read-only by
   voice. Ask runs edits at once with an undo notice (the voice actor is the
   user, so there is no question for an edit) and confirms sensitive calls.
   Allow runs everything. A remembered "Always allow" may cover a sensitive
   tool for voice (unlike the MCP rule), from Phase 2. Phase 1a answered every
   sensitive call with `needs_phase_2`; Phase 1b replaces that with the
   Confirm card (decision 9).
6. **Cost and idle.** An open session bills like talking, so a 90 s idle close
   (10 minutes with an open work order) is the net; the $5 monthly soft cap
   stops new sessions, never a running one.
7. **Credentials.** Ensemble agents never receive Rafu-held credentials; Rafu
   features may use the user's provider key from Keychain. Voice reads the
   OpenAI key through the existing AI provider store
   (`KeychainAISecretStore`) into one request header, never into observable
   state, logs, `UserDefaults`, notices or the timeline.
8. **Privacy.** Audio is captured only while the key is held or the session is
   latched, and the blob shows it; what was said while the socket connected is
   sent once it opens. Transcripts live in memory only (the timeline keeps at most 120
   scalars of the user's own words and is cleared on close). The style profile
   holds preferences only, 0600, at most 4 KiB, never synced or exported.

9. **Confirm card for sensitive calls (Phase 1b).** In Ask mode a sensitive
   voice call (`terminal_create` with an agent or command, `terminal_start`,
   `terminal_send`, `node_remove`, `edge_remove`, `export`) waits on one
   `RafuConfirmPopup` sheet (ADR 0033) on the workspace window. The card names
   the Ensemble and the bounded approval summary. Buttons: "Allow Once" (the
   default for a non-destructive call), "Allow for This Session", and Cancel.
   A removal shows one destructive "Remove" button and no session grant;
   Return never removes. The spoken `voice_confirm` / `voice_cancel` resolve
   the same waiting card; a 60 s timeout and closing the session cancel it.
   The backend receives the answer as that call's `function_call_output`
   (`cancelled`, `confirm_timeout`, or the tool result). At most one card
   waits; a second sensitive call meanwhile answers `confirm_busy`. With no
   workspace window to hold the card, the call is refused at once
   (`no_window`) instead of waiting unseen. Allow
   mode runs sensitive calls at once with the "Rafu (voice)" badge and no
   card. Off denies them.
   - **"Allow for This Session"** is a deliberate, small part of the user's
     "Always allow" request: an in-memory grant for one tool on one Ensemble,
     cleared when the voice session closes, never for a removal. The
     persisted "Always allow" needs document persistence and stays Phase 2.
   - **A spoken confirmation counts only in a later user turn.** Rafu counts
     `session.delegation.created` events; `voice_confirm` resolves a card
     only when a backend turn started after the card appeared, so the
     backend can never confirm its own call (for example `node_remove` and
     `voice_confirm` in one response). Otherwise it answers `not_heard`.
     `voice_cancel` counts in any turn, because cancelling is always safe. A
     click on the card is not affected. Rafu also sends
     `parallel_tool_calls: false` in the delegation; the turn rule alone is
     the gate. Accepted residual risk: in a latched session GPT-Live may
     detect a turn on background noise and the backend may then confirm;
     the card stays visible throughout.
   - Voice calls pass the same 30-per-minute limit as an agent
     (`CanvasAgentCenter.admit`) before they run or ask.
   - **Voice may type into any terminal card on the board** after consent
     (Confirm in Ask, Allow), because the user is the actor (user request
     2026-11-07). MCP agents keep the creator rule. Text input still needs an
     agent Rafu knows in that terminal; a `command` still passes
     `CanvasAgentShell.refusal`.
10. **Global push-to-talk (Phase 1b).** ⌃⌥Space is a Carbon
    `RegisterEventHotKey` hot key with press and release events, so it works
    in any app with no Accessibility permission. The local `NSEvent` monitor
    stays as the fallback when registration fails. When macOS's own
    "Select next source in Input menu" owns ⌃⌥Space and more than one input
    source is on, Settings ▸ Voice says so and offers ⌃⌥⇧Space
    (Start Listening). The chord is not configurable in Phase 1.
11. **Microphone indicator and quit (Phase 1b).** A session that is not
    latched stops its audio engine after 10 s with the microphone off, no
    audible reply, no running call and no waiting card; the macOS
    microphone indicator then goes out while the session stays open. The
    next press, a delegation, or audible reply audio restarts it. Quitting
    Rafu sends `session.close` and waits at most 2 s
    (`applicationShouldTerminate`); `applicationWillTerminate` drops a socket
    that is still open, synchronously.

### ADR 0026 amendment (Phase 2 wording)

A voice `terminal_send` or work order counts as the user's consent after a
Confirm card in Ask mode, or by a standing Allow or "Always allow" grant on
that Ensemble. From Phase 1b, voice may type into any terminal card on the
board after that consent, including cards the user made; MCP agents keep the
creator rule. Work orders stay Phase 2.

### Amendment (2026-11-08): `show_view` and argument streaming

[ADR 0036](0036-generated-views-on-the-ensemble-board.md) adds generated views.

- **Tool.** The voice backend gets one tool, `show_view`, for create, replace
  and reset. The spec is flat (`root`, `elements`, `state`) beside `title`,
  `node` and `reset`. A nested `spec` object is accepted as an alias; that call
  does not stream. `view_render` and `view_update` are hidden from voice
  (`hiddenEnsembleTools`).
- **Policy.** Ask runs at once with an Undo notice, because the voice actor is
  the user. Off refuses with the Off message. Allow runs. The call passes the
  same 30-per-minute limit as other voice calls; a streamed call is counted once,
  when its skeleton starts.
- **Server events.** Two nested `response.event` types are now decoded:
  `response.output_item.added` for a `function_call` item, and
  `response.function_call_arguments.delta`.
- **Skeleton first.** The session keeps argument text for `show_view` only until
  it knows the title: the title string, the first spec key (`root`, `elements` or
  `state`), or 512 bytes, whichever comes first. Then it adds a skeleton card
  and pushes the text into a stream that fills the card.
- **Orphan rule.** When a response completes, any started call that never
  received its finished `function_call` event has its skeleton cancelled. The
  finished flag is set by that event, not by the presence of a `call_id`,
  because a started call can carry its `call_id` early.
- **Measurement pending.** Whether GPT-Live sends argument deltas is unverified.
  The timeline row of every `show_view` call shows "deltas: N, size". The user
  reports the number; until then the streaming hand-off stays in the code and the
  card appears on completion if no deltas arrive.

## Alternatives considered

From VPLAN section 17: on-device SpeechAnalyzer plus Foundation Models; the
OpenAI Realtime API; Whisper/WhisperKit; WebRTC (no first-party Swift path,
needs a web view); client delegation as the primary mode (Rafu would own a
planner); a file or command tool in the voice backend (an invisible executor,
no undo, steerable by board text, and the embedded-agent non-goal); a second
session per persona as the default (double cost, two clocks); a separate voice
"Confirm level"; cloud memory or fine-tuning for personalization; a Rafu
server for the key; a wake word or always-on listening.

## Consequences

- Idle time is billed, so a forgotten latched session costs money until the
  idle close. The check-in and pause make the open microphone visible.
- No reconnect in Phase 1: a lost connection ends the session with "Voice
  disconnected"; the user presses the key again.
- The macOS microphone indicator is on while a session's audio engine runs,
  because one engine carries echo cancellation for both directions; audio is
  captured only while the key is held or the session is latched. From Phase
  1b, a session that is not latched stops the engine after 10 quiet seconds,
  so the indicator goes out; a latched session keeps it on, visibly, until
  the pause or the idle close.
- Quit closes the voice session before the persistence flush
  (`closeForQuit` runs first in `applicationShouldTerminate`). When a save
  then fails and quit is cancelled, the voice session is already closed; the
  user presses the key again.
- A Confirm card blocks the voice call queue, so the user's spoken "yes"
  reaches Rafu only when GPT-Live starts a second delegation while the first
  waits for its function output. That is unverified with the real server;
  the card, Escape and the 60 s timeout work regardless.
- A hardened-runtime (notarized) build will need the
  `com.apple.security.device.audio-input` entitlement; Rafu Lightning is
  ad-hoc signed without hardened runtime and needs only
  `NSMicrophoneUsageDescription`.

## Revisit trigger

- The persona swap through `session.update` proves unclean mid-delegation:
  then a second session per persona.
- Terra stops being accepted as a delegation backend: fall back to Luna.
- OpenAI ships a client-secret flow for Live, or a Swift SDK.

## Amendment (2026-11-08): `compose_view`

The voice backend may call `compose_view { prompt, context?, title?, near? }`. Risk `.edit`, the same Off, Ask and
Allow rules as `show_view` (Ask runs at once with an Undo notice; Off refuses; the rate limit applies). It makes a
second provider call type, the OpenAI Decisions API (`POST /v1/decisions`, model `gpt-6-luna`), with the same
OpenAI key from Settings ▸ AI (`KeychainAISecretStore` through `VoiceKeyResolver`). The key is read once per
request inside the `OpenAIDecisionsEvaluator` key provider and goes only into that request's `Authorization`
header; a non-https base URL is refused before the key is read. It runs only when the backend calls it, never as a
fallback after `show_view` validation fails. Ensemble agents in terminals do not have this tool and never receive
the key. See [`voice-compose-view.md`](../references/voice-compose-view.md).

## Amendment (2026-11-09): opt-in debug transcript

The user asked for a transcript log to debug live voice sessions. Settings ▸ Voice ▸ Debugging has a toggle,
"Keep a debug transcript", **off by default**. It is the one exception to the voice no-logging rule. When it is on,
each new voice session writes one JSONL file to `~/Library/Logs/<app name>/Voice/` (`Rafu` or `Rafu Lightning`, so
the two never share a folder): what the user said, what Rafu said, each delegation, and every tool call with its
raw arguments and its result. The file can hold note text, board titles and (scrubbed) terminal lines. It never
holds the OpenAI key, request headers or audio: `VoiceDebugTranscript` never receives them.

Constraints: folder 0700, file 0600; secret shapes (`sk-…`, `Bearer …`, GitHub, Slack and AWS tokens,
`password=…`) are replaced with `[redacted]`; each field at most 16 KiB, each file at most 2 MiB (then one
`truncated` line); Rafu keeps the newest 20 files. It is not a logging API (`VoiceSourcePolicyTests` still bans
them): one ordered `AsyncStream` from the main actor and one `@concurrent` drain task that owns the file. A change
of the setting applies from the next session. See
[`gpt-live-protocol.md`](../references/gpt-live-protocol.md) "Debug transcript and argument cleanup".

## Amendment (2026-11-09): voice has no node on the board

The voice caller's card is synthetic and never on the board (`CanvasAgentCaller.voice`). Voice therefore gets no
`link` property on any tool, and no `x` or `y` on the tools that place a new node (`terminal_create`, `note_create`,
`node_create`, `diagram_build`; `node_update` keeps them to move a node). Rafu places a new node beside the selection
or focus, or `near` a named node. `terminal_create`, `terminal_send` and `edge_create` have voice texts that never
say "your node" (`VoiceToolSchema.voiceDescriptions`); the MCP texts and schemas for agents are unchanged.
`VoiceToolExecutor.cleanedArguments` also drops `link`, and `x`/`y` when both are 0. `send_message` stays declared
and answers "Not available by voice." The voice result for `terminal_create` does not suggest `edge_create`, and
the lease-cap advice tells Rafu to ask the user which terminal to stop. Reason: in the 2026-11-09 live test the
backend sent `"link":true,"x":0,"y":0`; the link failed on the missing node, the node landed at the board origin,
and the model said "my node isn't available".

## Amendment (2026-11-10): agent updates by voice

The user said Rafu does not speak when Codex or Claude Code replies. Decision: while a voice session is open, Rafu
speaks one short sentence, unprompted, when an agent terminal on the shown Ensemble ends a turn, needs approval, or
waits for an answer. Setting `voice.agentUpdates`, **on by default** (Settings ▸ Voice ▸ "Speak when an agent
finishes or needs you"); it includes "needs your approval".

- **Signal: agent hooks, not terminal output.** `AgentActivityStore` folds `Stop`, `PermissionRequest` and
  `Notification` events into `TrackedAgentSession`. It has a new `replyRevision` counter, bumped only when a session
  gets a new reply or starts waiting. `VoiceAgentUpdates` observes that counter with `withObservationTracking`
  (re-armed per change, stopped in `releaseSession`; no polling). Without connected hooks Rafu says nothing and
  Settings ▸ Voice shows a hint. Detecting a quiet terminal tail is out of scope.
- **Rafu writes the sentence.** `VoiceAgentUpdatePolicy` (pure, `RafuCore`) builds "<Agent> in “<title>” is done. It
  says: <first sentence>." from the hook preview, scrubbed with `VoiceOutputScrubber`, at most 120 scalars, and
  dropped when it holds code, a path or a secret. The text goes to GPT-Live as `session.commentary.append`: no
  backend turn, no `response.create`, and no instruction, so a reply text cannot steer the model.
- **Rules.** Speak only when the session is started and latched or paused, no Confirm card waits, no call runs, the
  key is not held, no local speech in the last 1.5 s and no audible reply in the last 600 ms; otherwise the update
  stays queued and the 1 s tick retries. At most one sentence per 10 s (updates merge: "Claude Code in “Build” and
  Codex in “Tests” are done."), queue depth 3 (oldest dropped), 6 a minute, an update older than 2 minutes is
  dropped. Replies that exist when the session opens are not announced.
- **The idle close stays.** Audio of an update does not reset the 90 s silence clock, so updates never keep a
  session open. A user who leaves for more than 90 s no longer hears updates until the next session.
- **Consent.** No new tool, no board change, nothing leaves the Mac that the session did not already send: the
  sentence is the preview the hook already stored. The debug transcript records it as `agent_update`.
- **Open.** `session.commentary.append` is unverified under Responses delegation (see
  [`gpt-live-protocol.md`](../references/gpt-live-protocol.md)). If it fails, a fallback (a `response.create` turn
  with a fixed prompt) must be added; the policy and the gates stay.

## Amendment (2026-11-10): the companion replaces the blob; the status item is a dot

The user approved the floating voice companion (the orb's exact look stays open). Decision:

- **The companion is the window's voice surface.** One overlay per workspace window, at the window root above the
  editor and below sheets, on every tab, fixed while a board pans or zooms (not an `NSPanel`, not in the board
  layer). It shows while a session is open or failed; when idle only with "Keep Rafu on the canvas when voice is
  off" (`voice.companion.keepOnCanvas`, default off). Its corner is remembered per workspace.
- **The orb replaces the blob.** `VoiceBlobView` is removed. The notch wing shows a 20 pt orb; real audio levels
  drive it (input while listening, output while speaking); Thinking turns slowly; every other state is one still
  frame with no task. Colours come only from the active theme palette, custom themes included.
- **The status item is a dot.** A 7 pt dot (filled while open, a ring while idle), the state word in its help text
  and accessibility value; the menu with every voice action stays.
- **One speech card and an icon-only pill.** The card shows live captions (in memory, 160 scalars, cleared on
  close), the state's words, the newest spoken agent update, the inline Confirm, or the error. ✓ and ✕ resolve the
  same Confirm gate as the sheet, once (`answerConfirm`); a spoken confirmation still needs a later backend turn.
  The Rafu menu keeps the words and shortcuts (Approve has no shortcut for a removal, per ADR 0033).
- No protocol or state-machine change. Details: [`voice-presence.md`](../references/voice-presence.md).

## Related

- Code: `Sources/RafuCore/Voice/`, `Sources/RafuApp/Voice/`,
  `Sources/RafuApp/Canvas/Integration/CanvasAgentActions.swift` (voice caller
  name), `CanvasAgentProvenance.swift` (voice badge).
- Plan: the voice VPLAN (revision 3, outside the repository) and
  [`voice-control.md`](../plans/phases/voice-control.md).
