# 0037. Usage surfaces on Macs with a system Dynamic Island

- Status: Accepted (user direction), 2026-11-15. Device-verified on Mac17,13
  (macOS 27.2) for the "In the menu bar" position; the remaining device checks
  are in the phase document.
- Phase: [`../plans/phases/terminal-notch-hud.md`](../plans/phases/terminal-notch-hud.md)
  (section "Dynamic Island Macs (2026-11-15)")
- Reference: [`../references/dynamic-island-macs.md`](../references/dynamic-island-macs.md)

## Context

The notch companion, the attention HUD, the voice orb and the mascot were built
for a notch. The user now has a Mac with a hole-punch camera and a system
Dynamic Island (Mac17,13, macOS 27.2). On that Mac the old geometry still
returned a rect (59 x 40) and Rafu treated it as a notch. Rafu's black band
started at the screen top, next to a system island that floats below the top
edge and is drawn above every app window.

The user asked for a result that is "seamless and good". On the island the user
wants only the Usage section first. The screen is a touch screen: a touch must
act as a click.

No public API puts content into the system island on macOS 27.2. ActivityKit is
present in the 27.2 SDK but every symbol is `@available(macOS, unavailable)`.

A first design drew one black "shared island" capsule beside the system island,
inside the menu-bar band. Device checks showed that it cannot work: the menu bar
leaves only about 106 to 109 pt around the island, and MenuBarAgent gives every
hover and tap in that band to the system island, so a Rafu surface there is
never interactive. The decision below replaces that design.

## Decision

1. **Classification.** A screen is `none`, `notch` or `islandCamera`. The camera
   housing width is derived as before. The screen is an island camera when the
   housing width is less than 3 times the top safe-area inset; otherwise it is a
   notch. If the derivation fails, the screen is `none`.
   `NotchHUDGeometry.notchRect` returns a rect only for `.notch`, so every
   consumer that already asked for a notch treats an island Mac as "no notch".
2. **No interactive surface in the menu-bar band around the island.** On an
   island Mac Rafu puts no window in that band and expects no hover or tap
   there. No public API changes this routing.
3. **Two positions, one setting.** On island Macs only, Settings ▸ Notch has
   "Usage glance" (key `notchUsageGlancePosition`, values `belowIsland` and
   `menuBar`, default `belowIsland`; an unknown stored value reads as the
   default).
   - "Below the Dynamic Island": a black pill (109 x 33 pt on Mac17,13) hangs 4
     pt below the menu bar, centred under the island. It shows the mascot on the
     left and the usage ring on the right. Hover widens it to 282 pt and adds the
     percent. A click or tap opens a Usage-only card that grows down from the
     pill. The pill covers no menu item, so the macOS 27 lowering rule never
     applies to it.
   - "In the menu bar": an `NSStatusItem` among the other apps' right-side
     status items shows the usage ring and the percent. A click or tap opens a
     transient `NSPopover` (360 x 380 pt, dark) with the Usage section only and a
     close button.
   The pure type `CompanionPresence.resolve(surface:position:isEnabled:)` decides
   which surface exists. Notched and plain-display Macs keep the panel and never
   get a status item.
4. **Usage only.** On the island surface the companion offers the Usage section
   only. The rule is a pure function (`NotchSection.offered(_:on:)`). It writes
   no stored section flag and no remembered tab, so the user's choices for a
   notched Mac stay unchanged. Now Playing stops on the island surface because it
   reads the visible sections. The attention bell always uses the drop-down HUD
   on an island (no feed there). Hover never opens the card on an island; the
   "Open when the pointer rests on the notch" setting is disabled there.
5. **No private API.** Rafu uses `NSScreen.safeAreaInsets`,
   `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` only.
6. **Window levels.** `NotchHUDPanel` keeps `.statusBar` and its collection
   behaviour, with two additions:
   - It overrides `constrainFrameRect(_:to:)` to return the frame unchanged,
     because AppKit moves a window ordered below the menu-bar level out of the
     menu-bar band. Every frame is already clamped to the screen by the pure
     geometry.
   - macOS 27 menu-bar overflow fix, for a NOTCHED Mac only: on macOS 27 or
     later, while the companion is collapsed on a notch surface, the panel
     orders at `mainMenu - 1` (23) and the leading wing does not start hover. The
     panel rises to `.statusBar` (25) when the hover dwell starts and is lowered
     again when the dwell is cancelled. The island pill, the plain-display pill,
     the attention HUD and macOS 26 or earlier do not change.
7. **No swipe code.** Rafu adds no handler for the swipe gesture on the island.
8. **Live Activities deferred.** A real system-island presence needs ActivityKit
   and a WidgetKit extension. That is a later phase.
   `NotchIslandUsageGlance` is a pure `Sendable` value so it can become content
   state later.

## Alternatives considered

- **A shared in-band island: one black capsule beside the system island inside
  the menu-bar band (the first design).** Rejected on device evidence. (a) At the
  macOS 27 overflow level (23) AppKit moved the capsule to y 45, below the menu
  bar. (b) A 228 pt capsule sat under menu titles. The menu bar leaves a gap of
  only about 106 to 109 pt (titles end at about 699 to 701 pt and resume at about
  805 to 807 pt on a 1512 pt screen), and the gap grows while the system island
  shows an activity. (c) Even at 109 pt the capsule got no hover and no tap:
  MenuBarAgent gives them to the system island. The evidence is in the reference
  note.
- **A usage ring on the Dock icon, with a Dock menu** (`NSDockTile` content view
  and `applicationDockMenu`). It was built and removed: the user found
  right-click then an item a poor path to usage.
- **Dock widgets.** Not possible: the Dock gives an app one square tile. Apps that
  offer "Dock widgets" use floating windows that guess the Dock's geometry, which
  breaks with auto-hide and magnification. Apple's widget path is WidgetKit
  (desktop and Notification Center), which needs an extension, as Live Activities
  do.
- **Cover or join the system island with a private Space.** Third-party reports
  describe private CGS Space calls that rank above the island. That is private
  API and fragile across macOS updates. Rejected under the architecture rule on
  private API.
- **Handle the island swipe.** No public API exists for the system island or its
  swipe. Public touch API exists (`NSEvent.EventType.directTouch`,
  `NSTouch.TouchType.direct`, `NSView.allowedTouchTypes`), but it cannot read a
  gesture that the system island owns. Rejected.
- **Detect the open "»" overflow directly and lower only then.** It needs a
  window-list change that Rafu does not observe, and reading status items needs
  Accessibility permission. Rejected; the rule uses only Rafu's own state. A
  macOS 27 layering change was used by prior art
  ([FocusIsland PR 14](https://github.com/zeapsu/FocusIsland/pull/14)).
- **Show all four sections on the island.** The user asked for Usage first.
  Rejected for this round.
- **Live Activities and WidgetKit now.** Deferred; see the revisit trigger.

## Consequences

- An island Mac gets a Usage-only companion in one of two places; notched Macs
  and no-cutout Macs keep their current frames, shapes, hover rules and sections.
- The user judged "In the menu bar" better than "Below the Dynamic Island"
  ("it's working and better than below the Dynamic Island"). The default stays
  `belowIsland`; the user chooses the other position in Settings.
- The menu-bar item shows only the most constrained usage window. It uses the
  system's own text colour, so it follows a light or dark menu bar.
- The collapsed companion on a macOS 27 NOTCHED Mac has no hover over its leading
  wing. The user reaches the companion by the housing or the trailing wing. This
  path is not device-verified (the user has no notched Mac now).
- The island values (4 pt gap, 33 pt height, 28 pt card radius, system island
  sizes) came from screenshots and are accurate to about 1 pt. Only one island
  model was measured.
- The status item does not activate Rafu, so Escape may not reach the popover.
  This is unverified.

## Revisit trigger

Revisit decision 8 when both of these are true: macOS 27.3 is released, and
ActivityKit is available (not `unavailable`) on macOS in the SDK. Then decide
whether a WidgetKit extension fits Rafu's SwiftPM-built bundle. Revisit decision
2 if Apple documents a way for an app window to receive events in the menu-bar
band around the island. Revisit decision 6 if Apple changes the status-item
window level.

## Related paths

- `Sources/RafuApp/Terminal/NotchHUDGeometry.swift`
- `Sources/RafuApp/Terminal/NotchIslandGeometry.swift`
- `Sources/RafuApp/Terminal/NotchCompanionGeometry.swift`
- `Sources/RafuApp/Terminal/NotchCompanionPolicy.swift`
  (`CompanionPanelLayering`, `CompanionPresence`, `UsageMenuBarItemText`,
  `NotchIslandUsageGlance`)
- `Sources/RafuApp/Terminal/NotchCompanionModel.swift`
- `Sources/RafuApp/Terminal/NotchHUDWindow.swift` (`constrainFrameRect`)
- `Sources/RafuApp/Notch/UsageMenuBarItem.swift`
- `Sources/RafuApp/Notch/NotchDisplayPreferences.swift` (`UsageGlancePosition`)
- `Sources/RafuApp/Notch/NotchSettingsSection.swift`
- `Sources/RafuApp/Views/NotchCompanionView.swift`
- `Tests/RafuAppTests/NotchIslandGeometryTests.swift`
