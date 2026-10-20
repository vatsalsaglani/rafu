# UI design language — flat, modern, layered

- **Applies to:** themes, palette tokens, RafuMetrics spacing/radius, shared components, button styles, toolbar configuration, and surface-level chrome across all Rafu windows
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-18; theme-tint and pane-strip rules re-verified on 2026-07-26 (UX2-01)

**Window composition superseded (2026-10-19).** The framed workbench
([ADR 0030](../decisions/0030-framed-workbench-left-rail-and-detached-tabs.md),
accepted on the user's direction) replaces the window-level parts of the
surface map below. Current language:

- **Frame.** The window frame — titlebar zone, `WindowTitlebarRow`, status bar
  — is `appBackground`. It is the quiet rear plane. (The titlebar band no longer
  takes `sidebarBackground`.)
- **Card.** The editor deck is the one raised rounded card: 8 pt
  `workbenchInset`, 10 pt `radiusWorkbenchDeck`, and one soft theme-aware shadow
  (`WorkbenchDeckShadowStyle`: opacity 0.18 dark / 0.10 light, halved under
  Increase Contrast, radius 6 with y-offset 2 so its 8 pt reach fits the inset).
  The shadow goes on the card's background shape only — never on a TextKit or
  SwiftTerm viewport, and with no `clipShape` or `mask` over one. No material,
  blur, bevel, or gradient; Reduce Transparency is a no-op here.
- **Rail.** A 40 pt always-visible left `WorkspaceActivityRail` carries all five
  navigator modes, on a `WindowDragHandle` background. There is no right rail and
  no right utility panel. Sidebar bounds are 220 / 300 / 560 pt.
- **Tabs.** Detached `RoundedRectangle` cards of radius 10, `space1` spacing,
  `tabShelfHeight` 40 pt as a floor that grows with Larger Text. Selected:
  `tabActiveBackground` + a `borderStrong` hairline on all four edges + a tab
  shadow (radius 3, y 1) through the same helper. Inactive: `chipBackground`.
  The attached-cap grammar (`masksBottomSeam`, seam overlay,
  `radiusAttachedTab`) is removed.
- **Shadow budget.** Exactly two shadows exist in the workbench — the deck and
  the selected tab — and both go through `WorkbenchDeckShadowStyle`. A source
  test pins that count, so a third shadow is a test failure, not a review note.

**Proposed successor:** the 2026-07-29
[`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
and [ADR 0022](../decisions/0022-recessed-workbench-deck.md) propose revisiting
the flush-main-pane and single-radius rules below. Until ADR 0022 is accepted
and implemented, this note describes the verified current UI.

## Rules and observed behavior

- **RafuMetrics code constants** (`Sources/RafuApp/Support/RafuMetrics.swift`) define geometry that is **not** theme-JSON:
  - Radii: `radiusPanel = 12`, `radiusControl = 7`, `radiusField = 8`, `radiusChip = 999` (capsule), all `.continuous`.
  - Spacing grid: 4/8/12/16/20; section header height 34; row height 26–28.
  - Hairline dividers: 1pt `borderSubtle`, emphasized: 1pt `borderStrong`.

- **Four optional palette keys** with derived fallbacks so every existing theme file decodes identically (same mechanism as 2026-07-13 schema expansion):

| Key | Purpose | Fallback derivation |
|---|---|---|
| `ui.cardBackground` | Overlay/embedded cards | `elevatedBackground` |
| `ui.fieldBackground` | Filled form inputs, palette input, composer | blend(`appBackground` → `elevatedBackground`) |
| `ui.chipBackground` | Chips/badges/kbd hints | `hover` |
| `ui.accentSoft` | Selected-nav fill, active-segment wash | `accent` at ~14% opacity |

- **Shared SwiftUI components** for consistent surface presentation:
  - `RafuChip`: small filled badge for language names, counts, paths, kbd hints (capsule radius, `chipBackground`, text `textMuted`).
  - `RafuCardHeaderRow`: leading icon/chip + centered title + trailing quiet action button, hairline divider below (used in peek cards, composer, diff header, section headers).
  - `RafuField`: filled form input (radius `radiusField`, background `fieldBackground`). **Critical:** Custom filled fields lose the `.roundedBorder` system focus ring on `@FocusState`. Apply `.focusRing(.outer)` when `isFocused` to preserve Full Keyboard Access and Reduce Contrast visibility. This is a macOS AppKit interop requirement — empty or translucent fields get the system ring automatically, but opaque custom-filled fields must render it explicitly.
  - `RafuSheetHeader`: icon/title + subtitle, matching system sheet scale and alignment.

- **Theme roots must set `tint`, not just `\.rafuTheme`.** Rafu hand-draws
  most of its chrome, but it still uses stock SwiftUI controls whose accent
  it does not paint: `Toggle`'s switch, determinate `ProgressView`, `Slider`,
  `Stepper`, `ColorPicker`, text selection. Those render in the *system*
  accent — blue — unless a tint is in scope, which is why blue switches
  survived the first accent sweep in Settings → General. `View.rafuTheme(_:)`
  (`Sources/RafuApp/Support/RafuControlStyles.swift`) installs the theme and
  `.tint(theme.palette.accent)` together and is the **only** sanctioned way
  to write the `rafuTheme` environment key; `ThemedControlStyleScanTests`
  fails on any other write. Fixing this per call site does not scale — the
  sweep is one line per scene root (workspace window, Settings, notch
  companion, notch HUD).

- **`.tint` does not reach AppKit-backed control chrome.** `Picker(.segmented)`
  was the first casualty (hence `RafuSegmentedPicker`); `TabView`'s macOS bar
  is the second, and Settings now draws `SettingsPaneStrip` instead (see
  [`settings-surface.md`](settings-surface.md)). Rule of thumb: if the
  control is a SwiftUI-drawn control, `.tint` themes it; if it is
  AppKit segmented-control chrome, it must be replaced.

- **Custom ButtonStyle and sheet keyboard shortcuts:** SwiftUI's `ButtonStyle` modifier does **not** confer window default/cancel semantics that `.defaultAction`/`.cancelAction` keyboard shortcuts require. Sheets must apply `.keyboardShortcut(.defaultAction)` to the prominent button and `.keyboardShortcut(.cancelAction)` to the secondary/cancel button **independently** of any button style. This ensures sheets respond to Return/Escape correctly.

- **Unified titlebar (superseded):** the original `.toolbarBackground(.hidden, for: .windowToolbar)` treatment predates dropping the `NSToolbar` entirely. The current recipe — `FlatWindowChrome` + `.ignoresSafeArea(.top)` content merge, the `_NSTitlebarDecorationView` scrub, and the since-superseded traffic-light hover-reveal — is documented in [`flat-window-chrome-titlebar-merge.md`](flat-window-chrome-titlebar-merge.md).

- **Surface-to-token mapping** (every visible surface routes through one of these):
  - Window/pane canvas: `appBackground` (baseline app background, solid).
  - Sidebar: `sidebarBackground` (solid flush panel, ~85% tinted wash in prior checkpoint; now flat token-driven).
  - Editor tab bar: `tabBarBackground` (quiet surface); active tab: `tabActiveBackground` + rounded-top card OR underline.
  - Editor canvas: `editorBackground` (unchanged mechanics; tonal step vs. tab bar/status bar reads as one flat family).
  - Status bar: `statusBarBackground` (slim flat bar, 24pt height, solid; memory/LSP/branch as quiet chips).
  - Panels (Search, Source Control): the current utility container uses
    `sidebarBackground` at reduced opacity; embedded headers/sections use
    `cardBackground`. There is no `panelBackground` palette property.
    The proposed presentation successor uses the existing
    `elevatedBackground` for a solid utility surface.
  - Overlays (command palette, peek, hover tooltip, sheets): `cardBackground` (rounded 14pt card, floating on the canvas); headers use `RafuCardHeaderRow`, body separated by hairline.
  - Diff view header: `cardBackground` rounded-12 card anatomy (file chip + scope + ±stats chips + trailing actions).
  - Blame header and row hover: same card header anatomy.
  - Terminal header: card header row; body untouched (SwiftTerm).
  - Welcome screen: hero glyph + two card groups (Recent Workspaces, Shortcuts).
  - Markdown code blocks: `cardBackground` rounded-12 card (header row with language chip + copy action, body on card surface).
  - Settings: native macOS grouped `Form`s at the host's full width (no readable-measure clamp), under a `tabBarBackground` pane strip whose selected pill is `accentSoft` + `accent` glyph/label. Standard controls only, tinted by the theme root; no custom cards.

- **Motion defaults** (per apple-design skill):
  - Hover/press feedback: ≤120ms ease-out (house style).
  - Overlay enter: spring(damping 1.0, response 0.25–0.3) scale 0.98→1 + fade. System `.sheet` is already system-animated; custom overlays (popovers, NSPopover) use the spring. **Deferral:** Trigger-anchored spring motion was the original plan, but `.sheet` is system-animated with no anchor control API; card visuals were kept and system motion accepted.
  - Overlay exit: mirror entry.
  - Zero motion added to typing/caret/tab-switch paths.
  - Reduce Motion → cross-fade only.
  - Reduce Transparency → drop every `.opacity()` wash to solid token color.
  - Increase Contrast → `borderStrong` replaces `borderSubtle` on interactive boundaries.

### Workbench chrome values current as of 2026-10-20 (ADR 0031)

These supersede the ADR 0030 values that earlier sections of this note
describe. The authority is
[ADR 0031](../decisions/0031-card-header-tabs-and-themed-chrome.md).

| Surface | Value |
|---|---|
| Deck | radius 12, inset 12 on all four sides (also beside a collapsed sidebar: the handle's 10 pt hit area counts toward the gutter); shadow 0.55 dark / 0.14 light, radius 8, y 4 (round 4); corner wedges repaint frame + shadow; dark themes add a 1 pt inner top highlight (white 6 %) |
| Selected tab | `tabActiveBackground` (Indigo `#222A38`, Khadi `#FFFFFF`) + `borderSubtle` hairline (`borderStrong` under Increase Contrast); semibold 12.5 pt; shadow 0.40 dark / 0.18 light, radius 4 |
| Inactive tab | **Unfilled** — no `chipBackground`, no outline; medium 12.5 pt |
| Tab accent edge | None. `StitchedAccentEdge` is removed |
| Tab shelf | Fixed 38 pt (5 pt breathing), painted `tabBarBackground`: Indigo `#181D29` (= card), Khadi `#F3EEE3` (one step below the card `#FAF7F0`). An unset `tabBarBackground` falls back to `editorBackground` |
| Header hairline | Exactly one. The shelf hairline is hidden when a breadcrumb follows |
| Breadcrumb | Card tone, 26 pt tall, 12 pt padding |
| Shelf overflow | Leading fade only while scrolled; 48 pt trailing fade (round 4, from 28) with an 8 pt gap before `+` / `⌄`. Both grey — never accent. `ScrollViewReader` reveals the selected tab |
| Indigo frame and card | Frame `#090B10` for `appBackground`, `sidebarBackground`, `statusBarBackground`; card `#181D29` for `editorBackground`, `tabBarBackground`, `editor.background`, `editor.gutterBackground`; `hover` `#202735`, `lineHighlight` `#1D2335`, `elevatedBackground` `#1E2432`; `borderStrong` `#6A748D` (3:1 gate) |
| Khadi frame | `#EBE5D8` for `appBackground`, `sidebarBackground`, `statusBarBackground`; `hover` `#E4DCCB`; `selection` `#DDD3BE` (stays stronger than hover); card `#FAF7F0` |
| Window minimum | 774 pt (40 + 220 + 10 + 472 + 24 = 766 + margin) |
| Sidebar seam | None at rest; grab bar on hover only |
| Activity Rail | Selection fill + `borderSubtle` hairline, 15 pt glyph, 6 pt spacing, 10 pt top inset; `RafuRailAppTile` draws `RafuSeamGlyph` natively on a `tabActiveBackground` tile, non-interactive and `accessibilityHidden` |
| Files tree | `RafuFileTreeDisclosureStyle` + `FileTreeMetrics` (row 26, indent 14, selection radius 6, 16 pt icon slot, 4 pt icon-to-name gap, trailing row inset 8); indent guides with a strong segment beside the selected child |
| Sidebar header | `magnifyingglass` filter + one `plus` menu (New File…, New Folder…, Add Folder to Workspace…); 19 pt top padding so the title centre aligns with the tab labels' centre |
| Scrollers | Editor: `EditorThemedScroller` — theme track and knob, `isCompatibleWithOverlayScrollers` overridden, `scrollerStyle` never written. Files `List`: `OverlayScrollerConfigurator` forces overlay style on that one scroll view (round 4) |
| Ensemble symbol | `circle.hexagongrid` everywhere |

Increase Contrast now does three things in the workbench: promotes the tab
hairline to `borderStrong`, halves the deck shadow, and halves the tab shadow.

**Not yet verified by a person:** round 3's visuals were checked only by window
screenshots and a Fable review; the screen has been locked since, so no
light/dark × Indigo/Khadi pass has been done on them.

## Why it matters

The flat, modern, layered language unifies Rafu's visual identity across fifty+ surfaces without forcing a monolithic design system or theme-JSON bloat. All six bundled themes (Indigo, Khadi, and four AI-generated) and future user themes decode identically by leveraging optional `ui` keys with derived fallbacks. The shared components (chip, field, header row, sheet header) ensure consistent rhythm, touch targets, and accessibility (via standard controls + explicit focus rings). The geometry in RafuMetrics is product identity, not theme identity — it anchors every corner radius and spacing decision.

Custom filled form fields require explicit focus rings because macOS TextKit fields behave differently than empty container views. Button styles do not carry keyboard shortcut semantics, so sheets need independent `.keyboardShortcut` modifiers to respond to Return/Escape. The unified titlebar preserves native window chrome (traffic lights, menus, commands) while allowing themed content edge-to-edge behind it — a macOS-native design pattern that avoids custom window chrome or Liquid Glass recreation.

## Reproduction or evidence

Every surface in the app — sidebar, editor tabs, panels, overlays, cards — follows the surface-to-token mapping table above. Build the app and inspect any window:

- Sidebar: solid `sidebarBackground`, section headers with icon + title + hairline.
- Overlays: rounded-14 `cardBackground` card with `RafuCardHeaderRow` anatomy (icon/title + trailing action + hairline).
- Form inputs: `RafuField` with `isFocused ? .focusRing(.outer) : nil` applied.
- Sheets: prominent button with `.keyboardShortcut(.defaultAction)`, cancel button with `.keyboardShortcut(.cancelAction)`.
- Status bar: flat `statusBarBackground`, memory/LSP/branch as quiet `RafuChip` badges.

Tests verify that every bundled theme plus AI-generated themes decode
identically: `Tests/RafuAppTests/RafuThemeTests.swift` snapshots palette values
for Indigo, Khadi, and generated-theme parsing.

## Verification

```bash
./script/build_and_run.sh --verify
```

Screenshot visually across Indigo + Khadi + one AI theme, both windows. Verify:
- Titlebar is transparent; traffic lights are native.
- Sidebar is a flat solid surface with hairline edges.
- Panels (Search, Source Control) have card-header anatomy (icon + title + action + hairline).
- Command palette is a floating rounded card with spring entry motion.
- Focus rings appear on form inputs when tabbed into (Full Keyboard Access).
- Reduce Motion disables springs, Reduce Transparency drops opacity washes to solid colors, Increase Contrast strengthens borders.
- All surfaces read as one flat family: app → sidebar → panels → editor → status bar → overlays are ordered tonal steps, no bevels/shadows/gradients.

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/RafuMetrics.swift` (spacing/radius constants)
- `Sources/RafuApp/Support/RafuControlStyles.swift` (`View.rafuTheme(_:)` — theme + tint at scene roots)
- `Sources/RafuApp/Settings/SettingsPaneStrip.swift` (themed replacement for the macOS tab-view bar)
- `Tests/RafuAppTests/ThemedControlStyleScanTests.swift` (system-accent source scan)
- `Sources/RafuApp/Support/RafuControlStyles.swift` (RafuChip, RafuField,
  RafuCardHeaderRow, RafuSheetHeader)
- `Sources/RafuApp/Support/RafuTheme.swift` (palette, optional `ui` keys, and
  fallbacks)
- `Sources/RafuApp/Views/FlatWindowChrome.swift` and
  `Sources/RafuApp/Views/WorkspaceWindowView.swift` (current titlebar/window
  chrome; the former `.toolbarBackground(.hidden)` route is no longer present)
- `docs/decisions/0012-flat-workbench-chrome.md` (ADR 0012 — Proposed)
- `docs/decisions/0022-recessed-workbench-deck.md` (proposed composition
  successor)
- `docs/plans/phases/ui-flat-modern-refresh.md` (U0–U5 increments; deferrals: spring anchoring, fonts.markdownPreview)
- `docs/plans/phases/git-experience-and-worktrees.md` (GX1–GX5 adopt the same design language)
