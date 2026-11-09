# Voice presence: the companion orb, card, pill and status dot

- Applies to: `Sources/RafuCore/Voice/VoicePresence.swift` (pure rules),
  `Sources/RafuApp/Voice/VoiceOrbView.swift` (`VoiceOrbView`, `VoiceOrbPalette`,
  `VoicePresenceSampler`, `VoiceLiveOrb`), `VoiceCompanionView.swift`
  (`VoiceCompanionModel`, `VoiceCompanionHost`), `VoiceSpeechCard.swift`,
  `VoiceControlPill.swift`, `VoiceNotchOrb.swift`, `VoiceStatusItem.swift`, the
  presence block of `VoiceSession.swift`, and the overlay in
  `Sources/RafuApp/Views/WorkspaceWindowView.swift`
  ([ADR 0035](../decisions/0035-voice-through-gpt-live.md), amendment 2026-11-10 "the companion").
- Last verified: Swift 6.4.2, macOS 27, 2026-11-10 (code and unit tests only). The
  look on screen, CPU, VoiceOver, drag and tuck are **not** verified yet; they are
  the manual checks in [`voice-control.md`](../plans/phases/voice-control.md).

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

- A fixed 96 pt slot, 18 pt from the corner. The orb is 72 pt, 96 pt on hover, 40 pt idle,
  20 pt tucked, anchored to the corner inside the slot.
- Drag: `DragGesture(minimumDistance: 4)` on the orb only, exclusive before a tap; the
  offset follows the pointer 1:1 in a `disablesAnimations` transaction; on release the
  corner is the quadrant of the slot centre plus `predictedEndTranslation`
  (`VoiceCompanionPlacement.corner(afterDragFrom:predicted:in:)`), with
  `RafuMotion.companionSnap`.
- Keyboard: the orb is `.focusable(interactions: .activate)`. ⌥ + arrow moves to the
  adjacent corner; Space toggles the pill; focus shows the pill.
- Corner memory: `voice.companion.corner.<FNV-1a 64 of the workspace path, hex>`. The
  descriptor id is new on every open, so it cannot key a per-workspace value across
  launches; the hash keeps paths out of `UserDefaults` keys. A test pins the hash of `"a"`;
  changing the hash loses every saved corner.
- Card: above the orb in a bottom corner, beside it toward the window centre in a top
  corner. Pill: beside the orb toward the centre in a bottom corner, below it in a top
  corner. Placed with overlay alignment plus `alignmentGuide`, so no size is measured.
- Tuck (P1): the card header move gesture (`CanvasCardShell.headerGesture`, global
  coordinates) calls `noteBoardDrag(at:)` per change and `boardDragEnded()` at the end.
  The model compares the pointer with the slot's global frame (+8 pt) and writes
  `isTucked` only on a change; the orb returns 400 ms after the drag ends
  (`RafuMotion.companionTuck`). The board's background pan flags (`gridDragIsLive`,
  `boardDragIsLive`) are pans, not card drags, so they are not used. "Nudge away from the
  focused card" is P2, not built.

### Orb rendering and motion

- `VoiceOrbView` is pure: `VoiceOrbPose` (from `VoiceOrbPose.pose(for:micOpen:latched:
  increaseContrast:)`), `VoiceOrbPalette`, `level`, `phase`, `ripple`, `size`. One `Canvas`:
  base disc, four radial lobes with `.plusLighter` clipped to the disc, a specular
  highlight, eye-lights, a rim shade, the ring and the ripple. No `addFilter(.blur)`, no
  `TimelineView`, no Metal. The look may change later: only `VoiceOrbView` and
  `VoiceOrbPalette` should need edits.
- `VoicePresenceSampler` (one per orb, `@State`): one `Task.sleep` loop at 50 ms
  (10 ms tolerance), started by `.task(id:)` only while the pose has a driver
  (input, output, turning) or a ripple **and** `\.rafuMotionAllowed` **and** not Reduce
  Motion. Otherwise `run` resets to a still frame and returns: idle and paused run no
  task. Smoothing `shown = max(raw, shown × 0.72)`; a write only when the level moves by
  more than 0.02 (Thinking writes every tick: 0.1 turn/s). Silence never moves the lobes:
  the phase advances with the level only.
- `VoiceSession.outputLevel` comes from the RMS that `handleOutputAudio` already computes
  (`VoiceAudioLevel.meterLevel`), is written only on a change above 0.02, and is reset in
  `endReply` and `stopCapture`.

### Theme

- `VoiceOrbPalette(theme:increaseContrast:)` reads only `theme.palette` tokens: base =
  `appBackground` darkened (dark themes) or `textPrimary` with a touch of accent (light
  themes), so the orb is dark on every theme; lobes = `info`, accent, accent lifted to
  white, `warning` mixed with accent; the ring is `accent`. Light-theme accents are lifted
  toward white first, as `RafuMascotColors` does. A user theme without optional tokens
  gets the fallbacks `RafuThemePalette` already resolves (`info` `#82A7F0`, `warning`
  `#E8894A`). The card and pill use `cardBackground`, `textPrimary/Secondary`,
  `borderSubtle`, and `borderStrong` under Increase Contrast; they are solid, so Reduce
  Transparency needs no change.

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

### Status dot and notch

- `VoiceStatusItem` label is a 7 pt template image: filled while a session is open
  (accent), a ring while idle (muted). A borderless `Menu` label draws an image, not a
  `Shape`, so the dot is an `NSImage` drawn once. The state word is in `.help` and the
  accessibility value; the menu is unchanged.
- The notch wing shows `VoiceNotchOrb` (20 pt `VoiceLiveOrb`, no ring) where
  `VoiceBlobView` was. `VoiceBlobView` and `VoiceLevelBars` are gone.

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

- `VoicePresenceTests` (RafuCore): pose table, smoother, ripple, captions, card order and
  hold rules, placement, corner key, progress.
- `VoicePresenceAppTests`: the palette for Indigo, Khadi and custom light and dark themes,
  with and without Increase Contrast; the sampler gate; corner memory; tuck and return.
- `VoicePresenceSessionTests` (in `VoiceSessionIntegrationTests.swift`): output level,
  captions, the inline Confirm, turn progress, the agent line.

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
