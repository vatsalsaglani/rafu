# T-F — Notch HUD for terminal attention

Status: planned, not started. Prepared 2026-07-21 against the completed
terminal-manager phase (T-A…T-E, 960 tests, 0 warnings). Supersedes the
earlier sketch version of this document.

Depends on: [`terminal-manager.md`](terminal-manager.md) T-E and ADR 0016.
Every data-path primitive the HUD needs already exists, is tested, and is
security-reviewed; **T-F is presentation only**. If an implementation finds
itself re-reading the terminal buffer, re-sanitizing replies, or opening a
second route into a pty, it has gone wrong — stop and re-read this line.

## What the user asked for

"Show the notification from the MacBook notch, show the agent's last reply
there, and let me type my command there and send it instead of navigating
back to the app."

## Ground truth: the platform has no notch API (verified on this machine)

There is no Dynamic Island equivalent on macOS. The system exposes only
geometry, probed live on this MacBook Air (1710×1107 points):

```
safeAreaInsets:        top: 33.0            ← menu-bar/notch band height
auxiliaryTopLeftArea:  (0,    1074, 763, 33) ← usable strip LEFT of the notch
auxiliaryTopRightArea: (948,  1074, 762, 33) ← usable strip RIGHT of the notch
```

Therefore the notch rect itself is derivable, not queryable:

- `notchWidth = auxTopRight.minX - auxTopLeft.maxX` (= 185pt here)
- `notchHeight = safeAreaInsets.top` (= 33pt here)
- On a screen with NO notch, both auxiliary areas are nil → fall back.

Every app that appears to "use the notch" (NotchNook, boring.notch,
DynamicLake) draws a borderless always-on-top `NSWindow` positioned in that
band and fakes the shape. That is what T-F builds — which is why it is its
own phase: a new window subsystem with lifecycle, focus, input,
multi-display and accessibility obligations, verifiable only by GUI pass.

## Existing seams the HUD plugs into (verified symbols, current tree)

| Need | Existing, tested primitive |
|---|---|
| "A session needs attention" trigger | `WorkspaceSession.notifyIfNeeded(for:)` (`WorkspaceSession.swift:430`) — the exact point that decides a bell deserves surfacing; the HUD hook goes beside the notifier call, gated by the same `TerminalAttentionPolicy.shouldNotify` inputs |
| The output snippet | `WorkspaceTerminalController.recentOutputSnippet()` → `TerminalAttentionPolicy.snippet` (bounded 6 lines / 512 bytes, control-stripped; `TerminalAttentionPolicy.swift:44`) |
| Reply sanitization | `TerminalAttentionPolicy.sanitizedReply(_:maxBytes:)` (`:65`) — one line, 1024-byte cap |
| Reply routing to the right pty | `TerminalAttentionCenter.shared.deliverReply(_:to:)` (`TerminalAttentionCenter.swift:42`) — UUID-routed, drop-on-dead-session |
| Display name / color | `WorkspaceTerminalController.displayName` / `sessionColor` |
| Preference storage pattern | `TerminalNotificationPreferenceStore` (suite-injectable, default-on) |
| Attention lifecycle | `.bell` set by `noteBell()`, cleared by tab selection — the HUD dismises when the state clears, it does NOT own the state |

Privacy rules carry over verbatim from ADR 0016: the snippet is passed by
value into the HUD view and dropped; never logged, persisted, or
transmitted. The HUD shows it on screen — that is its job — but it must not
survive dismissal in any store.

## Product decisions locked by this doc

1. **One arbitration preference, not two booleans.** Replace the single
   `terminalBellNotificationsEnabled` bool with
   `TerminalAttentionSurface: String enum { notification, hud, both, none }`,
   default `.both`. Migration: existing key absent → `.both`; existing
   `false` → `.none`; existing `true` → `.both`. The old key is read once
   for migration and then superseded — document in the store.
   Rationale: HUD + banner both firing for one bell is noise the user has
   to configure away; an enum makes the arbitration explicit and testable.
2. **The HUD never steals focus while you type elsewhere.** It appears
   without activating; keyboard focus moves to it ONLY when the user
   clicks its reply field (or presses the global reveal shortcut, N-C).
   A HUD that grabs the keystroke you were typing into your editor is
   worse than no HUD.
3. **Non-notch displays get the same HUD, anchored top-center under the
   menu bar.** Most external monitors have no notch; a notch-only feature
   would be invisible exactly where many users work. Same window, same
   content, different anchor rect.
4. **The HUD is a queue of one.** If a second session bells while the HUD
   is up, the HUD shows the newest and a "+N more" chip that reveals the
   Terminals panel on click. No carousel, no stacking — the panel is the
   many-sessions surface.
5. **Auto-dismiss after 12s without interaction**, immediately on reply
   send, on Escape, on clicking the session name (which reveals the tab),
   and the moment the session's `.bell` clears for any other reason
   (e.g. the user clicked the tab directly). Hovering pauses the timer.
6. Reduce Motion: cross-fade only, no slide. Increase Contrast: solid
   background + defined border. If VoiceOver focus cannot be made to reach
   a non-activating panel reliably, the notification remains the
   accessible path and the reference note must say so plainly.

## Architecture

### N-1. Geometry (pure, headless-testable — write this first)

`Sources/RafuApp/Terminal/NotchHUDGeometry.swift`

```swift
/// Everything the layout needs from a screen, captured as plain values so
/// the math is testable without NSScreen.
nonisolated struct NotchScreenMetrics: Equatable, Sendable {
    let frame: CGRect                 // screen frame in global coords
    let safeAreaTopInset: CGFloat     // 0 on non-notch displays
    let auxiliaryTopLeft: CGRect?     // nil on non-notch displays
    let auxiliaryTopRight: CGRect?
}

nonisolated enum NotchHUDGeometry {
    /// The notch rect in screen coordinates, or nil when the screen has
    /// none (both auxiliary areas nil, or inset == 0).
    static func notchRect(for metrics: NotchScreenMetrics) -> CGRect?

    /// Where the HUD window goes: hanging just below the notch and
    /// matching at least its width (expanded state grows downward), or —
    /// no notch — top-center just below the menu bar. Always fully within
    /// `frame`.
    static func hudFrame(
        for metrics: NotchScreenMetrics,
        contentSize: CGSize,
        state: NotchHUDState        // .compact / .expanded
    ) -> CGRect
}
```

The ONLY place `NSScreen` is read is a small `@MainActor` adapter that
builds `NotchScreenMetrics` from a real screen; everything downstream is
pure. Screen choice: the screen containing the key window, else
`NSScreen.main`, recomputed on
`NSApplication.didChangeScreenParametersNotification` (dock/undock,
resolution change — the churn source called out by prior chrome work).

### N-2. The panel (`Sources/RafuApp/Terminal/NotchHUDWindow.swift`)

`final class NotchHUDPanel: NSPanel`:

- `styleMask: [.borderless, .nonactivatingPanel]`
- `level = .statusBar` (floats over normal windows, below screensaver)
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`
  — `.fullScreenAuxiliary` is REQUIRED or the HUD vanishes exactly when an
  agent-watching user is full-screened (the scenario this exists for)
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`
- `hidesOnDeactivate = false`, `isMovable = false`
- Content: `NSHostingView(rootView: NotchHUDView(model:))`
- **Focus recipe (the fiddliest part, budget iteration):**
  `canBecomeKey` returns `true` ONLY while the reply field is engaged
  (a flag the view model flips when the user clicks the field). Appear
  without `makeKey` — `orderFrontRegardless()`. On reply send or Escape,
  `resignKey` and re-activate nothing (the previous app keeps focus
  because we never stole it).
- Known trap from this repo's own chrome work: **verify with screenshots,
  not reasoning** — capture the window by ID at each state exactly as the
  FlatWindowChrome/title-bar work did. Empirical loop is the method here.

### N-3. Controller (`Sources/RafuApp/Terminal/NotchHUDController.swift`)

`@MainActor final class NotchHUDController` — app-global singleton beside
`TerminalAttentionCenter` (same weak-session registry justification: bells
arrive with window context, but the HUD is one-per-Mac, not one-per-window).

```swift
func show(_ event: NotchHUDEvent)      // NotchHUDEvent { sessionID, title, snippet, color }
func dismiss(reason: DismissReason)
func attentionCleared(for sessionID: UUID)   // called by the session when .bell clears
```

Pure decision helpers (tested):

```swift
nonisolated enum NotchHUDPolicy {
    /// Queue-of-one: newest event wins; count of superseded ones feeds
    /// the "+N more" chip.
    static func merge(current: NotchHUDEvent?, incoming: NotchHUDEvent,
                      pendingCount: Int) -> (shown: NotchHUDEvent, pendingCount: Int)
    static func shouldDismiss(didReply: Bool, escapePressed: Bool,
                              secondsSinceInteraction: Double,
                              stillNeedsAttention: Bool, isHovered: Bool) -> Bool
    static func surfaces(for preference: TerminalAttentionSurface,
                         authorized: Bool) -> (notification: Bool, hud: Bool)
}
```

`WorkspaceSession.notifyIfNeeded(for:)` changes exactly one way: it asks
`NotchHUDPolicy.surfaces(...)` and calls the notifier and/or
`NotchHUDController.shared.show(...)` accordingly. The HUD path does NOT
require notification authorization — it is our own window.

### N-4. The view (`Sources/RafuApp/Views/NotchHUDView.swift`)

Two states:

- **Compact** (initial): a pill hanging under the notch — session color
  edge (same border language as the panel cards), status glyph, display
  name, first snippet line, "+N more" chip when queued. Click anywhere
  non-field → reveal the session's tab and dismiss.
- **Expanded** (click, or immediately when spawned by hover-over-notch in
  a later iteration — NOT v1): full bounded snippet (monospaced, up to the
  6 stored lines), reply `TextField` + Send. Reply path:
  `TerminalAttentionPolicy.sanitizedReply` →
  `TerminalAttentionCenter.shared.deliverReply` → dismiss. Identical
  contract to the notification reply — same trailing-newline, same
  drop-if-dead semantics, and the session's `.bell` clears on send.

Styling per ADR 0012: flat, theme tokens, `RafuMetrics` radii, hairline
border (or the session color as the border, matching the panel cards), no
glass. The HUD reads the CURRENT theme via the same resolution
`WorkspaceSceneRoot` uses; note the HUD belongs to no window/scene, so the
theme must be passed into the controller on show (from the belling
session's workspace) rather than read from an `@Environment`.

### N-5. Settings

Settings → General: a `Picker("Terminal attention", …)` over
`TerminalAttentionSurface` (Notification / Notch HUD / Both / Off),
replacing the current toggle, with the migration described above. Help
text keeps ADR 0016's honesty: "Replies you type are sent to that
terminal."

## Stages

| Stage | Contents | Size |
|---|---|---|
| N-A | Geometry + policy (pure) + preference enum & migration + tests | S |
| N-B | Panel window + compact view + show/dismiss lifecycle + screenshot-verified placement | M/L |
| N-C | Expanded state + reply field + focus recipe + settings picker + arbitration wiring | M |

Ship N-A+N-B together (visible, no input risk), then N-C.

## Tests (headless — the minority; be honest about it)

- `notchRect`: this machine's real metrics (1710×1107, inset 33, aux areas
  as probed above) → rect (763, 1074, 185, 33); nil for zero-inset/nil-aux
  metrics; synthetic ultrawide metrics.
- `hudFrame`: hangs below the notch, horizontally centered on it, clamped
  within frame; non-notch fallback top-center below menu bar; expanded
  grows downward only.
- `NotchHUDPolicy.merge`: queue-of-one semantics, pending count.
- `shouldDismiss` truth table incl. hover-pauses-timer.
- `surfaces(for:)`: all four enum cases × authorized true/false —
  `.hud` must not depend on authorization; `.notification` must.
- Preference migration: absent → `.both`; legacy true → `.both`; legacy
  false → `.none`; round-trip of all four raw values (suite-injected
  defaults, cleaned up, per the standing test rule).
- Reply path: spy on `TerminalAttentionCenter` — send calls it exactly
  once with sanitized text; empty reply is a no-op.

**GUI-only (the majority — screenshot-driven, per this repo's established
empirical method):** placement under the real notch; non-notch fallback on
an external display; focus non-theft while typing in the editor; click
field → type → Send lands in the right terminal; Escape; auto-dismiss and
hover-pause; full-screen visibility (`.fullScreenAuxiliary`); Space
switching; dock/undock recompute; Reduce Motion / Increase Contrast;
VoiceOver reachability (with the honest fallback note if it fails).

## Prior art (surveyed 2026-07-21)

[open-vibe-island](https://github.com/Octane0411/open-vibe-island) (hook-based
multi-agent notch monitor for OTHER apps' terminals, no reply capability) and
[agent-notch](https://github.com/realfishsam/agent-notch) (ps/lsof-polling
mascot display, ~30s state lag, reads Claude transcripts off disk) both
validate the borderless-window-plus-fallback rendering approach. Rafu's HUD
differs structurally because Rafu OWNS the pty: synchronous BEL instead of
polling/hooks, a typed reply into stdin (neither offers one), and a bounded
ephemeral snippet instead of transcript/hook payload access.

Two requirements adopted from that survey:

1. **Click-through everywhere except the HUD's own content** (agent-notch's
   collapsed-window trick): the panel must set `ignoresMouseEvents` outside
   its content so it never blocks menu items or windows beneath it.
2. **Out-of-scope boundary, stated:** agents running OUTSIDE Rafu (e.g.
   `claude` in Ghostty) are invisible to this HUD — no bell reaches us. If
   that ever matters, it is a separate hooks-based phase (a small forwarder
   CLI over the existing launcher IPC socket), not scope creep here.

## Risks, ranked

1. **Focus stealing** — mitigated by the `canBecomeKey`-only-when-engaged
   recipe; verified by typing in the editor while the HUD appears.
2. **Full-screen invisibility** — `.fullScreenAuxiliary` + GUI check.
3. **Geometry churn** on screen-parameter changes — recompute on
   notification; pure function makes it cheap and testable.
4. **Double surfacing** (HUD + banner) — the arbitration enum; default
   `.both` is deliberate (banner persists in Notification Center, HUD is
   ephemeral) but the user can pick one.
5. **Theme access without a scene** — passed on show; a HUD shown from
   window A after switching window B's theme shows A's theme; acceptable,
   note it.
6. This is the third chrome surface to fight macOS 26 (ADR 0012's
   amendments; the titlebar zone lesson). **Method requirement, learned
   the hard way: screenshot the real window at every step; do not reason
   from API docs.**

## Verification gates

`swift build` 0 warnings; `swift test` AND `swift test --no-parallel`
green (baseline 960 + new); `./script/format.sh --fix` then `--lint`
clean; `./script/build_and_run.sh` GUI pass covering the list above on
the built-in (notched) display and, if available, an external one.

## Documentation on completion

- Amend ADR 0016: the HUD as a second presentation surface, the
  arbitration enum, and the focus-model guarantee.
- Reference note: real `NSScreen` notch geometry semantics (with this
  machine's probed numbers), the non-activating-panel focus recipe, and
  whatever the screenshot loop actually revealed.
- Update this doc's status + phases README row.
