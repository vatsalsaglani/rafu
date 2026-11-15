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
- **Amended 2026-11-15:** steps 2 and 3 landed (frosted deck, Ensemble nodes,
  editor and terminals; merge commit de54821). See "Amendment" below.
- **Retains:** theme authority, the unclipped deck, the two-shadow budget, and
  the rule that geometry is Rafu's. The editor and terminal are opaque only when
  the "Frost the editor and terminals" switch is off or the base is Solid (see
  the Amendment).

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

**Not changed.** Popups, sheets, the welcome window, and the notch HUD.
Reduce Transparency and Increase Contrast keep their existing jobs and add this
one. (Step 1 kept the editor and terminal opaque; the Amendment changes that.)

**Migration.** One time, in `RafuApplication.init()`: if the spike default
`RafuFrostSpike` is `"visualEffect"` and no style is set, the style becomes
Frosted (Balanced). All eight `RafuFrostSpike*` keys are then deleted. An
existing user choice is never overwritten.

**Later (step 3).** Done; see the Amendment. How the terminal alpha works is in
[`frosted-window-base.md`](../references/frosted-window-base.md).

## Amendment 2026-11-15: steps 2 and 3 (frosted deck, nodes, editor, terminals)

User requests: "if we can bring some amount of it in the middle part" and "the
same would apply to every ensemble component/node". Merge "frosted deck,
Ensemble nodes, editor and terminals", commit de54821. The step 1 clause
"Retains: an opaque editor and terminal" is removed.

**Setting.** Settings > Appearance > Window > "Frost the editor and terminals",
key `windowSurfaceFrostContent`, default On. Disabled when the base is Solid or
forced Solid. With the switch Off, or in Solid, content is opaque as before.

**Opacity table** (over the blurred desktop; the frame tint is unchanged from
step 1). "Content" is switch On / Off.

| Strength | Frame | Deck | Card | Content |
|---|---|---|---|---|
| Subtle dark | 0.62 | 0.90 | 0.96 | 0.90 / 1 |
| Balanced dark | 0.50 | 0.82 | 0.94 | 0.82 / 1 |
| Strong dark | 0.38 | 0.72 | 0.90 | 0.72 / 1 |
| Subtle light | 0.86 | 0.94 | 0.98 | 0.94 / 1 |
| Balanced light | 0.74 | 0.88 | 0.96 | 0.88 / 1 |
| Strong light | 0.60 | 0.80 | 0.93 | 0.80 / 1 |

**Rule: paint once.** In Frosted the deck card paints no base. Each region
paints its colour exactly once through `rafuDeckFill(color, layer)` or
`windowSurface.fill`, so translucent fills never stack. `DeckLayer` meanings:

- `deck`: tab shelf, breadcrumb, Ensemble board, empty states, guard banner.
- `content`: editor, terminal, Markdown preview, diff, image, video, agent
  session pane, blame.
- `card`: Ensemble cards and board controls. A card paints only the alpha still
  needed over the board: `layeredOpacity a = (target - base) / (1 - base)`. For
  example Balanced dark card is about 0.67 over the board.
- `cardContent`: editor-like content inside a card; clear when frosted.
- `pinned`: sticky headers.
- `underlay`: Solid only.
- `frostedBase`: Frosted only.

Split gaps use `rafuFrameSurface(.app)`.

**Shadow.** In Frosted only, the deck and Ensemble card shadow shapes are masked
to a ring outside the card (`rafuShadowOutsideOnly`: an even-odd rect-minus-
outline mask grown by reach = 2 x blur + y-offset). Solid has no mask.

**Ensemble nodes.** Every node kind uses the card shell's one fill. Read faces
paint nothing in Frosted (note read/compact face, Markdown file card, note
command row, generated view card). Editor-like faces follow the switch (note
editor `NSTextView`, Mermaid source editor, terminal claim placeholder). Board
chrome uses the card layer (tool palette, zoom capsule, notices, minimap, edge
labels, session links bar, silhouette, agent control capsule, restored-links and
refusal capsules, save-failure row). Shape fills were already translucent ink
tints. Strokes, text, selection and focus rings stay opaque. Web card chrome
follows the card; the `WKWebView` content stays opaque.

**Not changed.** Find panel, approval popover, Mermaid/diagram inner tiles,
Markdown code-block background in note cards, terminal exited strip.

**Contract for new code.** Every full-region fill in the deck or on the board
must use `rafuDeckFill` or `windowSurface.fill`, never a direct opaque
`.background(palette...)`. A new node kind must not paint a second card-role
fill. `FrostedDeckContractTests` enforces the main call sites.

**New Frosted-only costs (not measured).** One mask pass for the deck shadow,
one per visible card shadow, and SwiftTerm compositing a non-opaque layer.

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
  opaque fill, or the frost shows a patch of solid colour. Deck and board
  regions follow the same rule through `rafuDeckFill` (see the Amendment).
- AGENTS.md macOS interface rules changed to match (translucency only through
  this opt-in base).

## Revisit trigger

Revisit if the Release WindowServer cost is too high, if per-region backdrops
measure better, or if a future macOS gives a glass surface that blurs the
desktop on a window base. Also revisit after a Release measurement, in Solid and
in Frosted, of typing p95, the `yes | head -200000` terminal flood, and a 40-card
board pan; the Amendment's Frosted-only costs have no numbers yet.

## Related

- Reference: [`frosted-window-base.md`](../references/frosted-window-base.md)
- Phase: [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- Code: `Sources/RafuApp/Settings/WindowSurfacePreference.swift`,
  `Sources/RafuApp/Views/WindowFrostBackdrop.swift`, `RafuApplication.init()`
