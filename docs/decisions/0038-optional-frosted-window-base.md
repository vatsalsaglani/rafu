# ADR 0038: Optional frosted window base

- **Status:** Accepted (2026-11-15) on the user's explicit direction. The user
  saw and approved the frost in a spike build (Indigo, tint 0.5), then asked
  for it to be a setting and for the frame gaps to be tightened.
- **Date:** 2026-11-15
- **Amends:**
  - [ADR 0012](0012-flat-workbench-chrome.md): the "no system materials /
    heavy translucency" rule and its Reduce Transparency sentence, through its
    own revisit clause
  - [ADR 0022](0022-recessed-workbench-deck.md),
    [ADR 0030](0030-framed-workbench-left-rail-and-detached-tabs.md),
    [ADR 0031](0031-card-header-tabs-and-themed-chrome.md): the "opaque tonal
    surfaces / no material, blur" clauses and "Reduce Transparency stays a
    no-op"
- **Retains:** theme authority, an opaque editor and terminal, the unclipped
  deck, the two-shadow budget, and the rule that geometry is Rafu's

## Context

The user wants the window frame (titlebar row, rail, sidebar, status bar, deck
gutter) to show a blurred desktop, as a choice. ADR 0012 had excluded system
materials and heavy translucency, and ADRs 0022, 0030 and 0031 repeated that
Reduce Transparency stays a no-op because nothing was translucent. The user has
also lifted the "no Liquid Glass" rule. A spike (a debug default,
`RafuFrostSpike`) tested the options on macOS 27.2 before this decision.

Spike findings (the screenshots are in a temporary folder, so the findings are
named here):

- A behind-window `NSVisualEffectView` blurs the real desktop. It needs no
  `isOpaque = false` on the window.
- `NSGlassEffectView`, SwiftUI `glassEffect`, and
  `containerBackground(.ultraThinMaterial, for: .window)` show no desktop on an
  opaque window. On a clear window `NSGlassEffectView` shows the desktop sharp
  and tinted, with no blur. Glass is therefore not a usable base.
- A SwiftUI `Material` blurs only what is inside the window.
- `followsWindowActiveState` flips the frost to a flat grey on every focus
  change, so the view uses `.active`. The user approved a frost that stays when
  the window is inactive.

## Decision

Add an opt-in **frosted window base**. Default is Solid, so a user who changes
nothing sees no translucency.

**Setting.** Settings > Appearance > Window:

- "Window background": Solid / Frosted (default Solid).
- "Frost": Subtle / Balanced / Strong. Disabled when the style is Solid or
  when it is forced Solid.
- UserDefaults keys `windowSurfaceStyle` and `windowSurfaceFrost`. The pure
  resolver `WindowSurfacePreference`
  (`Sources/RafuApp/Settings/WindowSurfacePreference.swift`) maps a missing or
  unknown style to Solid and a missing or unknown strength to Balanced.
- Reduce Transparency or Increase Contrast forces Solid. A footer in the
  setting says why.

**Mechanism.**

- One `NSVisualEffectView`: `.behindWindow`, material `.hudWindow`, state
  `.active`. It is mounted under `workbenchContent` only in Frosted, and never
  for the welcome window (`Sources/RafuApp/Views/WindowFrostBackdrop.swift`).
- One `appBackground` tint at the root, at the opacity of the chosen strength.
- `rafuFrameSurface(.app / .sidebar / .statusBar)` paints the token in Solid and
  nothing in Frosted, so the nested sidebar paints do not stack. Cost: a theme
  with a distinct `sidebarBackground` loses that difference in Frosted.
- Deck corners: four masked `.behindWindow` wedge views, each a 2r x 2r tile
  with an even-odd continuous-corner `maskImage` (cached), plus the existing
  masked wedge ZStack tinted with `appBackground.opacity(tint)`. The deck is
  never clipped.
- `NSWindow.backgroundColor` and `isOpaque` are unchanged.

**Tint table** (`appBackground` opacity over the blur):

| Strength | Dark | Light |
|---|---|---|
| Subtle | 0.62 | 0.86 |
| Balanced | 0.50 | 0.74 |
| Strong | 0.38 | 0.60 |

Balanced dark (0.50) is the value the user approved in the spike.

**Not changed.** Popups, sheets, the welcome window, and the notch HUD. The
editor and terminal stay opaque. Reduce Transparency and Increase Contrast keep
their existing jobs and add this one.

**Migration.** One time, in `RafuApplication.init()`: if the spike default
`RafuFrostSpike` is `"visualEffect"` and no style is set, the style becomes
Frosted (Balanced). All eight `RafuFrostSpike*` keys are then deleted. An
existing user choice is never overwritten.

**Later (step 3, not done).** A translucent terminal is feasible without
patching SwiftTerm: it uses the CoreGraphics path with RGBA layer contents.
SwiftTerm sets `layer.backgroundColor` once in `setupOptions` from the default
`textBackgroundColor`, so Rafu must clear `view.layer.backgroundColor` in
`applyTheme`.

## Alternatives considered

- **SwiftUI `Material`.** Rejected. It blurs only inside the window.
- **Liquid Glass (`NSGlassEffectView`, `glassEffect`, window container
  background).** Rejected for the base, for the spike findings above. It stays
  an option for small controls.
- **Clip the deck to a rounded shape.** Rejected. It breaks the rule that the
  deck never clips TextKit or SwiftTerm content.
- **One backdrop per region instead of one backdrop.** Not chosen. To be
  measured.

## Consequences

- Frosted costs WindowServer CPU. Spike measurement, Debug build, busy Mac,
  rough: +4 to +5 points (17.3 to 22.6 % with a moving backdrop; 16.1 to 20.4 %
  static). Rafu memory changed by less than 1 MB. **Re-measure in Release.**
- Reduce Transparency and Increase Contrast now have a visible effect in the
  window frame: they force Solid.
- A theme's distinct `sidebarBackground` is ignored in Frosted.
- Frame surfaces must be painted through `rafuFrameSurface`, never a direct
  opaque fill, or the frost shows a patch of solid colour.
- AGENTS.md macOS interface rules changed to match (translucency only through
  this opt-in base).

## Revisit trigger

Revisit if the Release WindowServer cost is too high, if per-region backdrops
measure better, if a future macOS gives a glass surface that blurs the desktop
on a window base, or if the terminal gets alpha (step 3).

## Related

- Reference: [`frosted-window-base.md`](../references/frosted-window-base.md)
- Phase: [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- Code: `Sources/RafuApp/Settings/WindowSurfacePreference.swift`,
  `Sources/RafuApp/Views/WindowFrostBackdrop.swift`, `RafuApplication.init()`
