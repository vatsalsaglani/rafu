# UI refresh — flat, modern, layered (planning brief)

## Status

IMPLEMENTED (2026-07-18). Increments U0–U5 shipped across five commits with 714 tests (684→714, +30 pure-core); manual GUI verification + ADR acceptance (0012/0013 Proposed) remain owed by the user.

Prior art: [`workbench-visual-polish.md`](workbench-visual-polish.md) built
the token/palette engine, shared control styles, and the Files-left /
utility-right structure this plan composes on top of. Nothing here replaces
the theme system — every change routes through `RafuThemePalette`.

Sibling feature briefs that adopt this plan's design language (planned the
same day, GitLens-inspired references):
[`git-experience-and-worktrees.md`](git-experience-and-worktrees.md)
(inline blame, hunk peek, commit graph, worktrees, AI composer) and
[`editor-terminal-tabs.md`](editor-terminal-tabs.md) (terminals as editor
tabs for CLI coding agents). U3's Git-inspector restyle is presentation
only; those briefs own the new capabilities.

## What the references share (distilled design language)

Five references were studied (Conductor's macOS app; a widget-properties
inspector; a Chat/Design/Code builder; an AI chat app in two crops). They are
not code editors, but they share one language:

1. **Layered tonal flatness.** Depth comes from 2–3 tonal steps of the same
   near-neutral surface (canvas → panel → control/field), separated by
   hairline 1px borders — not from shadows, bevels, or gradients.
2. **Continuous-corner geometry, one scale.** Panels/cards ~12–16pt radius,
   controls/fields ~7–10pt, pills for segments and chips. Nothing square,
   nothing bubble-round; one consistent scale everywhere.
3. **Quiet icon rails.** Icon-only rails with rounded-square hit areas;
   the selected item gets a soft tinted fill and/or a 1px accent outline —
   never a full accent block.
4. **Section headers as anatomy.** Small leading icon + medium-weight title
   + trailing quiet action (info/expand), then a hairline divider. Forms are
   label-left / filled-rounded-field-right with generous vertical rhythm.
5. **Chips carry metadata.** Inline code, paths, language names, counts, and
   statuses render as small filled chips/badges rather than raw text.
6. **Content blocks are cards.** Code blocks, collapsible "reasoning"
   sections, and composers are rounded cards with a header row (leading
   label/chip, trailing icon actions) on a slightly elevated surface.
7. **Accent is scarce.** One brand accent used for selection outline, active
   nav item, and the primary action; semantic colors only for meaning.
   Everything else is neutral text hierarchy (primary/secondary/muted).
8. **Composition split.** Conductor (the only macOS-native reference) uses
   **flush panels** divided by hairlines. The web tools float **cards with
   gutters** on a canvas. Both read modern; flush-panels is the
   macOS-appropriate base, cards the overlay/content language.

## Direction (recommendation)

**Base composition: Conductor-style flush flat panels.** Sidebar, editor,
utility panel, terminal, and status bar are flat theme surfaces separated by
hairline `borderSubtle` dividers — no floating gutters between the main
panes, no material blur stacks, no bevels. This keeps `NavigationSplitView`,
the native toolbar, traffic lights, and every accessibility behavior intact
while removing the "older Mac app" cues (system material sidebars, heavy
toolbar chrome, mixed control styles).

**Card language for everything that overlays or embeds.** Command palette,
peek view, hover tooltip, sheets, popovers, welcome screen tiles, Markdown
code blocks, the diff header, the commit composer, and the terminal header
adopt the rounded-card-with-header-row anatomy from the references.

**Themes stay the authority.** All six bundled themes, user themes, and
AI-generated themes keep working unchanged: new appearance needs are met by
(a) reusing existing tokens and (b) a small set of **optional** new `ui`
keys with derived fallbacks — the exact pattern the theme engine already
uses. Branding stays Indigo/Khadi-first; the refresh changes geometry,
rhythm, and restraint, not hue.

This direction needs one durable decision recorded: AGENTS.md currently says
"use system-adaptive chrome … do not paint native sidebars with opaque
custom backgrounds." The polish pass already partially superseded that at
user direction (theme-tinted sidebar at 0.85 opacity). Going fully flat is a
product-appearance decision among alternatives → **ADR 0012** (reserved
here): *Flat layered workbench chrome — theme surfaces + hairlines replace
system materials in workspace windows; native toolbar/menus/traffic lights,
standard controls, and accessibility behaviors retained; no Liquid Glass, no
per-document web views.* Settings and system alerts stay native.

## Token and metrics plan (foundation, additive only)

New **code-side** constants (not theme JSON) — `RafuMetrics` in
`Sources/RafuApp/Support/`:

- `radiusPanel = 12`, `radiusControl = 7`, `radiusField = 8`,
  `radiusChip = 999` (capsule), all `.continuous`.
- Spacing grid: 4/8/12/16/20; row height 26–28; section header height 34.
- Hairline = 1 (borderSubtle), emphasized = 1 (borderStrong).

New **optional** `ui` theme keys, each with a derived fallback so every
existing theme file decodes identically (same mechanism as the 2026-07-13
schema expansion; `AIThemePrompt` schema updated in the same increment):

| Key | Purpose | Fallback derivation |
|---|---|---|
| `cardBackground` | Overlay/embedded cards | `elevatedBackground` |
| `fieldBackground` | Filled form inputs, palette input, composer | blend(`appBackground` → `elevatedBackground`) |
| `chipBackground` | Chips/badges/kbd hints | `hover` |
| `accentSoft` | Selected-nav fill, active-segment wash | `accent` at ~14% |

Explicitly **not** added: shadow tokens (flat = no shadows beyond system
popover/sheet defaults), gradient tokens, per-surface radii in JSON
(geometry is product identity, not theme identity).

Motion defaults (apple-design): hover/press feedback ≤120ms ease-out
(already the house style); overlay enter = spring(damping 1.0, response
0.25–0.3) scale 0.98→1 + fade **anchored to the invoking control**; exits
mirror entries; zero motion added to typing/caret/tab-switch paths; Reduce
Motion → cross-fade only; Reduce Transparency → drop every `.opacity()`
wash to solid token color; Increase Contrast → `borderStrong` replaces
`borderSubtle` on interactive boundaries.

## Surface-by-surface mapping (what goes where)

| Rafu surface (file) | Today | Reference cue → target |
|---|---|---|
| Window + titlebar (`WorkspaceWindowView`, `RafuApp` scene) | Native toolbar band over themed panels | Conductor: unified/transparent titlebar so the theme canvas runs edge-to-edge behind traffic lights; toolbar keeps native items, loses visual band |
| Files sidebar (`WorkspaceSidebarView`) | List `.sidebar` style on 0.85 tinted wash | Flush flat panel on `sidebarBackground` (solid); header row per reference anatomy (leading glyph + "FILES" + trailing quiet icon buttons — already close); rows keep 6pt-radius hover/selection; git badges unchanged; trailing metadata column reserved (Conductor's timestamp slot) |
| Utility rail (`WorkspaceUtilityRail`) | Icon strip | AI-app rail: rounded-square buttons (26–28), selected = `accentSoft` fill + 1px accent outline; spacing opened to 8 |
| Utility panel: Search + Source Control (`WorkspaceNavigatorView`, `GitInspectorView`) | Themed stack, mixed field styles | Widget-properties anatomy: section headers (icon + title + trailing action + hairline); every input becomes filled `fieldBackground` rounded-8 field; Changes/History uses restyled `RafuSegmentedPicker` (connected pills, `accentSoft` active); commit box becomes a composer card (rounded-12, field + trailing prominent Commit); stash/blame rows as hover rows with chip metadata |
| Editor tab bar (`EditorGroupTabBar`) | 0.92 washes, active-tab block | Conductor tabs: quiet text tabs on flat `tabBarBackground`; active tab = `tabActiveBackground` rounded-top card OR underline (decision D3); dirty dot + close on hover; height trimmed ~28 |
| Breadcrumbs (`EditorBreadcrumbView`) | Text path | Chip-styled clickable crumbs (capsule `chipBackground` on hover only — quiet at rest) |
| Editor canvas + gutter | Already token-driven | Unchanged mechanics; verify tonal step vs tab bar/status bar reads as one flat family |
| Diff view (`GitSideBySideDiffView` header) | Header on 0.97 wash | Card header row: file chip + scope + ±stats chips + trailing actions (stage hunk) |
| Blame canvas header | Table header wash | Same card-header anatomy |
| Status bar (`WorkspaceStatusBar`) | 26pt, 0.92 wash | Slim flat bar (24), solid `statusBarBackground`, hairline top; memory/LSP/branch as quiet chips; color never sole channel (existing rule) |
| Terminal panel (`WorkspaceTerminalPanel`) | Header + tabs | Header row anatomy; terminal tab chips = capsules; body untouched (SwiftTerm) |
| Command palette (`CommandPaletteView`) | Themed glass sheet | Floating rounded-14 card: large `fieldBackground` input, hairline, hover-row results with chip kbd-hints, footer hint row (AI-app composer language); enter/exit spring per motion defaults |
| Peek view / hover tooltip (`NavigationPeekView`, hover popover) | Themed panels | Rounded-12 cards, header row (symbol chip + path), hairline-separated body |
| Resources popover (`ResourcesView`) | List | Card rows: process name + RSS as trailing tabular-nums chip |
| Sheets: trust prompt, file creation, quit confirm, install consent | Ad-hoc paddings | One sheet template: icon + title header, label-left/field-right form rows, trailing action row (secondary + prominent); consistent 22–24 padding, rounded per system sheet |
| Welcome screen (in `EditorCanvasView`) | Shortcut hints + recents | Hero glyph + two card groups: Recent Workspaces (icon + name + path chip) and Shortcuts (kbd chips) — the one place allowed a slightly larger display treatment (tightened tracking per apple-design type rules) |
| Markdown preview (`MarkdownPreviewView` + theme `fonts.markdownPreview`) | Native MarkdownUI | Code blocks get card treatment: header row (language chip + copy), body on `cardBackground`; also closes the long-open "fonts.markdownPreview unused" item |
| Settings (`RafuSettingsView`) | Native forms | Stays native macOS Settings (AGENTS: standard controls first); only control accent + field tinting via existing tokens |

Non-goals (unchanged from AGENTS): no Liquid Glass recreation, no
translucent blur stacks, no custom traffic lights, no window-shape changes,
no decorative motion on typing/tab/caret paths, no WKWebView anywhere, no
theme-JSON breaking changes.

## Increments (each = advisor → implementor → verify → documentor)

- **U0 — Foundation (no visible change).** DONE (cfab4e8). ADR 0012 authored (Proposed); `RafuMetrics`; four optional palette keys + fallback derivations + decode tests; `AIThemePrompt` schema row additions. Gate: build, full suite, every bundled theme + one AI-generated theme decodes byte-identically in rendered output.
- **U1 — Shell.** DONE (9971888). Titlebar unification, sidebar flush-flat + header, rail restyle, status bar slim, hairline discipline pass. Gate: `--verify`, second window, sidebar toggle/menu paths, VoiceOver landmark pass, Reduce Transparency check.
- **U2 — Editor chrome.** DONE (c9d6eb8). Tab bar, breadcrumb chips, diff/blame headers, find bar, guard/merge banners. Gate: tab drag/split/hibernation regression pass + typing-path untouched.
- **U3 — Panels & forms.** DONE (6b46423). Git inspector sections/fields/composer, search panel, sheet template applied to all five sheets. Gate: keyboard-only commit + stage/unstage/stash flows; Full Keyboard Access.
- **U4 — Overlays.** DONE (c9d6eb8). Command palette, peek, hover tooltip, Resources, welcome screen; overlay motion. **Deferral:** trigger-anchored spring motion — `.sheet` is system-animated, card visuals kept.
- **U5 — Content & close-out.** DONE (c9d6eb8). Terminal header, Increase Contrast audit. **Deferral:** `fonts.markdownPreview` — ThemeFonts schema has no such key; plan assumption was stale, NOT wired.

Sequencing rationale: U0 unblocks everything and is invisible; U1 is the
single biggest perceptual change and lands before dependent surfaces so
tonal steps are judged against the final shell; overlays (U4) come after
panels so the card language has one authoritative in-app example first.
User eyeballs and approves after each increment — this is an
appearance-driven phase; screenshots accompany every handoff.

## Open decisions for the user (before U0)

- **D1 — Composition base:** flush flat panels (recommended, Conductor-style,
  documented above) vs floating cards-with-gutters for the main panes
  (bigger departure; likely requires replacing `NavigationSplitView` with a
  custom split — more risk, defers native sidebar behaviors). Plan assumes
  flush.
- **D2 — Corner personality:** 12pt panels / 7–8pt controls (recommended,
  matches references) vs sharper 8/6.
- **D3 — Active editor tab:** rounded-top connected card (VS Code-like,
  reference IMG_5367 tab row) vs flat underline (quieter). Recommend
  underline + slightly brighter text: flattest, calmest.
- **D4 — Titlebar:** unified transparent (recommended) vs keep the current
  toolbar band.
- **D5 — Light themes:** the references are all dark. Khadi (light) gets the
  same geometry with its own tonal steps — confirm light-theme parity is a
  gate, not an afterthought (plan assumes yes; every increment's screenshot
  set includes Khadi).

## Verification contract (whole phase)

`swift build` zero warnings; full suite green (677 baseline); format lint;
`./script/build_and_run.sh --verify` per increment; screenshot set per
increment (Indigo + Khadi + one AI theme, both windows); accessibility
passes as listed per increment; idle-RSS glance unchanged (~34 MB debug
baseline); no new dependencies; `Package.swift` untouched.
