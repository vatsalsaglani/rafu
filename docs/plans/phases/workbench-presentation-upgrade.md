# Workbench presentation upgrade — tucked depth, attached tabs, and terminal tiles

## Status

**PROPOSED (documentation only, 2026-07-29).** No implementation has started.
This brief is the implementation contract for a presentation pass over the
existing pre-initial-push workbench. It changes no feature behavior, process
boundary, theme ownership, or product scope. A possible terminal-layout preset
feature is documented in a deferred adjacent-workstream section and is not part
of this phase's definition of done.

Implementation is gated on accepting
[ADR 0022](../../decisions/0022-recessed-workbench-deck.md), which records the
user-directed revisit of ADR 0012's flush-pane composition and single-radius
scale. Until that decision is accepted and the work below lands,
[`ui-design-language.md`](../../references/ui-design-language.md) continues to
describe the implemented UI.

Parallel execution is specified by
[`workbench-presentation-upgrade/README.md`](workbench-presentation-upgrade/README.md):
one serial shared foundation, six file-disjoint worktrees from its exact commit,
and one final integration/visual-QA wave. Each child plan includes its exclusive
paths, gates, merge contract, and a copy-paste Goal-mode start prompt.

## Outcome

Rafu should keep its compact, native workbench and gain the presentation grammar
visible in the supplied references:

- Files and the activity rails form a quiet rear plane.
- The working area sits just in front of that plane through a 4 pt inset, a
  small exposed corner, and a theme hairline.
- Tabs are attached caps that visually join the content they own.
- Each split editor group reads as one bounded tile.
- A terminal session's existing color identity reaches the actual terminal tile,
  not only its list row or tab marker.
- Search, Source Control, Terminals, and Ensemble use one panel anatomy and one
  empty-state grammar.
- Settings and New Ensemble reveal task hierarchy instead of presenting a field
  of unrelated controls.

This is not a reskin. The JSON theme remains the sole product-color authority.
The pass changes geometry, surface composition, density, and state continuity.

## Why the current UI feels less finished than its feature set

The screenshots show strong editor rendering, a dense file tree, useful utility
panels, and a coherent Indigo theme. The weakness is the relationship between
those parts:

1. The workbench has two dominant modes: completely flush rectangles or large
   12 pt cards. It lacks the compact middle layer used by the references.
2. The selected editor tab is communicated mainly by `StitchedUnderline`; the
   tab does not appear physically attached to the document or terminal below it.
3. Recursive editor groups have functional splitters but no clear containing
   frame. In multi-terminal layouts, ownership and keyboard focus are visually
   ambiguous.
4. Terminal identity stops at the manager row and a 2 pt leading tab marker.
   The live SwiftTerm surface remains visually anonymous.
5. Utility panels stack an outer uppercase title, an inner title/header, several
   dividers, and then an oversized empty state. The repeated chrome makes sparse
   content feel assembled rather than composed.
6. Settings uses a tall icon-over-label category strip above a wide grouped
   form. New Ensemble repeats large provider cards and detached model pickers.
   Both surfaces expose configuration density before task hierarchy.
7. Selection has too many unrelated visual dialects: stitched underline, filled
   row, segmented pill, 2 pt outlined agent card, filled primary button, and
   large selected rail tile.

The editor itself does not need reinvention. The presentation pass should make
the chrome feel as deliberate as the editing behavior already is.

## Screenshot evidence

### External references

The reference files are evidence for relationships, not palettes or product
scope:

| Reference | Useful evidence | Transfer to Rafu | Do not copy |
|---|---|---|---|
| `codex-clipboard-c1490b86-f21f-45a0-b5a8-ee1ed54cd7de.png` | The sidebar is a backplane; the main settings surface overlaps it through a tonal step and exposed rounded corner. The readable settings column stays bounded inside a very wide window. | Rear navigator + front working surface; clear page/section hierarchy; bounded settings content. | Olive/blue gradient, custom window frame, or 14–16 pt radii on dense workbench chrome. |
| `codex-clipboard-aa7aa51f-7daa-48db-b749-ddde812a8696.png` | A main content deck begins below the outer chrome with a tiny inset. Internal columns remain flush and hairline-divided. Active rows hug their content. | One narrow outer gutter; compact selected rows; structural seams inside the deck. | Fixed light palette, extra permanent navigation column, or web-style centered toolbar. |
| `codex-clipboard-24191fe6-2383-4821-bd21-573e95fb23ee.png` | Terminal panes use 4–6 pt visual gaps, 4–6 pt corners, compact attached headers, and a perimeter that carries session identity and focus. | Theme-resolved terminal perimeter around the actual live pane; explicit layout choices; focus through line weight plus tab state. | Eight panes by default, bright glows, tiny metadata, or color-only status. |
| `codex-clipboard-76c03531-5643-4a1a-8e55-0dffe9742eab.png` | The active tab is a filled cap with no bottom seam, so it joins the open content. Adjacent structural columns touch through hairlines. | Attached selected tabs and one scoped accent edge. | Eight chat columns, sub-11 pt body copy, hard-coded magenta, or permanent Git chrome. |

### Rafu captures

| Capture | Keep | Upgrade |
|---|---|---|
| `rafu-terminal-agents-1-2-layout.png` | Existing recursive 1+2 topology and live sessions. | Add 4 pt group gutters, bounded tiles, and session-colored terminal perimeters. |
| `rafu-terminal-agents-side-by-side.png` | Compact 28 pt tabs and side-by-side workflow. | Stop the tab bars reading as one continuous strip; give each group ownership and focus. |
| `rafu-terminal-agents.png` | Calm terminal canvas and useful manager. | Replace the anonymous edge-to-edge terminal plane with a framed live tile; compact manager rows. |
| `rafu-branches-left-bottom.png` | Searchable branch switcher and status-bar entry point. | Constrain and anchor the popover; reduce radius and row height; keep full branch names discoverable. |
| `rafu-setting-totally-meh.png` | All settings are reachable and use native controls. | Replace the mobile-like category strip with compact navigation; add page hierarchy; tighten section geometry. |
| `rafu-global-search.png` | Search mechanics are visible and compact. | Use one panel header and the shared lower-emphasis empty state. |
| `rafu-source-control-tab.png` | Good branch → mode → changes → commit order. | Reduce header bands and composer radius; integrate the bottom composer into panel rhythm. |
| `rafu-ensemble-tab.png` | Runs/Workflows/Activity are understandable. | Remove the duplicate `RUNS`/`Ensemble` title treatment and share the panel empty state/CTA. |
| `rafu-multiple-file-opened.png` | File tabs, editor, and Terminals coexist predictably. | Make selected tabs hug their content and reduce the oversized utility empty state. |
| `rafu-file-open-1.png` | Single-file editing is already calm and legible. | Make the document plane feel tucked into the shell; reduce the visual weight of rail selection. |
| `rafu-ensemble-agents-model-selection-meh.png` | Per-CLI model control is explicit. | Represent each CLI/model relationship once in a compact row instead of card grid plus repeated picker stack. |
| `rafu-ensemble-view.png` | Coordinator, grant, allowed CLIs, and goal are all present. | Reorder them into a clear start flow; strengthen the goal surface; keep common inputs above the fold. |

The source screenshots are review inputs, not repository assets: four clipboard
captures live in a temporary directory and the Rafu captures live on the
reviewer's Desktop. They are intentionally not copied into the product
repository in this documentation-only pass. The two tables above and the
measured contracts below are the durable evidence. If visual provenance needs
to ship with a later implementation, add an approved, redacted contact sheet in
that implementation rather than depending on these absolute paths.

Measurements inferred from screenshots are visual estimates. The values below
are macOS points and must be judged in the real app on Retina and non-Retina
displays.

## Durable presentation rules

### 1. Four surface levels, not a card around everything

Use this hierarchy:

1. **Window backing plane:** `appBackground`.
2. **Structural chrome:** rails and Files on `sidebarBackground`; status on
   `statusBarBackground`.
3. **Workbench deck:** editor plus the open utility panel, on
   `editorBackground`, inset 4 pt from the structural chrome and outlined with
   `borderSubtle`.
4. **Local controls/content:** tab shelf on `tabBarBackground`, active cap on
   `tabActiveBackground`, utility sections on `elevatedBackground`, embedded
   cards on `cardBackground`, and inputs on `fieldBackground`.

```text
┌──────── rear structural plane: app/sidebar background ──────────────────────┐
│ left rail │ Files │ 4 pt │╭──── working deck ───────────────────╮│ right rail│
│           │       │      ││ editor groups  │ optional utility  ││           │
│           │       │      │╰────────────────────────────────────╯│           │
├──────────────────────── flush 24 pt status bar ──────────────────────────────┤
└───────────────────────────────────────────────────────────────────────────────┘
```

The deck is one front/back relationship, not a floating card per pane. Internal
editor/utility columns still use native splitters and hairlines. Do not add
shadows, blur, translucent materials, gradients, bevels, or recreated Liquid
Glass.

### 2. Geometry is semantic

Do not globally change `RafuMetrics.radiusPanel`. That 12 pt value remains
appropriate for genuine overlays and sheets. Add a compact workbench tier:

| Role | Target |
|---|---:|
| Structural hairline | 1 pt |
| Workbench outer inset | 4 pt |
| Editor-group separation | 4 pt visual target including the native splitter; tolerance is one physical pixel at 1× and 2× |
| Workbench deck radius | 6 pt |
| Editor/terminal group radius | 5 pt |
| Attached selected-tab top radius | 4 pt |
| Dense row selection radius | 4 pt |
| Dense embedded card/composer radius | 6 pt |
| Workbench field radius | 5 pt |
| Branch/transient popover radius | 8 pt |
| Overlay/sheet radius | existing 12 pt |
| Tab strip height | existing 28 pt |
| Panel header height | existing 34 pt |
| Utility body inset | 8 pt |
| Settings section inset / row minimum / section gap | 14 / 36 / 28 pt |
| Status bar height | existing 24 pt |

Proposed code-side names in `RafuMetrics`:

```swift
static let workbenchInset: CGFloat = 4
static let editorGroupGapTarget: CGFloat = 4
static let radiusWorkbenchDeck: CGFloat = 6
static let radiusEditorGroup: CGFloat = 5
static let radiusAttachedTab: CGFloat = 4
static let radiusDenseSelection: CGFloat = 4
static let radiusDenseCard: CGFloat = 6
static let radiusWorkbenchField: CGFloat = 5
static let radiusTransientPopover: CGFloat = 8
static let utilityBodyInset: CGFloat = 8
static let settingsSectionInset: CGFloat = 14
static let settingsRowMinHeight: CGFloat = 36
static let settingsSectionGap: CGFloat = 28
static let terminalBorderWidth: CGFloat = 1
static let focusedTerminalBorderWidth: CGFloat = 2
```

These are geometry constants, not JSON fields.

### 3. Theme JSON remains the color authority

The core upgrade needs no new token. Use the already-resolved
`RafuThemePalette` values:

| Presentation role | Palette value |
|---|---|
| Revealed gutter/backing | `appBackground` |
| Files and activity rails | `sidebarBackground` |
| Workbench/editor surface | `editorBackground` |
| Utility panel/section surface | `elevatedBackground` |
| Tab shelf | `tabBarBackground` |
| Attached active tab | `tabActiveBackground` |
| Embedded cards | `cardBackground` |
| Inputs | `fieldBackground` |
| Hover/selection | `hover`, `selection`, `accentSoft` |
| Structure/focus | `borderSubtle`, `borderStrong`, `focusRing` |
| Terminal session identity | `theme.palette.color(for: controller.sessionColor)` |
| Accent and semantic state | `accent`, `info`, `success`, `warning`, `error` |

Rules:

- Add no hard-coded RGB, hex, black, gray, amber, blue, magenta, or provider
  color.
- Do not derive product colors from vendor marks.
- Do not add a required JSON field.
- Existing imported themes that omit optional rich tokens must continue through
  the current deterministic fallbacks.
- `TerminalSessionColor.custom` remains the one existing explicit exception: it
  is a literal color the user selected in the system color picker, not a Rafu
  product color. It is an identity accent layered with a neutral
  theme-resolved structural boundary, never the only perimeter. An uncolored
  terminal uses theme borders.
- Alpha can lower emphasis, but never use opacity to make a required boundary
  disappear under Reduce Transparency or Increase Contrast.
- Built-in themes must render every required normal-size text role at a contrast
  ratio of at least 4.5:1 against its immediate surface. This includes
  `textSecondary` when it carries status, unavailable reasons, helper copy,
  upstream information, or empty-state instructions. Reserve `textMuted` for
  genuinely nonessential/inactive information and never make it the sole
  carrier of an explanation. Essential icons, keyboard-focus indicators, and
  control boundaries that are necessary to recognize a control must render at
  least 3:1. Decorative structural hairlines are exempt. If a bundled theme
  fails, correct its JSON token; do not introduce a code-side color. Imported
  themes are user-owned and are not silently corrected.
- Add
  `Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json` during
  implementation as the exact adversarial imported-theme fixture below. This
  fixture deliberately does not promise tonal depth. It proves that layout,
  labels, attached-tab geometry, and accessibility remain usable when
  user-supplied surface colors converge.
- If the bundled-theme contrast audit fails, edit only the failing token in the
  owning JSON under `Resources/Themes/indigo.json`, `khadi.json`,
  `dracula.json`, `notion-light.json`, `notion-dark.json`,
  `github-light.json`, or `github-dark.json`; do not patch over it at a view
  call site.
- If implementation later proves a missing semantic color role, stop and make it
  an optional JSON key with a deterministic fallback. That change must include
  `RafuTheme.UIColors`, `RafuThemePalette`, `makePalette`,
  `AIThemePrompt.swift`, `ThemeFileService.swift`, bundled themes, and
  `RafuThemeTests.swift`.

Exact converged-surface fixture:

```json
{
  "$schema": "https://rafu.dev/schemas/theme/v1.json",
  "version": 1,
  "name": "Workbench Converged Surfaces",
  "id": "dev.rafu.test.workbench-converged-surfaces",
  "appearance": "dark",
  "ui": {
    "appBackground": "#202020",
    "sidebarBackground": "#202020",
    "editorBackground": "#202020",
    "elevatedBackground": "#202020",
    "statusBarBackground": "#202020",
    "tabBarBackground": "#202020",
    "tabActiveBackground": "#202020",
    "cardBackground": "#202020",
    "fieldBackground": "#202020",
    "textPrimary": "#F2F2F2",
    "textSecondary": "#B8B8B8",
    "textMuted": "#8A8A8A",
    "accent": "#777777",
    "focusRing": "#777777",
    "borderSubtle": "#4A4A4A",
    "borderStrong": "#777777",
    "selection": "#242424",
    "hover": "#242424"
  },
  "editor": {
    "background": "#202020",
    "foreground": "#F2F2F2",
    "cursor": "#F2F2F2",
    "selectionBackground": "#2A2A2A",
    "lineHighlight": "#222222"
  },
  "syntax": {
    "keyword": {
      "color": "#D0D0D0"
    }
  }
}
```

### 4. State has one vocabulary

- **Selection:** close-fitting `selection`/`accentSoft` wash, stronger label,
  and `.isSelected`.
- **Pressed:** an immediate theme-derived `selection` wash or stronger boundary,
  distinct from hover and with no decorative animation.
- **Active tab:** attached surface fill, top/side outline, stronger label, and a
  small stitched accent edge.
- **Keyboard focus:** native focus ring or `focusRing`; it must remain distinct
  from selection.
- **Editor-group focus:** stronger perimeter plus the attached selected tab;
  terminal focus additionally changes perimeter width from 1 pt to 2 pt.
- **Terminal identity:** session color perimeter plus provider icon/name/status.
  Never color alone.
- **Current terminal row:** exactly one manager row—the focused group's visible
  terminal—may use selected geometry and `.isSelected`. The controller's
  `selectedID` is not rendered as a second list-selection state. If no visible
  terminal is focused, no row is current. Running/exited status, attention, and
  session-color identity remain separate.
- **Attention:** stronger perimeter plus textual/icon status.
- **Disabled:** explicit label/reason where the unavailable choice remains
  visible; do not depend on opacity alone.
- **Inactive window:** styles read `controlActiveState`, reduce accent/focus
  emphasis, and retain the selected shape, boundary, label contrast, and
  accessibility value.
- **Primary action:** at most one filled accent action per local task surface.

No decorative animation belongs on tab switches, editor focus changes, terminal
focus, caret movement, or typing. Existing short hover feedback may remain.

### 5. Typography stays native and restrained

- Use the system proportional font for tabs, panels, settings, metadata, empty
  states, and controls. Monospace remains for editor text, terminal output, code,
  and individual shortcut/path tokens.
- Page title: 21–24 pt semibold.
- Section title: 15–18 pt semibold.
- Panel and tab label: 12–13 pt medium.
- Normal control text: 12–14 pt.
- Secondary metadata: 10.5–12 pt.
- Uppercase group label: 10–11 pt semibold with modest tracking.
- Establish hierarchy with primary/secondary/muted theme contrast before adding
  more font weights or sizes.
- Empty-state titles stop at 20 pt; they should guide a task, not compete with
  the editor.
- The 28 pt tab strip, 32 pt settings-navigation row, 34 pt panel header, 34 pt
  provider launch cell, and other text-bearing heights are default targets, not
  clipping boxes. Use scaled type and minimum heights. At larger user text
  sizes, headers/rows expand to preserve one readable line and controls reach
  overflow sooner; explanatory copy wraps instead of truncating. Tabs may grow
  to 34 pt and use overflow earlier; after that cap, the title truncates with
  its full tooltip/VoiceOver label while the close action remains reachable.
  Do not scale editor or terminal content behind the user's explicit font
  settings.

## Surface specifications and exact implementation edits

### A. Window shell and tucked workbench deck

**Files**

- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Sources/RafuApp/Views/WorkspaceNavigatorView.swift`
- `Sources/RafuApp/Views/WorkspaceSidebarView.swift`
- `Sources/RafuApp/Views/WorkspaceStatusBar.swift`
- `Sources/RafuApp/Views/FlatWindowChrome.swift` (verification; edit only if the
  duplicate top band reproduces)
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- new `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`

**Edits**

1. In `WorkspaceWindowView.windowContent`, keep the current outer
   AppKit-backed `HSplitView` as the direct owner of Files versus the work area,
   and keep the inner `HSplitView` as the direct owner of editor versus utility.
   Keep their width bounds, layout priorities, rails, and status bar.
2. Replace only the current inner editor/utility branch with this wrapper order:

   ```text
   appBackground
   └─ external 4 pt padding
      └─ WorkbenchDeckSurface (no content padding and no clipping)
         └─ existing inner HSplitView
            ├─ editorCanvas
            └─ optional WorkspaceUtilityPanelView
   ```

   The outer Files/work-area splitter remains outside the deck wrapper. The
   inner editor/utility splitter remains inside the deck but outside any
   content padding. Their visible divider and invisible drag hit areas stay
   authoritative.
3. `WorkbenchDeckSurface` owns:
   - `editorBackground` fill;
   - 6 pt continuous corner;
   - 1 pt `borderSubtle` outline, promoted to `borderStrong` under Increase
     Contrast.
   Apply the 4 pt inset as padding *outside* this surface so it reveals
   `appBackground`; do not pad the editor or utility content inside it.
   Because those children already paint opaque rectangular backgrounds, do not
   rely on the background shape alone and do not mask/clip the composite.
   `WorkbenchDeckSurface` must finish with a non-hit-testing,
   accessibility-hidden overlay stack: `CornerCutoutOverlay` paints four 6 pt
   corner wedges with the surrounding `appBackground`, then the surface draws
   its rounded border stroke. This visually exposes the corner while leaving
   TextKit, SwiftTerm, splitters, responder routing, and hit regions
   geometrically untouched.
4. Keep `WorkspaceSidebarRail`, `WorkspaceSidebarView`,
   `WorkspaceUtilityRail`, and `WorkspaceStatusBar` edge-attached. They form the
   rear structural plane; do not turn them into separate cards.
5. In `WorkspaceUtilityPanelView`, replace
   `sidebarBackground.opacity(0.92)` with a solid resolved surface. The panel
   lives inside the deck and should use `elevatedBackground`; the right rail
   remains `sidebarBackground`.
6. Leave the Files leaf unrounded and edge-attached on
   `sidebarBackground`; retain its current divider, `List` density, native
   selection, stable file-tree identity, and header actions. Do not apply
   `WorkbenchDeckSurface` to it.
7. Add `RafuRailButtonStyle` in `RafuControlStyles.swift` and use it for the
   sidebar toggle inside `WindowTopLeftControlCluster` and for every
   `WorkspaceUtilityRail` mode button. `WorkspaceSidebarRail` itself remains a
   drag-handle column and receives no button style. Retain the 30 pt targets;
   use `radiusDenseSelection`, a subtle `accentSoft`/`selection` wash, a 1 pt
   theme boundary, and a 2 pt deck-facing inset bar as the non-color selected
   shape. Preserve `.isSelected`, tooltips, labels, badges, and keyboard routes.
   Hover and press feedback are immediate and theme-derived. Do not globally
   alter `RafuIconButtonStyle`, which serves other chrome.
8. Preserve `FlatWindowChrome`'s contract: no `NSToolbar`, no custom traffic
   lights, no titlebar-safe-area workaround, and no change to full-screen
   reapplication. If the duplicate top band reproduces, constrain the fix to
   `FlatWindowChrome`/`WorkspaceWindowView` state application rather than
   inventing new titlebar chrome.

**Acceptance**

- A 4 pt rear plane is visible around the working deck in Indigo, Khadi, and
  GitHub Light.
- The Files sidebar reads behind the deck without a shadow.
- With `workbench-converged-surfaces.json`, tonal depth is not guaranteed.
  Layout, labels, selection traits, and attached-tab shape must still preserve
  understandable ownership; implementation must not invent a fallback color.
- Sidebar and utility splitters retain their current pointer hit targets and
  min/ideal/max widths.
- The status bar remains a flush 24 pt window edge.
- A second window owns its own inset, utility state, and split positions.
- Single-pane, split-pane, key, inactive, full-screen, and restored windows show
  one consistent top-chrome band. The extra titlebar band visible in one supplied
  Rafu capture is unresolved evidence, not a design target: reproduce and fix it
  if current; otherwise record that capture as stale.

### B. Attached editor and canvas tabs

**Files**

- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Settings/SettingsCanvas.swift`
- `Sources/RafuApp/Views/EnsembleStartCanvas.swift`
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift`
- `Sources/RafuApp/Views/ConductorGraphCanvas.swift`
- `Sources/RafuApp/Views/ConductorRunDetailCanvas.swift`
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`

**Edits**

1. Add a shared `AttachedWorkbenchTab`/modifier with:
   - 28 pt default strip height via `@ScaledMetric(relativeTo: .body)`, clamped
     to 28–34 pt for larger user text;
   - 8 pt horizontal label inset;
   - 5–6 pt icon/title spacing;
   - 96 pt minimum and 220 pt maximum natural width for document/terminal tabs;
   - 4 pt top-only continuous corners;
   - selected fill `tabActiveBackground`;
   - selected top and side hairline using `borderStrong`;
   - no selected bottom edge;
   - inactive fill clear and text `textSecondary`;
   - selected text `textPrimary`;
   - 12 pt visible close glyph inside a 22 pt default hit region, scaling up to
     28 pt with larger user text. This intentionally expands the current 9 pt
     glyph/18 pt button while staying inside the scaled tab strip.
2. Let `EditorGroupTabBar` own the full-width bottom seam. The selected tab then
   draws a 1 pt `tabActiveBackground` seam mask at its bottom and a higher
   `zIndex`, visually joining the content without adding layout beyond the
   actual scaled tab-strip frame captured by drag/reorder code.
3. Change `StitchedUnderline` into a secondary `StitchedAccentEdge` at the
   selected cap's top. It may remain 1–2 pt and dashed; it is no longer the sole
   selection signal.
4. Apply the shared tab chrome to `EditorTabItem`,
   `EditorTerminalTabItem`, `GitDiffTabItem`, standalone blame/diff tabs,
   Settings, New Ensemble, New Run, graph, and run-detail canvases. Remove their
   separately hand-built underline variants.
5. Keep the current drop coordinate space, captured tab frames, insertion
   indicator, overflow menu, close-on-hover behavior, dirty dot, drag provider,
   and split context menu.
6. Give truncated labels `help` with their full title. Keep the dirty and exited
   states textually accessible.
7. Keep Markdown mode controls outside tab ownership and visually separated by
   one short divider.

**Acceptance**

- The selected tab and its content share a surface with no visible bottom seam.
- Selection remains obvious in grayscale without the stitched accent.
- Eight representative tabs either fit or reach the existing overflow menu at a
  1,200 pt window width without colliding with Markdown controls.
- No editor-layout model or tab state-transition change is required; existing
  drag/reorder/split behavior tests remain green.
- Settings and every Ensemble canvas use the same active-tab construction as
  documents and terminals.

### C. Editor groups and terminal tile identity

**Files**

- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- `Sources/RafuApp/Terminal/TerminalSessionColor.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`

**Edits**

1. In `EditorLayoutTreeView`, keep `HSplitView`/`VSplitView` as the resizing
   engine. Put `appBackground` behind each split and treat
   `editorGroupGapTarget` as a measured 4 pt visual target from one group edge
   to the next, *including* the native divider. Let the divider visually occupy
   that band; do not add two 2 pt leaf pads and then add its thickness again.
   Its larger native pointer hit target may extend invisibly beyond the painted
   band. Verify the result to within one physical pixel at both 1× and 2×.
2. Wrap `EditorGroupView` in `EditorGroupSurface`:
   - 5 pt continuous radius;
   - `editorBackground` fill;
   - neutral `borderSubtle` at rest;
   - `borderStrong` for the focused document group;
   - frame includes both tab cap and content.
   Its children also paint opaque backgrounds, so reuse
   `CornerCutoutOverlay(radius: 5, surrounding: appBackground)` above the
   composite rather than clipping it, then draw the document or terminal border
   styles above that cutout. The overlay does not accept hit tests and is hidden
   from accessibility.
3. When the selected tab is a terminal:
   - resolve `controller.sessionColor` through
     `theme.palette.color(for:)`;
   - always draw a 1 pt neutral structural boundary using
     `borderSubtle`, promoted to `borderStrong` under Increase Contrast;
   - when color is assigned, draw it as a complete inset identity perimeter
     over or immediately inside that neutral boundary, at 1 pt when unfocused;
   - when focused, strengthen the focus boundary to 2 pt and keep the identity
     perimeter visible. A custom color equal to `editorBackground` therefore
     cannot erase the neutral structure or the focus state;
   - use neutral structure alone when the terminal has no assigned color;
   - retain provider icon, terminal name, status text, and selected tab so color
     is never the sole carrier.
4. Use one shared `TerminalSurfaceBorderStyle` resolver from both
   `EditorGroupSurface` and `TerminalSessionRowView.rowBorder`. Give the
   resolver an explicit context enum:
   `.editorGroup(isFocused:)` or
   `.managerRow(isCurrent:needsAttention:)`. It returns neutral structure,
   optional identity accent, focus/current emphasis, and row fill separately;
   do not force manager attention precedence to equal editor focus precedence.
   Remove duplicated color-resolution logic.
5. Keep `EditorTerminalTabContent`'s SwiftTerm host, generation identity,
   responder behavior, exit overlay, process lifetime, hide/close split, and
   theme application unchanged. It remains body-only: `EditorGroupSurface` is
   the sole owner of the tab-plus-content perimeter. Do not add a second border,
   inset, or clip around the terminal's text viewport.
6. Retain the terminal tab's 2 pt leading marker as a redundant cue for
   unselected terminal tabs, but resolve it through the same identity-accent
   value as the live perimeter. It must not have separate precedence logic.
7. Do not assign random or provider-brand colors. Uncolored sessions stay
   neutral. Existing preset and user-picked session colors are sufficient.
8. Expose a read-only presentation value for the focused group's selected
   terminal session from `WorkspaceSession` (the current private
   `focusedTerminalSessionID` derivation is already the source of truth). Pass it
   to `TerminalSessionRowView` as `isCurrent`, replacing `isSelected:
   session.terminal.selectedID == row.id` as the visual input. A current row
   uses the close-fit selected shape, stronger label, `.isSelected`, and an
   accessibility value such as **Current terminal**. A click reveals/focuses the
   session and therefore moves this single state; no independent visual list
   selection remains. Running/exited status, attention, and session color remain
   separate signals.

**Terminal Groups supersession — terminal layout behavior**

ADR 0023 and [`terminal-groups.md`](terminal-groups.md) now own compound
Terminal Group topology, pane creation, directional focus, and layout saving.
This presentation phase remains visual-only. The historical layout-command
discussion below does not define current terminal behavior or this phase’s
acceptance gate.

**Historical deferred adjacent workstream — terminal layout commands**

The current recursive topology already produces single, side-by-side, stacked,
2×2, and 1+2 arrangements. This phase frames and verifies those existing
arrangements without changing topology behavior. If later dogfooding still
finds layout creation too hidden, open a separately approved behavior workstream
for user-triggered commands:

- Single
- Columns
- Rows
- 2×2
- 1+2

That follow-up would own `WorkspaceSession.swift` and `EditorLayout.swift`.
Its visible control would belong in the Terminals panel header when at least two
terminal tabs exist, with matching menu/keyboard reachability. Applying a command
could move terminal tab references between editor groups but must not respawn,
close, park, or reorder underlying sessions and must never run automatically.
Disable 2×2 unless every resulting terminal leaf can remain at least 280 pt wide
and 180 pt high. These commands are informative design direction only: they are
not part of P0–P6, the ownership table, or this phase's acceptance gate.

**Acceptance**

- 1×2, 2×1, 2×2, and 1+2 layouts show unambiguous tab-to-content ownership.
- The same assigned session color appears on manager row, terminal tab cue, and
  complete live terminal tile.
- Focus is distinguishable by perimeter weight and selected-tab shape without
  relying on hue.
- Existing manually-created 2×2 remains usable at a 1,200 pt window with Files
  visible and the utility panel closed: every leaf is at least 280 × 180 pt,
  SwiftTerm reports at least 32 columns × 8 rows at the configured font, and
  every tab title and close action remains reachable directly or through
  overflow.
- A custom session color equal to `editorBackground` still leaves a visible
  neutral structural boundary and a distinguishable focus state.
- The row for the focused visible terminal looks current even when it has no
  attention and no assigned color.
- TextKit and SwiftTerm focus, scrolling, resizing, drag/drop, hide, close,
  parking, and process teardown remain unchanged.

### D. One utility-panel anatomy

**Files**

- `Sources/RafuApp/Views/WorkspaceNavigatorView.swift`
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- `Sources/RafuApp/Views/GitInspectorView.swift`
- `Sources/RafuApp/Views/ConductorRunsPanelView.swift`
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`

**Edits**

1. Add shared `RafuUtilityPanelHeader` and `RafuPanelEmptyState`.
2. Remove `WorkspaceUtilityPanelView.panelHeader`. Let each concrete panel own
   exactly one primary header and receive the common close action. In
   `GitInspectorView.swift`, add `SourceControlPanelView` as that concrete owner
   for both repository states. `WorkspaceUtilityPanelView.panelContent` calls
   it unconditionally for `.sourceControl`; it no longer branches directly on
   `gitSnapshot`, which would otherwise leave the no-repository state without a
   header or close action.
3. `RafuUtilityPanelHeader` is 34 pt high by default, expanding as a minimum
   height for larger user text, and contains icon, title, optional count/context,
   actions, and close. Primary titles use normal title case and 12–13 pt medium
   text. Uppercase 10–11 pt text is reserved for internal section metadata.
4. Permit a second row only for real mode or repository context:
   - Search: controls, not another title.
   - Source Control: branch/upstream context.
   - Terminals: agent quick launch; layout commands only if the deferred
     behavior workstream is separately approved.
   - Ensemble: Runs/Workflows/Activity picker.
5. Standardize panel body inset at 8 pt and structural seams at 1 pt.
6. `RafuPanelEmptyState` fills the remaining body, centers inside that remaining
   area, and uses:
   - 28–32 pt icon;
   - 18–20 pt semibold title;
   - 13–14 pt system body copy, maximum 280 pt;
   - one `RafuProminentButtonStyle` action where creation is available.
7. Render shortcut tokens as monospaced chips, not the whole Terminal
   explanation in a monospaced font.

**Panel-specific edits**

- **Search — `WorkspaceSearchContent`:** retain the query as the dominant first
  row and keep recent/run actions trailing. Put include/exclude inside a
  `DisclosureGroup("File filters")` immediately below it; collapse it by
  default when both fields are empty and force it open when either contains a
  value. Keep case, word, and regex on one compact row with labelled
  tooltips/accessibility; use the shared empty state without a primary action.
- **Source Control — `GitInspectorView`:** left-align the
  `SourceControlPanelView` owns the one primary header and close action.
  `GitInspectorView` remains the repository-present body: left-align its
  Changes/Worktrees/History switcher with the 8 pt body inset; reduce redundant
  full-width separators; use 40 pt minimum change rows; retain the bottom-pinned
  composer but use `radiusDenseCard` and an 8 pt outer inset rather than
  `radiusPanel` and a 10 pt floating-card gutter. When the repository is clean,
  use `RafuPanelEmptyState` with a quiet **No Changes** title and explanatory
  text, but no creation CTA; keep branch/repository context above it. The
  wrapper's no-repository branch uses the same component with the existing
  explicit **Initialize Repository** action; do not change Git's user-initiated
  boundary.
- **Terminals — `WorkspaceTerminalsPanelView`:** fold `header(count:)` into the
  shared primary header; keep quick launches in a real secondary section.
  Replace the one-line logo strip with an adaptive grid of 34 pt default-height,
  minimum-86 pt-wide cells at 6 pt spacing; cell height expands for larger user
  text. Each cell shows the provider icon and a one-line short display name,
  plus the full provider tooltip and accessibility label. Make session rows
  48 pt minimum with 6 pt gaps; render the focused
  visible terminal as the explicit current row described in section C; preserve
  all menus, rename, color, reveal, hide, and close actions.
- **Ensemble — `ConductorRunsPanelView`:** use one primary title, **Ensemble**,
  instead of outer **RUNS** plus inner **Ensemble**; retain the three-way picker;
  make `New Run…` use the same prominent treatment as `New Terminal` in the
  empty state.

**Acceptance**

- Search, Terminal, and Ensemble empty states align within 12 pt of the midpoint
  of their available body area.
- No panel repeats its primary noun in two adjacent headers.
- Every creation empty state uses the same button style.
- Source Control's clean state uses the shared lower-emphasis anatomy without a
  misleading action.
- Panel headers remain top-pinned when content is empty, preserving the
  repository's load-bearing alignment rule.

### E. Branch popover

**Files**

- `Sources/RafuApp/Support/RafuSearchableDropdown.swift`
- `Sources/RafuApp/Views/GitInspectorView.swift`
- `Sources/RafuApp/Views/WorkspaceStatusBar.swift`

**Edits**

1. Change `RafuSearchableDropdown.popoverContent` from `radiusPanel` to
   `radiusTransientPopover`.
2. Target 340 pt width, 160 pt minimum height, and 420 pt maximum height.
3. Keep the search field 28–30 pt high and branch rows 30 pt high with 4 pt
   selection radius.
4. Keep the current checkmark for the current branch and the keyboard highlight
   as distinct states.
5. Show the full branch name in `help`; retain middle truncation only in the
   narrow trigger.
6. Use normal AppKit popover placement, but verify the status-bar trigger stays
   within the visible screen and no content extends beyond the window/screen
   edge. Do not replace `popover` with a manually positioned overlay.

### F. Settings hierarchy

**Files**

- `Sources/RafuApp/Settings/SettingsCanvas.swift`
- rename `Sources/RafuApp/Settings/SettingsPaneStrip.swift` to
  `Sources/RafuApp/Settings/SettingsPaneNavigation.swift`
- `Sources/RafuApp/Settings/RafuSettingsView.swift`
- `Sources/RafuApp/Settings/ThemeSettingsSection.swift`
- `Sources/RafuApp/Settings/AIThemeGeneratorSection.swift`
- `Sources/RafuApp/Settings/ConductorSettingsTab.swift`
- `Sources/RafuApp/Settings/EnsembleSettingsTab.swift`
- `Sources/RafuApp/Settings/LanguageServersSettingsSection.swift`
- `Sources/RafuApp/Settings/UsageSettingsTab.swift`
- `Sources/RafuApp/AI/AIProviderSettingsSection.swift`
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`

**Edits**

1. Use the shared attached tab in `SettingsCanvas`.
2. Convert `SettingsPaneStrip` from a tall centered icon-over-label bar into
   `SettingsPaneNavigation`:
   - 188 pt vertical category column on regular widths;
   - seven real `Button` rows, 32 pt default minimum height and expanding for
     larger user text;
   - 14 pt icon + label;
   - 4 pt selected-row radius;
   - selected wash plus stronger icon/text;
   - `.isSelected`, help, and Full Keyboard Access retained.
3. At narrow editor widths, use a compact top category popup/row. Decide from
   the Settings canvas's available width after deck insets—not the window
   width. The vertical variant requires 188 pt navigation + 16 pt gap + 560 pt
   minimum form + 48 pt outer padding, so use it at 812 pt or wider and the
   compact variant below 812 pt. Because the measurement does not depend on the
   chosen variant's own size, the threshold cannot oscillate or clip labels.
4. Preserve `visitedPanes`, the retained `ZStack`, `.opacity`,
   `.disabled(true)`, and `.accessibilityHidden(true)`. These are lifecycle and
   keyboard-safety behavior, not presentation details. Keep `paneContent`
   outside the navigation-variant conditional with stable identity; this
   retained host—not `AnyLayout`—is what prevents pane recreation.
5. Add title/subtitle metadata to `SettingsPane` and a shared page header.
6. Center the combined regular navigation + page group in the canvas with 24 pt
   outer padding and a 1,092 pt maximum (`188 + 16 + 840 + 48`). Keep the page
   column itself at an 840 pt maximum with left-aligned text and controls. In
   compact navigation, center that same 840 pt page column. Do not stretch one
   section across the whole editor canvas or pin a narrow column to one edge.
7. Exact card geometry is not reliably controllable through
   `Form.formStyle(.grouped)`. Replace each pane's outer grouped `Form` in
   `RafuSettingsView.form(for:)` with a `ScrollView` containing a
   `VStack(alignment: .leading, spacing: 24)`. The section count is bounded;
   keep it non-lazy so off-screen settings do not lose local state or repeat
   `.task` work. Add
   `RafuSettingsSection` to `RafuWorkbenchStyles.swift` with header, content,
   and footer slots, then change each settings section file listed above from
   its outer page-grouping SwiftUI `Section` wrappers to that shared container.
   Leave `Section` values nested inside a `Picker`/menu (for example Built In
   versus Custom themes) native. Keep `Toggle`, `Picker`, `TextField`, `Stepper`,
   `ColorPicker`, `LabeledContent`, buttons, menus, labels, validation, and focus
   behavior as native controls. The custom container owns only:
   - 6 pt radius;
   - 14 pt inner padding;
   - 36 pt normal minimum row height, expanding only for multi-line content;
   - 1 pt theme separators between logical rows where needed;
   - 28 pt between independent sections.
   `RafuSettingsSection` must restore the semantics that native `Section`
   supplied: its header has `.isHeader`, its container uses
   `.accessibilityElement(children: .contain)` rather than combining controls,
   and its source/VoiceOver reading order matches its visual order in both
   navigation variants.
8. General should show the app summary and common controls above the fold at an
   800 pt content height. Other panes should introduce a page heading before
   their first group.
9. Preserve the editor-hosted route, native `Settings` scene fallback, ⌘,,
   per-window ownership, non-restoration, and no-I/O-at-init contract.

**Acceptance**

- All seven categories are reachable without horizontal scrolling.
- At 900 pt editor width, labels and controls do not clip.
- Category selection reads as a compact row, not a large dashboard tile.
- General's common settings fit above the fold at 800 pt height.
- Resizing across the adaptive breakpoint does not rerun pane `.task` work or
  make a hidden pane keyboard-focusable.
- Repeated resizing within ±20 pt of the 812 pt threshold neither oscillates the
  navigation treatment nor resets scroll position, control focus, or pane state.
- VoiceOver announces each page and section heading once, then reaches every
  native control in the same order shown on screen.

### G. New Ensemble task flow

**Files**

- `Sources/RafuApp/Views/EnsembleStartCanvas.swift`
- rename `Sources/RafuApp/Views/EnsembleCLIIconGrid.swift` to
  `Sources/RafuApp/Views/EnsembleCLISelectionList.swift`
- `Sources/RafuApp/Views/EnsembleModelField.swift`
- `Sources/RafuApp/Views/EnsembleGoalPane.swift`
- `Sources/RafuApp/Views/ConductorGraphCanvas.swift`
- `Sources/RafuApp/Views/ConductorRunDetailCanvas.swift`

**Target order**

1. Name and goal.
2. Lead/coordinator CLI and its model.
3. Budget/deadline.
4. Allowed CLIs and their models.
5. Start action.

**Edits**

1. Use the shared attached canvas tab.
2. Keep `header` below 100 pt and bring Name into the same visual cluster as
   **New Ensemble**. Retain the three doors and suggested-name behavior.
3. In `guidedDoor`, replace the harsh central divider with a 4 pt
   `appBackground` gutter between two 5 pt surfaces. Put the flexible,
   minimum-420 pt goal pane first in both source and visual order, followed by a
   300 pt trailing configuration rail. This makes Goal the first keyboard and
   VoiceOver region after Name; do not use accessibility sort priority to mask
   a contradictory source order.
4. Replace `EnsembleCLIIconGrid` with `EnsembleCLISelectionList` and
   `EnsembleCLISelectionRow`. A row has a compact two-line logical layout:
   provider icon, name, readiness, and radio/checkbox selection on the first
   line; resolved model summary or inline model popup on the second. The
   lead/coordinator list uses radio semantics; Allowed CLIs uses checkbox
   semantics. At compact widths the second line may wrap, but it must not become
   a separate repeated picker stack.
5. Represent each allowed CLI/model relationship once. Remove the separate card
   grid followed by a repeated stack of labels and `EnsembleModelField`s.
6. Keep `EnsembleModelField`'s behavioral contract: CLI default is not a claimed
   explicit model, inherited resolution remains explained, discovered/custom
   models remain selectable, and free-text **Custom…** remains available.
7. Show unavailable CLIs with an explicit **Unavailable** label and the existing
   reason. Do not rely on 0.55 opacity.
8. Put Budget Grant and advanced Allowed CLI detail in compact sections or
   disclosures, while leaving the common path visible.
9. Give `EnsembleGoalPane` a clear local frame and focused `focusRing`; retain its
   one-pane edit/render behavior and zero Markdown parsing on the typing path.
10. Keep the footer 52 pt high, always visible, with secondary **Close** and one
    prominent primary **Start Coordinator** action. The role-specific delivered
    copy remains unchanged; internal `Conductor*` symbols remain unchanged.
11. Keep all grant enforcement, CLI probing, delegated auth, no-I/O-at-init,
    paste fallback, explicit user launch, and run routing unchanged.

**Acceptance**

- At 1,440 × 900 pt, Name, Goal, lead CLI/model, and primary action are visible
  simultaneously without scrolling.
- Each CLI/model relationship appears once.
- Lead single-selection and Allowed CLI multi-selection are visually and
  accessibly distinct.
- Disabled **Start Coordinator** explains the missing requirement inline.
- The Runs utility panel remains secondary to composition and uses the shared
  lower-emphasis empty state.
- No new visible string calls the feature “Conductor.”

## Exact code ownership map

| Workstream | Owned implementation paths | Primary symbols |
|---|---|---|
| WP-00 foundation/decision | `RafuMetrics.swift`, `RafuControlStyles.swift`, new `RafuWorkbenchStyles.swift`, theme fixture/tests, ADR 0022/index, one-time cross-lane test split | compact metrics, deck/tab/group/header/empty-state/rail styles, frozen theme contract |
| WP-10 shell deck | `WorkspaceWindowView.swift`, `WorkspaceSidebarView.swift`, verification-first `FlatWindowChrome.swift` | `windowContent`, exact external deck padding, native split/title-band preservation |
| WP-20 editor tabs/groups | `EditorCanvasView.swift` | `EditorLayoutTreeView`, `EditorGroupTabBar`, document/diff/terminal tab items, group-owned terminal perimeter |
| WP-30 terminal manager | `EditorTerminalTabContent.swift`, `TerminalSessionColor.swift`, `WorkspaceTerminalsPanelView.swift`, `WorkspaceSession.swift` | current-session derivation, concrete terminal header, adaptive launcher, compact rows |
| WP-40 utility panels | `WorkspaceNavigatorView.swift`, `GitInspectorView.swift`, `ConductorRunsPanelView.swift`, `RafuSearchableDropdown.swift`, `WorkspaceStatusBar.swift` | rails, primary headers, `SourceControlPanelView`, Search/Git/Runs density, branch popover |
| WP-50 Settings | `SettingsCanvas.swift`, renamed `SettingsPaneNavigation.swift`, `RafuSettingsView.swift`, explicitly listed pane section/tab files | adaptive navigation, retained pane host, custom section container with native controls, page hierarchy |
| WP-60 Ensemble | `EnsembleStartCanvas.swift`, renamed `EnsembleCLISelectionList.swift`, `EnsembleModelField.swift`, `EnsembleGoalPane.swift`, graph/detail canvases | goal-first source order, compact two-line provider rows, integrated models, fixed footer, attached canvas tabs |
| WP-90 integration/QA | global themed-control scan, integration tests, shared phase/reference indexes, narrowly documented union fixes only | theme/accessibility/display-scale/multi-window matrix and documentation close-out |

WP-00 lands before fan-out and its shared files are frozen for Wave 1.
WP-10 through WP-60 own disjoint source and test paths. WP-90 owns shared
indexes and final integration evidence. The executable branch/worktree,
ownership, merge, and Goal-prompt contract is
[`workbench-presentation-upgrade/README.md`](workbench-presentation-upgrade/README.md).

## Implementation sequence

### P0 — Decision and shared presentation primitives

- Accept ADR 0022.
- Add the semantic metric tier.
- Add deck, attached-tab, editor-group, terminal-border, utility-header, and
  empty-state primitives.
- Add pure/style contract tests.
- Keep `ui-design-language.md` as the verified implemented-state reference with
  its explicit successor pointer. Do not make it describe unimplemented call
  sites.

**Gate:** no visible call-site changes; all themes decode exactly as before; no
new color token.

For every visible increment P1–P5, the gate also includes Indigo, Khadi, the
exact `workbench-converged-surfaces.json` fixture, Increase Contrast, keyboard
navigation, the relevant VoiceOver labels/grouping, and larger user text where
the increment contains text-bearing chrome. P6 repeats these as an integrated
audit; it is not the first accessibility or theme-parity checkpoint.

### P1 — Shell, attached tabs, and group framing

- Inset the workbench deck.
- Move every canvas/document tab to the shared attached treatment.
- Frame split groups with the measured 4 pt separation target, including each
  native splitter.

**Gate:** tab drag/drop/reorder/split tests; sidebar/utility resizing; second
window; Indigo/Khadi/imported-theme captures.

### P2 — Terminal identity and layout presentation

- Carry existing session color to the actual terminal tile.
- Unify row/tab/tile border resolution.
- Compact manager rows and quick launches; add the explicit current-session
  state.

**Gate:** live session preservation across split/rearrange; focus/scroll/input;
hide versus close; colored, uncolored, and background-matching custom sessions.

### P3 — Utility panel consolidation

- One header and one empty-state grammar.
- Search density, Source Control composer integration, Ensemble panel CTA
  consistency, branch popover.

**Gate:** keyboard-only search/Git/terminal/run flows; top-pinned headers;
bottom-pinned composer.

### P4 — Settings

- Adaptive compact navigation.
- Page hierarchy and dense section geometry.
- Preserve retained pane lifetime and native fallback.

**Gate:** every pane visited twice with no repeated load; Full Keyboard Access;
no-window ⌘, fallback; narrow/wide resize.

### P5 — New Ensemble

- Reorder the common path.
- Consolidate CLI/model rows.
- Frame goal and keep the footer visible.

**Gate:** existing model-resolution/grant/launch tests; unavailable CLIs;
1,440 × 900 common-path capture.

### P6 — Integrated craft audit and documentation close-out

- Typography/copy consistency.
- Repeat Increase Contrast, Reduce Transparency, Reduce Motion, Full Keyboard
  Access, VoiceOver, and theme checks across the combined surface.
- Update `ui-design-language.md`, `settings-surface.md`, this phase status, and
  the active workbench plan if the pass becomes part of its achieved gate.

Nothing may modify a file after the final parallel test run.

## Verification contract

### Automated

Update or extend:

- `Tests/RafuAppTests/RafuThemeTests.swift`
- new `Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json`
- `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`
- `Tests/RafuAppTests/EditorThemeColorApplicationTests.swift`
- `Tests/RafuAppTests/EditorLayoutTests.swift`
- `Tests/RafuAppTests/EditorDragAndDropTests.swift`
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`
- `Tests/RafuAppTests/TerminalEditorTabTests.swift`
- `Tests/RafuAppTests/TerminalIdentityTests.swift`
- `Tests/RafuAppTests/TerminalsPanelTests.swift`
- `Tests/RafuAppTests/SettingsCanvasTests.swift`
- `Tests/RafuAppTests/RafuSearchableDropdownTests.swift`
- `Tests/RafuAppTests/StatusBarBranchFormatterTests.swift`
- `Tests/RafuAppTests/Conductor/EnsembleStartCanvasTests.swift`

Specific assertions:

- Active tab uses `tabActiveBackground` and has a non-color shape distinction.
- Corner cutout overlays are non-hit-testing/accessibility-hidden and no
  TextKit/SwiftTerm host receives a mask or clip modifier.
- Imported themes with only required legacy keys still decode and render through
  fallbacks.
- Built-in required primary/secondary text, essential icon, focus, and necessary
  control-boundary contrast meets the ratios in the theme contract; bundled JSON
  is corrected if it fails rather than bypassed in code.
- The converged-surface fixture decodes, preserves theme ownership, and is not
  silently contrast-corrected.
- Terminal border precedence is one shared context-aware pure contract.
- A custom terminal color equal to `editorBackground` retains neutral structure;
  the unique manager-current state, attention, status, identity, and editor
  focus remain separate inputs.
- Pane/group presentation does not alter editor topology or terminal lifetime.
- Settings keeps all seven panes, lazy-first-visit/retained-after-visit behavior,
  hidden-pane disabling, routing, and non-restoration.
- Ensemble source tests that currently pin two icon grids and the old 3/12 layout
  are deliberately updated to pin the new one-representation-per-CLI hierarchy;
  behavior assertions stay.

Final implementation sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

The advisor runs `./script/test.sh --no-parallel`; the coordinator runs both
modes after integration. GUI changes also require:

```bash
./script/build_and_run.sh --verify
```

### Manual screenshot matrix

Capture at minimum:

| Axis | Required states |
|---|---|
| Themes | Indigo, Khadi, GitHub Light, exact `workbench-converged-surfaces.json` imported fixture |
| Window width | 900 pt editor-constrained, 1,200 pt normal, 1,440 pt wide |
| Display scale | 1× and 2×: hairlines, complete 4 pt group separation, attached-tab seam mask, terminal perimeter |
| Editor topology | single, 1×2, 2×1, 2×2, 1+2 |
| Tabs | one, many/overflow, dirty file, exited terminal, long names, hover/pressed/selected/focused |
| Terminals | uncolored, theme-preset color, custom user color equal to editor background, current/background, focused/unfocused, attention |
| Utility | Search empty/results, Source Control no-repository/changes/clean, Terminals empty/list, Ensemble empty/list |
| Settings | every category, regular and compact navigation, native fallback |
| Ensemble | ready/unavailable CLIs, inherited/custom models, empty/filled goal, disabled/enabled Start Coordinator |
| Accessibility | Full Keyboard Access, VoiceOver labels/order/grouping, Increase Contrast, Reduce Transparency, Reduce Motion |
| User text size | Default and the largest supported accessibility size: tabs, panel headers, Settings navigation/sections, provider rows, helper and empty-state copy |
| Controls | rail buttons, tabs, provider rows, terminal rows: rest/hover/pressed/selected/disabled with immediate feedback |
| Windows | two workspaces; single/split; key/inactive; normal/full-screen/restored; independent sidebar, utility, settings, tabs, terminal focus; no duplicate top band |

### Presentation acceptance

- Built-in themes provide depth without shadows or hard-coded color. Arbitrary
  imported themes may collapse tonal depth; geometry, labels, and state
  semantics remain usable without silently replacing their colors.
- Gutters are 4 pt, not arbitrary per surface.
- Dense workbench radii stay 4–6 pt; 12 pt remains reserved for real overlays.
- Selected tabs look attached and cozy, not underlined labels floating above a
  separate canvas.
- Terminal identity surrounds the actual pane.
- A neutral structural edge survives identity-color/background collisions.
- Utility empty states and primary actions form one family.
- Settings and New Ensemble show the common task before advanced configuration.
- No typing-path work, background process, automatic command, credential access,
  Git behavior, or theme-schema requirement is introduced.

## Non-goals

- No feature removal.
- No extension host, embedded model, debugger, task runner, or new terminal
  process behavior.
- No replacement of `HSplitView`, TextKit, SwiftTerm, or the native Settings
  fallback.
- No custom traffic lights, `NSToolbar`, glass, blur stack, shadow system, or
  per-document web view.
- No provider-brand color as Rafu chrome.
- No random terminal color assignment.
- No terminal layout command/preset in this presentation phase.
- No breaking JSON theme change.
- No decorative motion on tabs, panes, terminal focus, typing, or caret changes.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Padding a split view shrinks or breaks its drag target. | Keep both native splitters outside content padding/clipping; measure the 4 pt group band including the divider while retaining its invisible hit target. |
| Rounded clipping affects TextKit or SwiftTerm drawing/focus. | Prefer outer fill/overlay and spacing; do not clip the text viewport. Verify responder and scroll behavior interactively. |
| Selected-tab seam mask corrupts drag frame geometry. | Keep the tab's actual scaled 28–34 pt layout frame authoritative; draw the 1 pt mask as a non-layout overlay with `zIndex`. |
| Settings adaptation recreates panes and repeats I/O. | Preserve one retained pane host; use identity-preserving layout and test repeated visits plus breakpoint resize. |
| New geometry looks good only in Indigo. | Treat Khadi and the exact converged-surface fixture as gates in every visible increment; audit all bundled themes at P6. |
| Semantic terminal colors look like status or disappear into the canvas. | Pair identity with name/icon/status, retain a neutral structural edge, and keep current/attention/focus as separate states. |
| The pass expands into a dockable IDE. | Keep existing topology and utility model; terminal layout commands require a separate approved behavior workstream. |

## Documentation close-out

When implementation lands:

1. Mark this phase implemented with commits, test totals, warnings, and GUI
   evidence.
2. Update `docs/references/ui-design-language.md` from current flush rules to the
   accepted deck/group/tab grammar.
3. Update `docs/references/settings-surface.md` with the adaptive navigation
   while preserving routing and pane-lifetime rules.
4. Update `docs/plans/phases/pre-initial-push-workbench.md` if this pass becomes
   part of the achieved acceptance gate.
5. Record any reusable AppKit/SwiftUI split, clipping, focus, or popover nuance
   discovered during implementation in a focused reference note and index it.
