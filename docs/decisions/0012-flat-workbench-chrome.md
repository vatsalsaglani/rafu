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

## Related plan, reference, and implementation paths

- Plan: [`ui-flat-modern-refresh.md`](../plans/phases/ui-flat-modern-refresh.md)
- Metrics: `Sources/RafuApp/Support/RafuMetrics.swift`
- Palette/tokens: `Sources/RafuApp/Support/RafuTheme.swift`
- Control styles: `Sources/RafuApp/Support/RafuControlStyles.swift`
- AI prompt: `Sources/RafuApp/AI/AIThemePrompt.swift`
