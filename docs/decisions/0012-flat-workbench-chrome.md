# ADR 0012: Flat, layered workbench chrome

- **Status:** Proposed
- **Date:** 2026-07-18

## Context

Hands-on review found the workbench "looks like an older Mac app." The dated
cues are structural, not palette: system-material sidebars, a heavy toolbar
band, mixed control styling, and depth expressed through materials rather than
tone. The user supplied modern references (Conductor's macOS app, plus several
web builder/chat tools) and asked for something "flat, modern … out of the new
world" while keeping every custom and out-of-the-box theme intact.

The earlier polish pass ([`workbench-visual-polish.md`](../plans/phases/workbench-visual-polish.md))
already softened AGENTS' "use system-adaptive chrome … do not paint native
sidebars with opaque custom backgrounds" rule by tinting the sidebar over the
system material at 0.85 opacity. Going fully flat is a durable, product-wide
appearance decision among real alternatives, so it is recorded here rather than
absorbed silently into a phase brief.

The full surface-by-surface plan is
[`ui-flat-modern-refresh.md`](../plans/phases/ui-flat-modern-refresh.md).

## Decision

Adopt a flat, layered visual language for **workspace-window chrome**:

- Depth comes from two or three tonal steps of theme surfaces (canvas →
  panel → card/field) separated by 1px hairline borders — not from system
  materials, blur stacks, shadows, or bevels. Main panes are flush,
  hairline-divided flat surfaces (Conductor-style); overlays and embedded
  content use a rounded-card language.
- Geometry is a single continuous-corner scale defined in code
  (`RafuMetrics`): panels ~12pt, controls ~7pt, fields ~8pt, capsule chips.
  Shape is product identity and stays out of theme JSON.
- Color remains entirely the theme's. New appearance needs are met by
  reusing existing tokens and by a small set of **optional** `ui` keys with
  derived fallbacks (`cardBackground`, `fieldBackground`, `chipBackground`,
  `accentSoft`), so all bundled, user, and AI-generated themes render
  identically until they opt in. No breaking theme-schema change.
- Native macOS behavior is retained: toolbar items, menus, traffic lights,
  standard controls, sheets, popovers, `NavigationSplitView`, and every
  accessibility affordance (VoiceOver, Full Keyboard Access, Reduce Motion,
  Reduce Transparency, Increase Contrast). Settings and system alerts stay
  native.

Reduce Transparency collapses every translucency wash to its solid token;
Increase Contrast promotes `borderSubtle` to `borderStrong` on interactive
boundaries; Reduce Motion replaces overlay springs with cross-fades.

## Alternatives considered

- **Floating cards-with-gutters for the main panes** (like the web
  references). Rejected as the base: it would mean replacing
  `NavigationSplitView` with a custom split, forfeiting native sidebar
  behaviors, for a look that reads as a web app rather than a native macOS
  tool. The card language is kept for overlays and embedded content, where it
  belongs.
- **Keep system materials, restyle only controls.** Rejected: the material
  sidebars and toolbar band are the primary "old Mac app" cues; leaving them
  is the thing being fixed.
- **Recreate Liquid Glass / heavy translucency.** Rejected: explicitly out of
  scope in AGENTS and at odds with the flat direction; also a legibility and
  Reduce-Transparency liability.
- **Per-surface radii in theme JSON.** Rejected: geometry is identity, not
  theme; per-theme shapes would fragment the product's feel.

## Consequences

- Supersedes the AGENTS "system-adaptive chrome / do not paint native
  sidebars" guidance for workspace windows (Settings unaffected). AGENTS'
  macOS-interface rules are amended in the same work that lands U1.
- Themes gain four optional keys; the AI theme-generation prompt advertises
  them; fallbacks guarantee old JSONs are unchanged.
- Flat surfaces with hairlines must be audited for contrast in light themes
  (Khadi), so light-theme parity is a gate on every increment, not an
  afterthought.
- Removing materials removes their automatic vibrancy; text legibility over
  the flat theme surfaces is now the theme's responsibility, checked under
  Increase Contrast.

## Revisit trigger

If a future macOS introduces a system material that is both flat-compatible
and accessibility-safe, or if user testing shows the flush-panel base reads as
too plain versus a measured card alternative, revisit the base-composition
choice (D1 in the phase plan).

**Amendment (2026-07-19):** `NavigationSplitView` was replaced with an
AppKit-backed `HSplitView` in `WorkspaceWindowView`. On macOS 26,
`NavigationSplitView` floats its sidebar as an inset, rounded, elevated
Liquid Glass card whenever the window is key — visible elevation, shadow,
and margins that directly contradict this ADR's flat-chrome decision and
its "no Liquid Glass" consequence, regardless of the sidebar's own
background token. `HSplitView` keeps the sidebar an ordinary flush pane
while preserving drag-to-resize behavior. Because `NavigationSplitView`
used to contribute the system sidebar toggle automatically, the toolbar now
adds exactly **one** custom toggle button (`sidebar.left`, driving
`session.toggleSidebar()` / `session.isSidebarCollapsed`), satisfying ADR
0002's "never duplicates the system sidebar toggle" rule with a
single explicit replacement rather than a second, competing toggle. ⌘B
continues to drive the same state. No other consequence of this ADR
changes.

## Amendment (2026-07-21): no `NSToolbar` at all; the titlebar carries the title

The custom toolbar toggle introduced by the amendment above is **withdrawn**,
and Rafu now carries **no `NSToolbar`**. Two macOS 26 behaviors made a
toolbar untenable for this ADR's flat chrome:

1. **Every toolbar item is wrapped in a Liquid Glass capsule** with a border
   and drop shadow. This applies to a bare `Text` used as a `.principal`
   item too, so the centered window title rendered as a floating pill — the
   same elevation this ADR exists to remove.
2. **A window with a toolbar keeps its titlebar band permanently on screen
   in full screen** (the Safari behavior), costing roughly 52pt of vertical
   space. Without a toolbar, AppKit auto-hides the titlebar in full screen
   and reveals it when the pointer reaches the top edge.

Removing the toolbar does **not** center the system title, as first assumed:
with `titlebarAppearsTransparent` the title draws at the **leading** edge,
jammed against the traffic lights. Rafu therefore hides the system title
(`titleVisibility = .hidden`) and draws no title text of its own: the title
still identifies the window in Mission Control and the Window menu, while the
workspace is identified by the sidebar and status bar. `FlatWindowChrome`
(`Sources/RafuApp/Views/FlatWindowChrome.swift`) sets `fullSizeContentView`
+ `titlebarAppearsTransparent` directly on the `NSWindow`, because
`.toolbarBackground(.hidden, for: .windowToolbar)` only takes effect while a
toolbar exists.

Applying that chrome **once is not enough**: AppKit rebuilds the window's
frame view across a full-screen transition and restores the stock titlebar
(`titleVisibility` back to `.visible`, `titlebarAppearsTransparent` back to
`false`). After a full-screen round trip the opaque system band therefore
reappeared, drew its leading title, and covered the title bar Rafu renders in
that same zone — taking the sidebar toggle with it. `FlatWindowChrome`
re-applies the chrome on `didEnterFullScreen`/`didExitFullScreen`, and on
`didBecomeKey` as a cheap net for any other reset.
`FlatWindowChromeTests` pins this (verified non-vacuous: reverting the
re-apply fails them).

**SwiftUI cannot lay content out inside the titlebar zone.** Verified three
ways against the running app (screen-captured each time), all of which
rendered nothing at all: `.ignoresSafeArea(.container, edges: .top)` on the
window `VStack`, the same modifier on the title bar alone, and a top
`.overlay` ignoring the safe area. Only *backgrounds* bleed into that zone.
Anything Rafu draws must therefore live BELOW the titlebar zone. That is why
the horizontal title bar was abandoned in favour of the left rail (below):
the bar could not share the traffic-light row, so it cost a second ~28pt row.
The zone itself is coloured by setting `NSWindow.backgroundColor` to the
sidebar fill, so the strip carrying the traffic lights blends into the app
chrome instead of reading as a foreign band.

ADR 0002's single-toggle rule still holds. The one sidebar toggle lives in
`WorkspaceSidebarRail`, a slim vertical icon rail on the window's LEFT edge
that mirrors the existing `WorkspaceUtilityRail` on the right. A rail costs
no vertical space, stays visible when the sidebar is collapsed, and needs no
full-screen special-casing. Two earlier placements were withdrawn: the status
bar (undiscoverable) and a horizontal title bar (which, because SwiftUI
cannot draw into the titlebar zone, had to sit below it and cost ~56pt of
vertical chrome). ⌘B continues to drive the same state. No other consequence
of this ADR changes.

## Related plan, reference, and implementation paths

- Plan: [`ui-flat-modern-refresh.md`](../plans/phases/ui-flat-modern-refresh.md)
- Metrics: `Sources/RafuApp/Support/RafuMetrics.swift`
- Palette/tokens: `Sources/RafuApp/Support/RafuTheme.swift`
- Control styles: `Sources/RafuApp/Support/RafuControlStyles.swift`
- AI prompt: `Sources/RafuApp/AI/AIThemePrompt.swift`
