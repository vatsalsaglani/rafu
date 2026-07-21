# T-F — Notch HUD for terminal attention

Status: planned, not started. Prepared 2026-07-21 against `475faf1`
(terminal manager T-A…T-E complete, 956 tests, 0 warnings).
Depends on: [`terminal-manager.md`](terminal-manager.md) T-E, which already
ships the model layer this phase re-presents.

## Why this is its own phase

The user asked for the attention experience to surface "from the macbook
notch … show the agent's last reply there and allow the user to type in
their command there only and send it". T-E delivered the substance of that
through a system notification: bounded output snippet + an inline reply
field that writes to the session's pty. What T-F adds is a *different
presentation surface* for the same data.

It was deliberately split out because it is not an incremental change:

- **macOS has no notch API.** There is no Dynamic Island equivalent. The
  notch is only screen geometry — `NSScreen.safeAreaInsets` /
  `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` describe it, and that is
  all the system offers. Every app that appears to "use the notch"
  (NotchNook, DynamicLake, boring.notch) draws a borderless, always-on-top
  `NSWindow` positioned under the menu-bar strip and fakes the shape.
- That means a new window subsystem with its own lifecycle, focus, input,
  multi-display and accessibility story — none of which can be verified
  headlessly, on a UI surface this session has already iterated on painfully.

## Scope

A small always-available HUD anchored to the notch/menu-bar area that:

1. Appears when a background terminal session raises `.bell` (the exact
   trigger T-E already computes — `TerminalAttentionPolicy.shouldRaiseAttention`).
2. Shows the session's display name and the same bounded output snippet the
   notification uses (`TerminalAttentionPolicy.snippet`, 6 lines / 512 bytes,
   control characters stripped).
3. Offers a one-line reply field that routes through the *existing*
   `TerminalAttentionCenter.deliverReply(_:to:)` — same sanitization, same
   UUID routing, same drop-on-dead-session behavior.
4. Dismisses on reply, on Escape, on clicking through to the session, and
   after a timeout.

**The whole point is that T-F adds no new data path.** Snippet reading,
reply sanitization, routing and privacy rules are already implemented,
tested and documented (ADR 0016). T-F is presentation only. If the
implementation finds itself re-reading the terminal buffer or re-writing to
a pty, it has gone wrong.

## Non-goals

- Replacing the system notification (they coexist; the HUD is for when the
  app is running and visible, the notification for when it is not).
- A general-purpose notch platform (music, timers, drag-and-drop targets).
- Anything on displays without a notch beyond a menu-bar-anchored fallback.
- Persisting HUD state across relaunch.

## Design sketch

- `NotchHUDWindow: NSPanel` — `.nonactivatingPanel`, `isFloatingPanel = true`,
  `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary,
  .fullScreenAuxiliary]`, `hasShadow`, transparent background, ignores mouse
  events except over its own content. Hosting an `NSHostingView` of a SwiftUI
  `NotchHUDView`.
- **Geometry**: read `NSScreen.main?.safeAreaInsets.top` and
  `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. When those report a notch,
  center the HUD under it and match its width plus the shape. When they do
  not (external display, older Mac), fall back to a top-center menu-bar-anchored
  card. **Both paths must be implemented** — most external monitors have no
  notch, and a notch-only feature would be invisible for many users.
- **Focus**: a `.nonactivatingPanel` can host a text field without stealing
  app focus, but it must become key to receive typing. Use
  `canBecomeKey = true` on the panel only while the reply field is focused,
  and resign immediately after send. This is the single fiddliest part.
- **Multi-display**: follow the screen with the mouse, or the screen owning
  the key window; recompute on `NSApplication.didChangeScreenParametersNotification`.
- **Reduce Motion**: no slide-down; cross-fade only. **Increase Contrast**:
  solid background, defined border. **VoiceOver**: the HUD must be reachable
  and announce the session name + snippet; if it cannot be made accessible,
  the notification remains the accessible path and that must be stated.
- Off by default? **No** — but gate it behind the same
  `terminalBellNotificationsEnabled`-style preference family so a user can
  choose HUD, notification, both, or neither. Recommend a single enum
  preference (`.notification`, `.hud`, `.both`, `.none`) rather than two
  booleans.

## Tests

Pure/headless (the only kind possible here):
- Geometry resolution: given a screen with/without a notch and given
  auxiliary areas, the computed HUD frame is centered, within bounds, and
  falls back correctly. Inject screen metrics — never read `NSScreen` in the
  pure function.
- Dismissal policy: a pure function over (didReply, escapePressed, elapsed,
  sessionStillNeedsAttention) → shouldDismiss.
- Preference enum round-trip and its effect on
  "should post notification" / "should show HUD" decisions.
- Reply path reuses `TerminalAttentionPolicy.sanitizedReply` and
  `TerminalAttentionCenter.deliverReply` — assert by construction (no new
  sanitization logic exists), plus a spy test that the HUD's send calls the
  center exactly once with the sanitized text.

**GUI-only (the majority — flag honestly):** HUD appearance under the real
notch and on a non-notch display; text-field focus without stealing app
focus; typing a reply landing in the right terminal; behavior in full
screen and across Spaces; multi-display follow; Reduce Motion / Increase
Contrast / VoiceOver.

## Risks

- **Focus stealing** is the likeliest user-visible failure: a HUD that grabs
  keyboard focus mid-typing would be worse than no HUD.
- **Always-on-top window in full screen** — `.fullScreenAuxiliary` is
  required or the HUD vanishes exactly when an agent-watching user is most
  likely to be full-screened.
- **Screen-parameter churn** (docking, sleep/wake) invalidating cached
  geometry.
- **Duplicate attention** — HUD and notification both firing for one bell is
  noise; the preference enum exists to prevent it.
- This is the third UI surface in this codebase to fight macOS 26 window
  chrome (see ADR 0012's amendments). Budget for empirical
  screenshot-driven iteration rather than reasoning from the API docs.

## Verification gates

`swift build` 0 warnings; `swift test` AND `swift test --no-parallel` green
(baseline 956 + new); `./script/format.sh --fix` then `--lint` clean;
`./script/build_and_run.sh` pass covering the GUI-only list above on both a
notched built-in display and an external display.

## Documentation on completion

- Amend ADR 0016 (terminal attention) with the HUD as a second presentation
  surface and the preference enum that arbitrates between them.
- Reference note: the real `NSScreen` notch/auxiliary-area API surface, what
  it does and does not tell you, and the non-activating-panel focus recipe —
  this is exactly the kind of platform nuance the standing learning rule
  exists for.
