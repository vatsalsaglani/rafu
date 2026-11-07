# Rafu Voice — GPT-Live control of the Ensemble

- Status: **Phase 1a merged** to `main` (2cbf3aa). **Phase 1b implemented**
  on `voice/phase-1b` (2026-11-07), awaiting review, merge and the manual
  microphone checks below.
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
  (hotkey install; 1b: voice close on quit), `script/build_and_run.sh`
  (microphone usage string), `SettingsPresentationTests.swift`.
- Phase 1b needed no Canvas change: the landing ring sets the existing
  `CanvasBoardState.landing`, which `CanvasSetDownRing` already draws.
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

### Phase 1b (done on the branch)

- [x] Confirm card for sensitive calls in Ask mode (`VoiceConfirm.swift`):
      "Allow Once" (default), "Allow for This Session" (in memory, not for
      removals), Cancel; removals show one destructive "Remove" and Return
      never removes. `voice_confirm` / `voice_cancel` resolve the same card;
      60 s timeout; closing the session cancels it. Allow runs sensitive
      calls with the badge and no card. `needs_phase_2` stays for hand-off,
      take back, focus, find, plan preview and work orders.
- [x] Global ⌃⌥Space through Carbon `RegisterEventHotKey` (press and
      release); the local monitor stays as the fallback. Settings ▸ Voice
      shows a one-line notice with ⌃⌥⇧Space when macOS's input-source
      shortcut owns the chord. It compiles; the press/release in another app
      is a manual check.
- [x] Voice Timeline popover from the status item menu and the blob's
      context menu (also a VoiceOver action): lanes You, Rafu, Delegations,
      Tools, Board effects, with ids, start offsets and durations; live;
      empty after close.
- [x] Landing ring on every card voice adds or changes (the Round A
      set-down ring; no haptic for voice). The trail from the blob was not
      built (optional; not small across the notch panel and the board).
- [x] Review items: rate limit on voice calls; engine stop after 10 quiet
      seconds in a session that is not latched; `session.close` on quit
      (≤ 2 s) plus a synchronous socket drop; a second press while
      connecting keeps the first press's frames.
- [ ] Release memory/CPU measurement with an open session (manual; method and
      the idle numbers in `gpt-live-protocol.md`).

## Exit checklist (VPLAN Phase 1)

- [ ] Hold-to-talk, latched, check-in, pause and idle close work with a real
      microphone on Rafu Lightning (manual).
- [ ] Utterances 1, 2, 7, 9, 10, 11, 13, 14, 15, 16, 18, 19, 21, 22, 29, 30
      work; "Rafu (voice)" notice and badge (manual; executor paths tested).
- [x] Off denies, Ask runs edits with a notice, Allow runs; sensitive calls
      wait on the Confirm card in Ask and run with the badge in Allow (tests).
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

Phase 1b additions:

10. Ask mode: say "Remove the Review note". A Confirm card shows "Remove"
    (red) and Cancel; Return does nothing destructive. Say "yes" (hold the
    key again if not latched). Record whether the spoken yes resolves the
    card (it needs GPT-Live to start a second delegation while the first
    waits); clicking Remove always works. Leave a card alone for 60 s: it
    closes and Rafu says it did not happen.
11. Ask mode: "Start a Claude terminal". The card offers Allow Once (default,
    Return) and Allow for This Session. Choose the session grant, then ask
    for a second one: no card. Close the session; the next request shows the
    card again.
12. With another app in front, hold ⌃⌥Space and speak; release. Rafu hears
    it and the blob shows listening. With two input sources on, Settings ▸
    Voice shows the input-source notice.
13. Hold-to-talk once, then wait 10 s after the reply: the macOS microphone
    indicator goes out while the blob still shows Paused. Press again: it
    comes back and speech goes through (note any clipped first word).
14. Open the Voice Timeline from the status item menu during a session: rows
    appear live in the five lanes; after the session closes it is empty.
    VoiceOver reads each row (id, title, detail, time).
15. A note created by voice shows the set-down ring once (none under Reduce
    Motion).
16. Quit Rafu Lightning during a session: it quits within about 2 s, and
    Settings ▸ Voice counts the minutes.
