# Voice presence: the companion orb, card, pill and status item

- Applies to: `Sources/RafuCore/Voice/VoicePresence.swift` (pure rules),
  `Sources/RafuApp/Voice/VoiceOrbView.swift` (`VoiceOrbView`, `VoiceOrbPalette`,
  `VoiceOrbRenderer`, `VoiceOrbAnimator`, `VoiceLiveOrb`), `VoiceCompanionView.swift`
  (`VoiceCompanionModel`, `VoiceCompanionHost`), `VoiceSpeechCard.swift`,
  `VoiceControlPill.swift`, `VoiceNotchOrb.swift`, `VoiceStatusItem.swift`,
  `VoiceTimelinePopover.swift`, the presence block of `VoiceSession.swift`, the zoom
  corner reserve in `Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift`, and the
  overlay in `Sources/RafuApp/Views/WorkspaceWindowView.swift`
  ([ADR 0035](../decisions/0035-voice-through-gpt-live.md), amendment 2026-11-10 "the companion").
- Last verified: Swift 6.4.2, macOS 27, 2026-11-10 (code and unit tests only; the
  kanche redesign of the same day). The look on screen, CPU, VoiceOver, drag and tuck
  are **not** verified yet; they are the manual checks in
  [`voice-control.md`](../plans/phases/voice-control.md). The design artifact (private):
  https://claude.ai/artifact/FCY8SC8zgPvAjiwiuUKgiu

## Rule or observed behavior

### Host

- One `VoiceCompanionHost` per workspace window, an `.overlay` on the workbench row
  (sidebar + deck) in `WorkspaceWindowView`: above the editor and every tab, below
  sheets, under the titlebar row and above the status bar. It is not inside the board's
  zoomed layer, so it does not pan or zoom. The welcome screen has no companion.
- The window owns `VoiceCompanionModel` in `@State`, puts it in the environment (board
  cards read it as an optional `@Environment(VoiceCompanionModel.self)`) and publishes it
  as `\.voiceCompanion` focused scene value (Rafu menu: Show Voice Timeline, Move Voice
  Companion to Next Corner).
- Visible while `blobState != .idle` (an error stays visible), or with
  `voice.companion.keepOnCanvas` on (Settings ▸ Voice, default off: a still 40 pt dim
  orb), or while the timeline popover is open.

### Placement

- A 64 pt slot, 18 pt from the corner. The orb is 64 pt (it does not grow on hover),
  40 pt idle, 20 pt tucked, anchored to the corner inside the slot.
- Chrome the orb must not cover reports a reserved rect (global) to
  `VoiceCompanionModel.setAvoidRect(_:for:)`; the host reports its own global frame, and
  `localAvoidRects` moves the rects into the host's space. A model, not a preference, so
  it also crosses an `NSHostingView`. Today one reporter: the board's zoom corner
  (`WorkspaceCanvasView.voiceCompanionReserve`, key `board.<presentation id>`), sized to
  the capsule plus the overview's place (at least 140 × 126 pt) **also while the overview
  is hidden**, so the orb does not jump when the overview shows on hover.
- `VoiceCompanionPlacement.slotRect(for:in:avoiding:)`: the corner; else away from the
  horizontal edge on the same vertical line (above the zoom corner in a bottom corner —
  user decision 2026-11-10); else beside the chrome in a short host; else the corner.
  8 pt clear space around chrome.
- Drag: `DragGesture(minimumDistance: 4)` on the orb only, exclusive before a tap; the
  offset follows the pointer 1:1 in a `disablesAnimations` transaction; on release the
  corner is the quadrant of the slot centre plus `predictedEndTranslation`
  (`VoiceCompanionPlacement.corner(afterDragFrom:predicted:in:)`, from the current
  slot rect), with
  `RafuMotion.companionSnap`.
- Keyboard: the orb is `.focusable(interactions: .activate)`. ⌥ + arrow moves to the
  adjacent corner; Space toggles the pill; focus shows the pill.
- Corner memory: `voice.companion.corner.<FNV-1a 64 of the workspace path, hex>`. The
  descriptor id is new on every open, so it cannot key a per-workspace value across
  launches; the hash keeps paths out of `UserDefaults` keys. A test pins the hash of `"a"`;
  changing the hash loses every saved corner.
- Card and pill take explicit rects (`cardRect`, `pillRect`) and an `.offset` in one
  top-leading `ZStack`; their sizes are measured with `onGeometryChange`. Card: above the
  orb in a bottom corner, below it in a top corner, its outer edge in line with the orb;
  beside it toward the centre in a short host. Pill: toward the window centre on the
  orb's centre line, then above or below, then away; off the orb, off chrome and the
  card when it can be, and always inside the host (8 pt margin). The pill shows only
  once its size is known (opacity 0 until then).
- **Pitfall (fixed):** the old layout put `.alignmentGuide` calls *inside* an
  `if model.showsPill` block under `.overlay(alignment:)`. A guide set inside a
  conditional does not reach the overlay (the overlay aligns the conditional wrapper,
  which reports default guides), so the pill aligned leading-to-leading with the slot:
  it covered the orb and ran past the window edge. Reproduced in a stand-alone probe
  (slot x 286, pill 134 wide, host 400: pill at x 286 with the guide inside the `if`,
  x 146 outside it). Do not place companion parts with alignment guides.
- Tuck (P1): the card header move gesture (`CanvasCardShell.headerGesture`, global
  coordinates) calls `noteBoardDrag(at:)` per change and `boardDragEnded()` at the end.
  The model compares the pointer with the slot's global frame (+8 pt) and writes
  `isTucked` only on a change; the orb returns 400 ms after the drag ends
  (`RafuMotion.companionTuck`). The board's background pan flags (`gridDragIsLive`,
  `boardDragIsLive`) are pans, not card drags, so they are not used. "Nudge away from the
  focused card" is P2, not built.

### Orb rendering and motion

- The orb is a "kanche": a translucent tinted glass marble (the board shows through it;
  thin and clear in the middle, stronger at the rim) with a cat's-eye leaf of coloured
  glass inside (two leaves along off-centre S-curves, three uneven bands, a twist that
  narrows and pales the sheet where it turns its back), two fixed window reflections, a
  thin rim light, a caustic and crescent at the lower right, three bubbles, a tinted
  contact shadow, and a face of **two dots** (no eye whites, no pupils — user decision).
  One `Canvas`, no blur filter, no Metal.
- Faces (`VoiceOrbFace`, RafuCore): off, connecting, listening, hearing, thinking,
  speaking, checkIn, paused, needsConfirm, error, success. `face(for:)` maps the session
  state; *hearing* is shown by the motion while the mic level is above 0.08 (back below
  0.02); *success* (the Done face) shows for 1.2 s after each completed task, never over
  needsConfirm, error or off. A badge only for **paused** (pause), **needsConfirm** (hand)
  and **error** (exclamation mark) — user decision; so a badge always means Rafu does not
  hear you or needs you.
- Pose table: `VoiceOrbExpression.target(for:)` (lids, happy arcs, gaze, dot size,
  brows, tilt, wobble speed, level swell, grey, glow, scale). Paused differs from
  Listening by the face (a flat lid cuts the dots, they look down), the badge, and a
  paler marble — not by colour only.
- Motion: `VoiceOrbMotion.step` (pure, 30 Hz) eases the pose (0.28 per tick, snaps when
  close, so a finished change is exactly equal), smooths the level
  (`max(raw, shown × 0.8)`), rocks the marble (it never spins), runs the connecting
  ripple, and moves the dots toward the pointer only while listening. `isSettled` is
  true for a face with no clock once everything arrived.
- `VoiceOrbAnimator` (one per orb, `@State`): one `Task.sleep` loop at 33 ms, started by
  `.task(id:)` with the face and the motion gate (`\.rafuMotionAllowed` and not Reduce
  Motion). It writes only when `step` reports a change, and returns once a face with no
  clock settles. Listening keeps the loop to notice speech, but silence writes nothing.
  Without motion: one still frame (`rest`), no blink. Blinks: one sleep of 3–6 s, then
  five 33 ms frames. Levels are read by a closure on each tick, so the hosting view does
  not redraw for level changes. No always-on timeline view (the source policy test bans
  it in Voice).
- Done: `VoiceSession.completedTasks` moves by one when a delegation ends — the
  `response.completed` that has no call running and no output waiting for another
  response — and at least one of its calls finished. A delegation counts once.
- The notch orb (`isCompact`) has no face and no badge: at 20 pt the dots would be
  about 1 pt.
- `VoiceSession.outputLevel` comes from the RMS that `handleOutputAudio` already computes
  (`VoiceAudioLevel.meterLevel`), is written only on a change above 0.02, and is reset in
  `endReply` and `stopCapture`.

### Theme

- `VoiceOrbPalette(theme:increaseContrast:reduceTransparency:)` reads only
  `theme.palette` tokens. Glass tint: sea-glass aqua mixed 25 % with `info`; alpha 0.16 →
  0.50 (dark) or 0.20 → 0.55 (light). Leaf bands: `accent` (lifted 10 %), `warning` on
  dark or `success` on light, `info`; light themes lift them 15 % toward white. Dots:
  near-white on dark themes, `textPrimary` on light ones, each on a soft halo of the
  opposite tone. Reduce Transparency draws a solid `cardBackground`-based base under the
  glass; Increase Contrast gives a 2 pt `borderStrong` outline. Other marble variants
  (cobalt, amber, green) are in the design artifact only; not built.
- The card, pill and timeline popover use `cardBackground`, `chipBackground`,
  `textPrimary/Secondary/Muted`, `borderSubtle`, and `borderStrong` under Increase
  Contrast; they are solid, so Reduce Transparency needs no change. The popover sets
  `.presentationBackground(cardBackground)` so the arrow matches.

### Card

- `VoiceCardPolicy.content` order: Confirm, error, the state's own words (Connecting…,
  Working…, Still there?), a hint, the live caption (yours while you talk, Rafu's newest
  12 words while Rafu speaks), the agent line. A voice caption always wins over an agent
  line. One card; it hides 4 s after the last change unless Rafu speaks, a Confirm waits,
  an error shows, Working/Connecting shows, or the pointer is over it. One sleep per
  change; nothing loops.
- `VoiceSession.liveCaption` keeps at most 160 scalars in memory and is cleared on close;
  it never reaches the debug transcript or disk.
- Inline Confirm: ✓ and ✕ call `VoiceSession.answerConfirm(_:)`, which resolves the same
  `VoiceConfirmGate` as the sheet: the first answer wins and the gate dismisses the sheet.
  The existing `resolveConfirm(_:)` stays the spoken path (a confirmation needs a later
  backend turn); a click does not, because the user acted.
- Agent line: `VoiceSession.agentLine` is the newest update of the batch that was just
  spoken (`VoiceAgentUpdates.lastSpoken`). The chevron opens the board and zooms to the
  card. The orb does not change for updates.
- Live region: `AccessibilityNotification.Announcement` for a caption at a sentence end,
  a Confirm, an error, and a new agent line.

### Status item, pill, timeline: running or paused in words

- `VoiceRunStatus` (RafuCore) gives one word, a mic line ("Mic on"/"Mic off") and a
  glyph per state, plus the main action ("Pause" when latched, else "Listen").
- `VoiceStatusItem`: an 11 pt SF Symbol template image (`mic.fill`, `pause.fill`,
  `mic.slash.fill`, `ellipsis`, a ring while idle) as the borderless `Menu` label, and the
  state word beside it while a session is open.
- `VoiceControlPill`: `VoiceStatusChip` ("Listening · Mic on"), the named main button,
  then Stop Speaking, Timeline, Settings, End (icons with `.help`).
- `VoiceTimelinePopover`: header with the chip; a banner with Start Listening while
  paused; an empty state that says what to do. Marker rows (lane `.marker`, item
  `.marker`): "Session started", then "Listening. The mic is on." or "Paused. The key was
  released before the session started." on connect, "Paused by you" / "Listening…" on a
  latch toggle, "Paused. No answer to the check-in." Before this, a new session had no
  row until speech or a call, so it read "Nothing yet in this session."
- Connect-then-paused (key released before `session.started`): `hint` is
  `VoiceSession.connectedPausedHint`, so the card says the mic is off and how to talk.
- The notch wing shows `VoiceNotchOrb` (20 pt compact `VoiceLiveOrb`).

### Menu and shortcuts (Rafu menu)

| Item | Shortcut |
|---|---|
| Start / Stop Listening | ⌃⌥⇧Space |
| Stop Speaking | ⌃⌥⇧. |
| End Voice Session | ⌃⌥⇧E |
| Approve Voice Request (Approve Voice Removal) | ⌃⌥⇧Return; none for a removal (ADR 0033) |
| Cancel Voice Request | ⌃⌥⇧Escape |
| Show Voice Timeline | ⌃⌥⇧T |
| Move Voice Companion to Next Corner | none (⌥ + arrow on the orb) |

## Why it matters

The companion is drawn in every window while a session is open, so a loop that runs when
nothing moves costs CPU in every window, and a hard-coded colour breaks the user's custom
themes.

## Reproduction / evidence

- `VoicePresenceTests` (RafuCore): faces and badges, Listening versus Paused, Done,
  easing and settling, silence, hearing hysteresis, rocking, ripple, pointer gaze, rest;
  captions, card order and hold rules; slot above chrome, beside it in a short host; card
  and pill rects (the pill never covers the orb and stays inside, widths 300–1600, every
  corner); corner key, progress.
- `VoicePresenceAppTests`: the palette for Indigo, Khadi and custom themes, contrast and
  transparency; the animator's still frame and self-ending loop; avoid rects in the
  host's space; corner memory; tuck and return.
- `VoiceSessionIntegrationTests`: timeline markers on connect and latch toggles; the
  connect-then-paused hint and markers; one completed task per delegation, counted after
  its last response.

## Verification commands

```bash
swift test --filter VoicePresenceTests
swift test --filter VoicePresenceAppTests
swift test --filter VoicePresenceSessionTests
swift test --filter VoiceSourcePolicyTests
top -l 50 -s 1 -pid $(pgrep -x RafuLightning)   # manual CPU check
```

## Related

- [ADR 0035](../decisions/0035-voice-through-gpt-live.md), [ADR 0033](../decisions/0033-rafu-popup-language.md) (removals never on Return)
- [`voice-control.md`](../plans/phases/voice-control.md) manual checks 31–38
- [`gpt-live-protocol.md`](gpt-live-protocol.md)
