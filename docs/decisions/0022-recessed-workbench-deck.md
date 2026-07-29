# ADR 0022: Recessed workbench deck and compact surface geometry

- **Status:** Proposed (records the user's 2026-07-29 presentation direction;
  implementation has not begun)
- **Date:** 2026-07-29
- **Supersedes on acceptance:** ADR 0012's flush-main-pane composition,
  single-radius-scale wording, and rejection of all main-pane gutters

## Context

ADR 0012 replaced system-material chrome with flat, theme-driven surfaces. It
chose flush main panes separated by hairlines, reserved rounded cards for
embedded/overlay content, and established a 12/7/8 pt panel/control/field radius
scale. That pass removed the dated material and toolbar cues, but dogfooding the
result showed a new problem: Files, editor, utility panels, and split editor
groups still read as one edge-to-edge plane, while embedded cards remain much
rounder and heavier.

The user supplied four new desktop-app references and twelve current Rafu
captures. Their explicit direction is to adopt the references' tucked depth,
very narrow gutters, small radii, attached/cozy tabs, terminal layout framing,
and session-colored borders around the actual editor-hosted terminal.

This activates ADR 0012's revisit trigger: user testing now says the flush base
reads too plain versus a measured guttered alternative. The technical premise
behind ADR 0012's original rejection has also changed. Rafu already replaced
`NavigationSplitView` with an AppKit-backed `HSplitView`; the new composition
does not require introducing a second custom split system or accepting macOS 26
Liquid Glass.

The full implementation contract is
[`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md).

## Decision

On acceptance, Rafu adopts one narrowly recessed **workbench deck**:

- The window backing plane, Files surface, activity rails, and status bar remain
  edge-attached structural chrome.
- The editor plus an open right utility panel form one working deck inset 4 pt
  from that structural chrome.
- Depth comes from the revealed theme surface, a 6 pt exposed deck corner, and a
  1 pt theme border. There is no shadow, material, blur, bevel, or gradient.
- Internal editor and utility columns continue to use the existing native
  `HSplitView`/`VSplitView` resizing and hairline seams.
- Adjacent editor groups target 4 pt of visible separation from group edge to
  group edge, including the native splitter, with one-physical-pixel tolerance
  at 1× and 2×. The splitter paints inside that band and retains its larger
  invisible resize target; its thickness is not added on top of two fixed leaf
  insets. Each group uses a 5 pt bounded surface.
- Selected tabs become 4 pt top-rounded attached caps filled with
  `tabActiveBackground`, outlined on their top/sides, and open at the bottom so
  they visually join their content. A stitched accent edge may remain as a
  secondary Rafu motif, never the only selected state.
- An editor-hosted terminal uses the existing session-color resolution for an
  inset identity accent around its complete group perimeter while retaining a
  neutral theme-resolved structural boundary. Focus increases line weight and
  remains paired with tab shape, provider/name, and status; a custom color that
  matches the canvas therefore cannot erase structure, and color is never the
  only signal.
- Geometry gains a compact semantic workbench tier. The existing 12 pt
  `radiusPanel` remains available for genuine overlays and sheets; it is no
  longer the implied radius for dense workbench panes and embedded composers.

Color remains entirely under the existing JSON theme contract:

- `appBackground` is the revealed backing/gutter.
- `sidebarBackground` owns Files and rails.
- `editorBackground` owns the working deck.
- `elevatedBackground`, `tabBarBackground`, `tabActiveBackground`,
  `cardBackground`, `fieldBackground`, borders, selection, and accent roles own
  their existing semantics.
- No new required or optional JSON key is needed for this decision.
- `TerminalSessionColor.custom` remains the existing explicit user-picked-color
  exception; Rafu itself introduces no hard-coded product color.

## Relationship to earlier decisions

- ADR 0002 and ADR 0003 remain unchanged: Files stays left, utilities stay
  right, diffs/details stay editor-hosted, and the rails remain the only
  permanent custom navigation chrome.
- ADR 0012's theme authority, flat tonal layering, no-Liquid-Glass rule,
  accessibility requirements, `HSplitView`, no-`NSToolbar` titlebar treatment,
  and native-control preference remain in force.
- This decision supersedes only ADR 0012's flush-main-pane composition, its
  universal-looking radius scale, and its blanket rejection of a main working
  gutter.
- ADR 0014 and ADR 0021 remain unchanged: terminals stay ephemeral
  editor-tab peers with the same process, auth, environment, hide/close, and
  lifecycle boundaries.
- ADR 0018 remains unchanged: user-visible prose says **Ensemble** and internal
  Swift symbols keep `Conductor*`.

## Alternatives considered

### Keep ADR 0012 unchanged and restyle only controls

Rejected. The screenshots show that the remaining gap is composition, not
control polish. More chips, rounded cards, or accent washes would intensify the
current mismatch without giving the editor a front/back relationship.

### Float every pane as an independent card

Rejected. It would add excess gutters, radii, and nested containers, weaken the
native splitter relationship, and make the workbench read like a web dashboard.
The decision introduces one working deck and small group gaps, not cards around
Files, Search, Git, terminal lists, and every editor surface.

### Reintroduce `NavigationSplitView` for its inset sidebar

Rejected. macOS 26 supplies a Liquid Glass elevated sidebar with system shadow
and margins that contradict Rafu's opaque theme surfaces and Reduce
Transparency contract. The current `HSplitView` stays.

### Put geometry in theme JSON

Rejected. Users own color; Rafu owns interaction geometry. Theme-specific
radii/gutters would fragment hit targets, split behavior, and product identity.

### Assign automatic rainbow colors to terminal sessions

Rejected. It would overload semantic colors and create an identity policy the
user did not ask Rafu to own. Existing theme presets and explicit user choices
carry through when assigned; uncolored sessions remain neutral.

## Consequences

- `RafuMetrics` needs semantic workbench constants instead of a global radius
  reduction.
- A shared workbench-surface layer should centralize deck, attached-tab,
  editor-group, terminal-border, panel-header, and empty-state geometry.
- `tabActiveBackground`, already decoded from every theme with a fallback, gains
  its intended editor-tab use.
- The window and editor composition require high-risk interaction checks:
  splitter hit targets, tab drag geometry, TextKit/SwiftTerm focus, and
  multi-window ownership.
- Opaque child surfaces mean exposed corners use non-hit-testing theme-colored
  corner cutouts plus border overlays; the workbench must not mask or clip a
  TextKit/SwiftTerm viewport merely to obtain rounded chrome.
- Settings and Ensemble can use the same compact surface grammar without
  changing their routing, lifecycle, process, or trust contracts.
- Light and imported-theme parity are gates for every visible increment.
- `ui-design-language.md` and `settings-surface.md` must be updated when the
  implementation replaces their currently verified layout rules.

## Revisit trigger

Revisit if measured minimum-window usability, splitter accessibility, TextKit or
SwiftTerm focus, Increase Contrast, or imported-theme testing shows that the 4 pt
deck/group spacing obscures content or weakens native interaction. Prefer
adjusting the compact metric tier before returning to shadows, materials, or
per-theme geometry.

## Related

- [`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
- [`0012-flat-workbench-chrome.md`](0012-flat-workbench-chrome.md)
- [`ui-design-language.md`](../references/ui-design-language.md)
- `Sources/RafuApp/Support/RafuMetrics.swift`
- `Sources/RafuApp/Support/RafuTheme.swift`
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`
