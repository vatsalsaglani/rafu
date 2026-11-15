# Frosted window base: what works on macOS 27.2 and how to check it

- Applies to: the optional frosted window base
  (`Sources/RafuApp/Views/WindowFrostBackdrop.swift`,
  `Sources/RafuApp/Settings/WindowSurfacePreference.swift`,
  `rafuFrameSurface`, and the deck corner wedges in
  `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`)
- Last verified: Xcode with macOS 27.2 SDK (26B118), Swift 6 language mode,
  Darwin 27.2.0, Mac17,13, 2026-11-15. Merged to `main`; build OK; parallel
  and `--no-parallel` both green on `main`, each reported as 451 tests in 31
  suites plus 3708 tests in 301 suites (the two test targets). Rafu Lightning
  launched from `main` and the one-time migration set `windowSurfaceStyle =
  frosted`, `windowSurfaceFrost = balanced`. GUI checks of the final build are
  not done (see the phase work log).

## Rule or observed behavior

1. **A behind-window `NSVisualEffectView` needs no `isOpaque = false`.** It
   blurs the real desktop with `NSWindow.backgroundColor` and `isOpaque`
   unchanged. Rafu uses `.behindWindow`, material `.hudWindow`, state `.active`.
2. **Use `.active`, not `followsWindowActiveState`.** The following state turns
   the frost flat grey on every focus change. `.active` keeps the frost when the
   window is inactive; the user approved that.
3. **Liquid Glass gives no desktop blur as a base.** On an opaque window,
   `NSGlassEffectView`, SwiftUI `glassEffect`, and
   `containerBackground(.ultraThinMaterial, for: .window)` show no desktop. On a
   clear window, `NSGlassEffectView` shows the desktop sharp and tinted, with
   no blur. Glass stays an option for small controls only.
4. **SwiftUI `Material` blurs only inside the window.** It cannot frost the
   desktop.
5. **`maskImage` is the reliable mask on a behind-window view.** Rafu uses it
   for the deck corners: four 2r x 2r tiles with an even-odd continuous-corner
   image. **Cache the image**, because `updateNSView` compares by identity.
6. **`screencapture -l<windowid>` does not show behind-window blur.** Use a
   region capture of the screen (`screencapture -R`) instead.
7. **The spike defaults are the source of "Balanced dark".** The user approved
   Indigo with tint 0.5; that is Balanced dark (0.50). Table and the rest of the
   decision: [ADR 0038](../decisions/0038-optional-frosted-window-base.md).
8. **Frame surfaces paint nothing in Frosted.** `rafuFrameSurface(.app /
   .sidebar / .statusBar)` paints its token only in Solid. A direct opaque fill
   on a frame surface leaves a solid patch in Frosted, and nested paints would
   stack. A theme's distinct `sidebarBackground` is not shown in Frosted.
9. **Terminal alpha (step 3, not done).** SwiftTerm uses the CoreGraphics path
   with RGBA layer contents, so alpha is feasible without patching it.
   SwiftTerm sets `layer.backgroundColor` once in `setupOptions` from the
   default `textBackgroundColor`; Rafu must clear `view.layer.backgroundColor`
   in `applyTheme`.

## Why it matters

- Spike evidence decided the mechanism; without it a later change could swap
  in Liquid Glass or a Material and lose the desktop blur without any error.
- A screenshot with `-l` makes a working frost look broken, so a reviewer might
  report a false failure.
- Cost, from the spike (Debug build, busy Mac, rough): WindowServer CPU +4 to
  +5 points (17.3 to 22.6 % with a moving backdrop; 16.1 to 20.4 % static).
  Rafu memory changed by less than 1 MB. These are not Release numbers.
  **Re-measure in Release.**

## Reproduction or evidence

The spike (debug default `RafuFrostSpike`; keys migrated and deleted by
`RafuApplication.init()`) produced screenshots in a temporary scratchpad folder
that may be gone. The findings above are the durable record.

## Verification

Manual, Rafu Lightning only (never the release `Rafu` process):

1. `./script/build_and_run.sh --verify`.
2. Settings > Appearance > Window: switch "Window background" between Solid and
   Frosted; step Frost through Subtle, Balanced, Strong, in Indigo and Khadi.
   Frost is disabled when Solid.
3. System Settings > Accessibility > Display: turn on Reduce Transparency, then
   Increase Contrast. The window must go Solid at once and the setting shows
   the footer that explains why.
4. Open a second window; it must follow the setting.
5. Capture with a region (`screencapture -R`), never `-l`.
6. Footprint of `pgrep -x RafuLightning`, and WindowServer CPU with Solid and
   with Frosted in the same scene, in a Release build. The exact commands the
   spike used were not recorded in the handoff; record them here when the
   Release measurement is made.

Automated: the pure resolver `WindowSurfacePreference` is covered by the
`main` gates above; the test names were not supplied.

## Related code, ADRs, and phases

- [ADR 0038](../decisions/0038-optional-frosted-window-base.md); amends ADRs
  0012, 0022, 0030, 0031
- [`workbench-deck-corner-wedges.md`](workbench-deck-corner-wedges.md)
- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- [`sidebar-panel-anatomy-and-terminal-rows.md`](sidebar-panel-anatomy-and-terminal-rows.md)
