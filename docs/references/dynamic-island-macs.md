# Dynamic Island Macs: cutout classification, event routing, pill and status item

- Applies to: `Sources/RafuApp/Terminal/NotchHUDGeometry.swift`,
  `NotchIslandGeometry.swift`, `NotchCompanionGeometry.swift`,
  `NotchCompanionPolicy.swift` (`CompanionPanelLayering`, `CompanionPresence`,
  `UsageMenuBarItemText`, `NotchIslandUsageGlance`), `NotchCompanionModel.swift`,
  `NotchHUDWindow.swift` (`constrainFrameRect`), `Notch/UsageMenuBarItem.swift`,
  and `Views/NotchCompanionView.swift`; any work on a Mac whose camera is a
  hole-punch with a system Dynamic Island, and any window that sits at or below
  the menu-bar level
- Last verified: macOS 27.2 (26B8119) on Mac17,13, SDK 27.2, Xcode toolchain
  (the Xcode version string was not recorded), 2026-11-15. Geometry, window
  layers, event routing and the "In the menu bar" mode were checked on the
  device by the user. Items under "Not verified" were not.

## Rule or observed behavior

**1. The old notch derivation also returns a rect on an island Mac.** On
Mac17,13 the built-in screen is 1512 x 993 pt, scale 2, `safeAreaInsets.top`
= 40, `auxiliaryTopLeftArea` = (0, 953, 726.5, 40) and
`auxiliaryTopRightArea` = (785.5, 953, 726.5, 40). The derived housing is
x 726.5, width 59, height 40. A notched MacBook gives 185 x 33. So the
derivation alone cannot tell a notch from an island camera.

**2. Classification.** `NotchHUDGeometry.cutout(for:)` returns `.none` (derivation
fails), `.islandCamera` (housing width < 3 x top inset; 59 < 120) or `.notch`
(185 > 99). `NotchHUDGeometry.notchRect` returns a rect only for `.notch`.
The top inset can be fractional on macOS 27 (33.5 reported in a third-party
issue), so all island frames snap to the pixel grid with
`pixelAligned(_:scale:)` and `NotchScreenMetrics.backingScaleFactor`.

**3. KEY FACT: no Rafu surface in the menu-bar band around the island can be
interactive.** The system island belongs to MenuBarAgent and is drawn above app
windows. In the menu-bar band around the island, MenuBarAgent gives every hover
and every tap to the system island. A Rafu window there, even at 109 pt wide,
got no hover and no tap; the island's own hover effect showed instead. No public
API changes this. This is why the first "shared island" design (a Rafu capsule
beside the island, inside the band) was dropped; see ADR 0037.

**4. The menu bar's gap around the island is small and dynamic.** On Mac17,13
(1512 pt wide), with the idle system island (equal to the housing, 727 to 785
pt), menu titles end at about 699 to 701 pt and resume at about 805 to 807 pt:
a gap of about 106 to 109 pt. While the system island shows an activity (screen
recording, music, microphone) it grows to about 117 to 133 pt and the menu bar
moves its titles out, to about 674 to 830 pt. A 228 pt Rafu capsule at this place
drew under menu titles ("Format" and "Window" drew over it).

**5. `constrainFrameRect` moves a window ordered below the menu-bar level.**
`NSWindow.constrainFrameRect(_:to:)` moves a window whose level is below the
menu-bar level (`mainMenu`, 24) out of the menu-bar band. The macOS 27 overflow
layering orders the collapsed companion at `mainMenu - 1` (23), and the in-band
capsule, requested 6.5 pt below the screen top, landed at y 45, below the menu
bar. Fix: `NotchHUDPanel` overrides `constrainFrameRect(_:to:)` and returns the
frame unchanged. The pure geometry already clamps every frame to the screen.
Regression test: `notchPanelKeepsAnInMenuBarFrameBelowTheMenuBarLevel`. This
applies to any Rafu window that is lowered below level 24 and must stay at a
screen coordinate inside the menu-bar band.

**6. Window layers measured on the device (CGWindowList, layers 20 and above).**

| Layer | Owner | Bounds | Role |
|---|---|---|---|
| 26 | MenuBarAgent | 0, 0, 1512 x 993 | full-screen window, the island host |
| 25 | MenuBarAgent | 0, 0, 1512 x 45 | status items |
| 24 | Window Server | 0, 0, 1512 x 45 | the menu bar (45 pt tall) |

`NotchHUDPanel` sits at `.statusBar` (25), the same layer as the status-item
window, and below the island host at 26. `NSScreen.touchCapabilities` is
`.multiTouch`.

**7. The island surfaces.** `CompanionPresence.resolve(surface:position:isEnabled:)`
(a pure function) decides which surface exists. `UsageGlancePosition` has two
values, stored under `notchUsageGlancePosition` as `"belowIsland"` (default,
also for an unknown stored value) and `"menuBar"`. Only an island screen reads
it; a notched or plain screen keeps its panel and never gets a status item.
Settings ▸ Notch shows the "Usage glance" picker on island Macs only.

- **Below the Dynamic Island.** `NotchIslandGeometry`: a black pill hangs
  `pillGapBelowMenuBar` = 4 pt below the menu bar (`visibleFrame.maxY - 4`),
  centred under the island, 33 pt tall. Mascot on the left, usage ring on the
  right. Frames on Mac17,13 (scale 1): resting (701.5, 911, 109, 33), wide
  (615, 911, 282, 33), open card with content height 373 (536, 571, 440, 373),
  card radius 28 pt. Hover widens the pill to 282 pt and adds the percent. A
  click or a tap toggles a Usage-only card that grows down from the pill. The
  resting width is the housing plus 2 x 25 pt, about the width of the menu bar's
  gap. Vertical values and widths scale with the top inset (`scale(for:)`,
  clamped 0.75 to 1.5). The pill is never lowered: `CompanionPanelLayering`
  lowers only `.notch`, because the pill covers no menu item and a lowered
  window would lose its hover. The system reserve zone (`systemZone`, (686,
  953.5, 140, 39.5)) remains: a click there closes an open card through a global
  mouse monitor that exists only while the card is open.
- **In the menu bar.** `UsageMenuBarItem` creates an `NSStatusItem`
  (variable length, `behavior = []`) among the right-side status items. A click
  or a touch tap (macOS delivers it as a click) toggles a transient `NSPopover`
  (360 x 380 pt, dark appearance, `animates` off under Reduce Motion) with the
  Usage section only and a close button. The popover is rebuilt on each open so
  it takes the current theme.

**8. Status item nuances.**

- The ring is an `ImageRenderer` image of `RafuProgressRing`. For the Monochrome
  palette it is a template image, so the menu bar tints it for a light or dark
  bar. For the Color palette it keeps the theme's ring hue.
- The percent is the button TITLE, not part of the image, so the system colours
  it for light and dark bars. Critical adds "!" to the title (`97%!`), so the
  state is not colour alone. With no usage data the title is empty and the item
  shows the ring track only. The ring is 16 pt on the 45 pt bar and never below 12
  pt (`UsageMenuBarItemText.ringSize`). VoiceOver label and tooltip: "Rafu
  usage. " plus the glance's spoken label.
- `withObservationTracking` is one-shot and its `onChange` fires before the
  change lands, so the item re-arms it on the next main-actor turn. A `lastDrawn`
  value skips the re-render when nothing the drawing reads changed. There is no
  timer.
- Usage refresh runs when the item is installed, when the popover opens (only
  if the last good read is older than 60 s), on a 300 s fallback while the item
  exists, and after an agent turn ends (2026-11-15). Before that fix the item
  refreshed only at install, on popover open and on manual refresh: the 180 s
  timer started only in `NotchCompanionModel.clicked()` for a pinned panel, and
  `clicked()` returns early in menu-bar mode, so the percent never updated by
  itself. The rules are in
  [`usage-rings-and-pace.md`](usage-rings-and-pace.md) (Refresh schedule).
  `teardown(keepingUsageRefresh:)` leaves an in-flight read alone
  when the status item stays: without it a screen-parameter change cancelled the
  item's read and left it blocked by the 60 s TTL.

**9. The macOS 27 "»" overflow (NOTCHED Macs).** The status-item window is at
layer 25. A companion panel at `.statusBar` covers the overflow items that
expand beside the notch. Rule: on macOS 27 or later (`osMajorVersion`,
injectable), while the companion is collapsed on a NOTCH surface
(`hoverState == .resting`, panel closed, no hover pending), the panel orders at
`mainMenu - 1` (23) and the leading wing does not start hover. When the hover
dwell starts, the panel rises to `.statusBar` with `orderFrontRegardless()`; when
the dwell is cancelled it is lowered again. `cancelTimers()` and `hoverExited()`
also apply the layering. The island pill, the plain-display pill, the attention
HUD and macOS 26 or earlier are unchanged. The hover tracker is
`.onContinuousHover` (not `.onHover`) so the view can tell the leading wing apart
by the pointer x. Detecting the open overflow directly was rejected: the window
list does not change, and status items need Accessibility. The policy type is
`CompanionPanelLayering`; prior art is
[FocusIsland PR 14](https://github.com/zeapsu/FocusIsland/pull/14). This fix
depends on item 5 to keep its frame. It is NOT device-verified: the user has no
notched Mac now.

**10. System island sizes from screenshots (pt, about 1 pt accuracy).**

| State | x range | Width | Top | Height |
|---|---|---|---|---|
| Idle | 728 to 784 | 57 to 59 | 8.5 | 31 |
| Music | 688.7 to 819.5 | 131 to 133 | 6.5 to 7 | 33 |
| Hover | 685.5 to 823.3 | 138 to 140 | 5 | 36 |
| Clicked | 613.7 to 898.3 | 285 | 6.4 | 152 |

**11. Public touch API exists; there is none for the island.**
`NSEvent.EventType.directTouch`, `NSTouch.TouchType.direct`,
`NSView.allowedTouchTypes` and related members exist. No public API exposes the
system island or its swipe, so Rafu adds no swipe code. A touch tap is handled
as a click (`onTapGesture`, or the status item's action).

**12. Dock surfaces cannot show usage well.** A Dock trial put a usage ring on
the Dock icon (`NSDockTile.contentView`) and a per-provider `applicationDockMenu`
with "Open Usage". The user found right-click then an item a poor path, and it
was removed. Wide "Dock widgets" are not possible: the Dock gives an app one
square tile. Third-party "Dock widget" apps use floating windows that guess the
Dock's geometry, which is fragile with auto-hide and magnification. Apple's
widget path is WidgetKit (desktop and Notification Center), which needs an
extension, as Live Activities do.

**13. ActivityKit is unavailable on macOS 27.2.** Every ActivityKit symbol in the
27.2 SDK is `@available(macOS, unavailable)` (checked in the
`arm64e-apple-macos.swiftinterface`). Press reports say macOS 27.3 (first beta
early November 2026, release expected December 2026) brings Live Activities to
Macs; they need a WidgetKit extension, which is a large packaging change for a
SwiftPM-built app. `NotchIslandUsageGlance` is a pure `Sendable` value so it can
become content state later. See ADR 0037 for the revisit trigger.

**14. Third-party claims, not verified by Rafu.** One issue on the same model
and OS (vorssaint-utils #3998) reports that the system island is at absolute
level 799 and that the compositor draws a camera-housing outline over every
window. Rafu uses none of this and relies only on the measured layers above.

## Why it matters

Without the classification, an island Mac gets a black band from the screen top
that collides with the system island. Without item 3, a design that puts an
interactive Rafu control beside the island looks right in a screenshot and
receives no input. Without item 5, a lowered window silently moves out of the
band it was placed in. These fail without any crash or log, so a regression looks
like a visual glitch only.

## Reproduction or evidence

- Screen and window measurements: a small Swift script reading `NSScreen` and
  `CGWindowListCopyWindowInfo` on Mac17,13, 2026-11-15. Event routing (item 3),
  the menu-title gap (item 4) and the moved frame (item 5) were observed by the
  user on the device.
- Test coverage: `NotchIslandGeometryTests` (cutout classification, fractional
  inset, frames, nesting, 4 pt pill placement, pixel snap, surface mapping, usage
  glance, `notchPanelKeepsAnInMenuBarFrameBelowTheMenuBarLevel`) and additions in
  `NotchPanelPolicyTests` (layering table, `UsageGlancePosition`,
  `CompanionPresence`, `UsageMenuBarItemText`) and `NotchCompanionModelTests`
  (island tap, sections, presence).
- Build and tests on `main` (Xcode toolchain, macOS 27.2, Mac17,13):
  `./script/build.sh` ended with "Build complete!"; `./script/test.sh
  --no-parallel` passed 443 + 3563 tests; `./script/test.sh` (parallel) passed
  443 + 3563 tests; `./script/build_and_run.sh --verify` launched
  `RafuLightning`. User device check: the "In the menu bar" mode works, and the
  user said it is better than "Below the Dynamic Island".
- Parallel-load flakes seen during the first implementation round, each passing
  alone: `LauncherRequestRouterTests` ("A stopped listener ends its accept thread
  and the same server listens again") and `AgentActivityStoreTests` ("A native
  directory notification drains an atomically written hook event"). They are
  already recorded as scheduler starvation in
  [`../plans/phases/issues-2026-11-06-fanout.md`](../plans/phases/issues-2026-11-06-fanout.md)
  and [`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md). The
  final parallel run passed.

## Not verified

- Escape closing the status-item popover. A status-item click does not activate
  Rafu, so the popover may not get key focus. The code calls `makeKey()` on the
  popover window after `show` and adds `onExitCommand`; the result was not
  checked.
- The overflow "»" fix and the leading-wing rule on a notched Mac on macOS 27.
- Full-screen Spaces, for both the pill and the status item.
- "Below the Dynamic Island" visual match (colour seam with the system island)
  and touch tap delivery into the non-activating pill panel were not recorded as
  checked in the final round.
- Only one island model (Mac17,13) was measured; the island values are
  accurate to about 1 pt.

## Verification

```bash
rg -n "islandCamera|cutout\(for" Sources/RafuApp/Terminal
rg -n "CompanionPanelLayering|CompanionPresence|constrainFrameRect" Sources/RafuApp
swift test --filter NotchIslandGeometryTests
./script/build_and_run.sh --verify
```

Then, on a Mac with a Dynamic Island, set Settings ▸ Notch ▸ Usage glance to "In
the menu bar" and click the item.

## Related code, ADRs, and phases

- [`0037-dynamic-island-macs.md`](../decisions/0037-dynamic-island-macs.md)
- [`notch-companion.md`](notch-companion.md) (geometry, click-through, focus
  rules for the notch; rules 1 and 12 point here)
- [`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md)
  (new pure statics sit in the primary type body)
- [`terminal-notch-hud.md`](../plans/phases/terminal-notch-hud.md) (section
  "Dynamic Island Macs (2026-11-15)")
