# Rafu Voice — GPT-Live control of the Ensemble

- Status: **Phase 1a implemented** on `voice/phase-1a` (2026-11-07), awaiting
  merge and the manual microphone checks below. Phase 1b starts from that merge.
- Decision: [ADR 0035](../../decisions/0035-voice-through-gpt-live.md).
- Reference: [`gpt-live-protocol.md`](../../references/gpt-live-protocol.md).
- Plan: the voice VPLAN, revision 3 (kept outside the repository). Phase 2
  (Ensemble personas, hand-off, sensitive tools with Confirm and grants, work
  orders, personalization learning) and Phase 3 (separate voices, multi-window
  polish, barge-in timing, triggers) follow the VPLAN.

## Owned paths

- `Sources/RafuCore/Voice/**`, `Sources/RafuApp/Voice/**`,
  `Tests/RafuCoreTests/Voice/**`, `Tests/RafuAppTests/Voice/**`.
- Small named edits: `CanvasAgentActions.swift` (voice caller name),
  `CanvasAgentProvenance.swift` (voice vendor, optional `cli`, `symbol`),
  `CanvasCardChrome.swift` (badge symbol), `RafuTerminalView.swift` and
  `WorkspaceTerminalController.swift` (`recentOutputLines`),
  `NotchCompanionView.swift` (blob in the left wing), `WorkspaceStatusBar.swift`
  (voice item), `SettingsPaneNavigation.swift` and `RafuSettingsView.swift`
  (Voice pane), `RafuAppCommands.swift` (menu items), `ExternalOpenRequests.swift`
  (hotkey install), `script/build_and_run.sh` (microphone usage string),
  `SettingsPresentationTests.swift`.
- No change: `Package.swift`, `Sources/RafuCore/CanvasBridge/*`,
  `CanvasLiveBridge.swift`, `Sources/RafuApp/Conductor/**`,
  `Sources/RafuApp/AI/**`.

## Split

### Phase 1a (done on the branch)

- RafuCore pure layer: wire events and config, tool schema generated from
  `CanvasAgentToolCatalog.definitions`, the Rafu persona, voice policy, target
  resolver, blob state machine, silence and idle clock, cost meter, output
  scrubber, timeline, board context, style-profile schema, audio level math.
- RafuApp: `VoiceSession` (lifecycle, event loop, function calls,
  `response.create` rule, timers), `VoiceLiveClient` over a transport protocol,
  `URLSessionWebSocketTransport`, one-engine `VoiceAudioIO`, local push-to-talk
  key (Rafu frontmost), voice caller and executor for read and edit tools,
  `voice_undo`, `voice_latch`, `view_zoom`, `view_tidy`, and the orchestrator
  tools `list_ensembles`, `ensemble_open`, `ensemble_create`,
  `cross_board_summary`, `voice_status`. Sensitive tools and `handoff_to_agent`,
  `take_back`, `view_focus`, `view_find`, `plan_preview`, `work_order_*`,
  `voice_confirm`, `voice_cancel` answer `{"error":"needs_phase_2"}`.
- Status-bar voice item (every Mac) and notch blob (notch Macs). Timeline in
  memory, no view yet.
- Settings ▸ Voice: backend and voice pickers, terminal-output toggle,
  personalization toggle with View and Reset (store only), monthly cap,
  cost readout, microphone status.

### Phase 1b (next agent, after the 1a merge)

- Confirm card (`RafuConfirmPopup` through `RafuPopupPresenter.presentSheet`,
  "Allow once", destructive variant for removals, Return never removes) and
  sensitive tools under Ask and Allow; `voice_confirm` / `voice_cancel`.
- Global ⌃⌥Space through Carbon `RegisterEventHotKey` (press and release, no
  Accessibility permission); mark unverified until it compiles.
- Timeline popover from the status item and the blob; landing ring on a card
  changed by voice (`RafuMotion.landingRing`).
- Verify the check-in audio path; Release memory and CPU measurement, recorded
  in `gpt-live-protocol.md`.

## Exit checklist (VPLAN Phase 1)

- [ ] Hold-to-talk, latched, check-in, pause and idle close work with a real
      microphone on Rafu Lightning (manual).
- [ ] Utterances 1, 2, 7, 9, 10, 11, 13, 14, 15, 16, 18, 19, 21, 22, 29, 30
      work; "Rafu (voice)" notice and badge (manual; executor paths tested).
- [x] Off denies, Ask runs edits with a notice, Allow runs; sensitive calls
      return `needs_phase_2` (tests).
- [x] Backend picker, voice picker, cost meter, cap, tail toggle,
      personalization toggle/View/Reset in Settings ▸ Voice.
- [x] Source-policy test: no logging in `Voice/`; the key only in the
      transport header.
- [ ] `NSMicrophoneUsageDescription` in the staged plist; `--verify` passes.
- [x] Idle: no engine, no task, no timer (by construction: everything is
      created by `open()`; the hotkey is a key monitor only).
- [ ] Parallel and serial suites green; 0 warnings; lint clean (gates).
- [ ] Release memory/CPU: session ≤ +25 MB, listening ≤ 8 % CPU (Phase 1b).

## Manual checks (the user; Rafu Lightning only; no synthetic input)

0. Settings ▸ AI: add an OpenAI configuration and save its API key first.
1. Open an Ensemble in Ask mode. Hold ⌃⌥Space, say "Add a note called Plan",
   release. Expect: blob listening, then thinking; a note appears; notice
   "Rafu (voice) added Plan · Undo"; a spoken confirmation in about 5 s.
2. Say "Undo". The note goes away.
3. Set the Ensemble to Off. Say "Add a note". Expect a spoken "read-only"
   reply and no change.
4. Click the blob (or Rafu ▸ Start Listening, ⌃⌥⇧Space) to latch. Stay silent:
   45 s check-in glyph (and audio, if the append works — record which),
   60 s Paused, 90 s the session closes and the blob returns to idle;
   Settings ▸ Voice shows the minutes.
5. Ask a long question and talk over the reply. Playback stops within about
   1.5 s (with echo cancellation on; note speakers vs. headphones).
6. Two windows with an Ensemble each: voice acts on the key window's board.
7. Reduce Motion on: the blob is still. VoiceOver: the status item reads the
   state.
8. Deny the microphone once: the blob shows "Microphone access is off";
   Settings ▸ Voice offers "Open System Settings".
9. Allow mode with "Share terminal output" on: ask "What is the terminal
   doing?"; the reply reflects the visible lines.
