# UI design language — flat, modern, layered

- **Applies to:** themes, palette tokens, RafuMetrics spacing/radius, shared components, button styles, toolbar configuration, and surface-level chrome across all Rafu windows
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-18

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

- **Custom ButtonStyle and sheet keyboard shortcuts:** SwiftUI's `ButtonStyle` modifier does **not** confer window default/cancel semantics that `.defaultAction`/`.cancelAction` keyboard shortcuts require. Sheets must apply `.keyboardShortcut(.defaultAction)` to the prominent button and `.keyboardShortcut(.cancelAction)` to the secondary/cancel button **independently** of any button style. This ensures sheets respond to Return/Escape correctly.

- **Unified titlebar:** `.toolbarBackground(.hidden, for: .windowToolbar)` removes the native toolbar visual band, allowing the themed canvas to run edge-to-edge behind traffic lights while keeping the native toolbar items and window controls intact. This requires keeping the scene as `WindowGroup` and not adding custom window decorations.

- **Surface-to-token mapping** (every visible surface routes through one of these):
  - Window/pane canvas: `appBackground` (baseline app background, solid).
  - Sidebar: `sidebarBackground` (solid flush panel, ~85% tinted wash in prior checkpoint; now flat token-driven).
  - Editor tab bar: `tabBarBackground` (quiet surface); active tab: `tabActiveBackground` + rounded-top card OR underline.
  - Editor canvas: `editorBackground` (unchanged mechanics; tonal step vs. tab bar/status bar reads as one flat family).
  - Status bar: `statusBarBackground` (slim flat bar, 24pt height, solid; memory/LSP/branch as quiet chips).
  - Panels (Search, Source Control): `panelBackground` (slightly elevated from sidebar); sections with `RafuCardHeaderRow` (icon + title + trailing action + hairline).
  - Overlays (command palette, peek, hover tooltip, sheets): `cardBackground` (rounded 14pt card, floating on the canvas); headers use `RafuCardHeaderRow`, body separated by hairline.
  - Diff view header: `cardBackground` rounded-12 card anatomy (file chip + scope + ±stats chips + trailing actions).
  - Blame header and row hover: same card header anatomy.
  - Terminal header: card header row; body untouched (SwiftTerm).
  - Welcome screen: hero glyph + two card groups (Recent Workspaces, Shortcuts).
  - Markdown code blocks: `cardBackground` rounded-12 card (header row with language chip + copy action, body on card surface).
  - Settings: native macOS Settings forms (standard controls only; control accent + field tinting via existing tokens, no custom cards).

- **Motion defaults** (per apple-design skill):
  - Hover/press feedback: ≤120ms ease-out (house style).
  - Overlay enter: spring(damping 1.0, response 0.25–0.3) scale 0.98→1 + fade. System `.sheet` is already system-animated; custom overlays (popovers, NSPopover) use the spring. **Deferral:** Trigger-anchored spring motion was the original plan, but `.sheet` is system-animated with no anchor control API; card visuals were kept and system motion accepted.
  - Overlay exit: mirror entry.
  - Zero motion added to typing/caret/tab-switch paths.
  - Reduce Motion → cross-fade only.
  - Reduce Transparency → drop every `.opacity()` wash to solid token color.
  - Increase Contrast → `borderStrong` replaces `borderSubtle` on interactive boundaries.

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

Tests verify that every bundled theme plus AI-generated themes decode identically: `sources/RafuApp/Tests/ThemeTests.swift` snapshots palette values for Indigo, Khadi, and one generated theme at theme parse time.

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
- `Sources/RafuApp/DesignSystem/` (RafuChip, RafuField, RafuCardHeaderRow, RafuSheetHeader)
- `Sources/RafuApp/Theme/RafuThemePalette.swift` (four optional `ui` keys + fallbacks)
- `Sources/RafuApp/App/RafuApp.swift` (titlebar `.toolbarBackground(.hidden)`)
- `docs/decisions/0012-flat-layered-workbench-chrome.md` (ADR 0012 — Proposed)
- `docs/plans/phases/ui-flat-modern-refresh.md` (U0–U5 increments; deferrals: spring anchoring, fonts.markdownPreview)
- `docs/plans/phases/git-experience-and-worktrees.md` (GX1–GX5 adopt the same design language)
