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
   tool for voice (unlike the MCP rule), from Phase 2. Phase 1a answers every
   sensitive call with `needs_phase_2`.
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

### ADR 0026 amendment (Phase 2 wording)

A voice `terminal_send` or work order counts as the user's consent after a
Confirm card in Ask mode, or by a standing Allow or "Always allow" grant on
that Ensemble. Until Phase 2 ships, voice never types into a terminal.

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
- The macOS microphone indicator is on while a session is open, because one
  engine carries echo cancellation for both directions; audio is captured
  only while the key is held or the session is latched.
- A hardened-runtime (notarized) build will need the
  `com.apple.security.device.audio-input` entitlement; Rafu Lightning is
  ad-hoc signed without hardened runtime and needs only
  `NSMicrophoneUsageDescription`.

## Revisit trigger

- The persona swap through `session.update` proves unclean mid-delegation:
  then a second session per persona.
- Terra stops being accepted as a delegation backend: fall back to Luna.
- OpenAI ships a client-secret flow for Live, or a Swift SDK.

## Related

- Code: `Sources/RafuCore/Voice/`, `Sources/RafuApp/Voice/`,
  `Sources/RafuApp/Canvas/Integration/CanvasAgentActions.swift` (voice caller
  name), `CanvasAgentProvenance.swift` (voice badge).
- Plan: the voice VPLAN (revision 3, outside the repository) and
  [`voice-control.md`](../plans/phases/voice-control.md).
