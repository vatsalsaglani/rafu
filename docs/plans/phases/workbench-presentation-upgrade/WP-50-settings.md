# WP-50 — Adaptive Settings hierarchy and dense native controls

## Status and execution slot

- **Status:** Planned.
- **Wave:** 1; parallel.
- **Suggested branch:** `codex/presentation-settings`.
- **Recommended model:** `gpt-5.6-terra` with xhigh reasoning.
- **Required base:** exact `<FOUNDATION_SHA>`.
- **Merge round:** before WP-60.

## Goal

Turn the current dashboard-like Settings canvas into a bounded, readable
desktop hierarchy: an attached Settings tab, compact category navigation,
clear page headings, and small theme-owned sections containing native controls.
Preserve pane lifetime, editor/native routing, per-window ownership, focus, and
all existing settings behavior.

## Required reading and skills

Read:

- `AGENTS.md`
- [`README.md`](README.md)
- [`WP-00-foundation.md`](WP-00-foundation.md)
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
- parent plan section F, P4, verification, and risks
- ADR 0012 and ADR 0022
- `docs/references/settings-surface.md`
- `docs/references/ui-design-language.md`
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with latest APIs, view structure, layout,
accessibility, focus, scroll, and macOS scenes/views. Use Build macOS Apps
`swiftui-patterns`, especially Settings and split-layout guidance. The existing
editor-hosted route and native Settings scene are both deliberate.

## Exclusive ownership

Source:

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

Tests:

- `Tests/RafuAppTests/SettingsCanvasTests.swift`
- new `Tests/RafuAppTests/SettingsPresentationTests.swift`

Documentation:

- this plan's implementation record
- one uniquely named reference note only for a newly verified reusable
  Settings/lifecycle/accessibility nuance

Do not edit `ThemedControlStyleScanTests.swift` (WP-90 owns the global scan),
WP-00 support files, `WorkspaceSession.swift`, scene/app entry points,
provider/service/store logic, `Package.*`, shared indexes, or another lane's
files.

## Implementation

### P1. Attach the Settings canvas tab

Use WP-00's attached-tab primitive in `SettingsCanvas`. Preserve:

- the editor-hosted route;
- close/Escape behavior;
- per-window selection;
- non-restoration;
- native Settings fallback through ⌘, when no editor route is appropriate.

Do not introduce a new scene or modal sheet.

### P2. Replace the tile strip with adaptive navigation

Rename the type/file to `SettingsPaneNavigation` and provide two variants:

- regular: 188 pt vertical category column;
- compact: top category popup/row.

Seven categories remain real `Button` controls with icon, label, help,
selected trait, Full Keyboard Access, and stable identity. Regular rows are
32 pt default minimum with 14 pt icons and 4 pt selected radius.

Choose the variant from Settings canvas available width, not window width:

- regular at 812 pt or wider;
- compact below 812 pt;
- derive the breakpoint from an input that does not depend on the selected
  variant's own size.

Use one pure breakpoint function for testability.

### P3. Preserve pane lifetime across adaptation

Keep:

- `visitedPanes`;
- one retained `ZStack` host;
- hidden-pane `.opacity`, `.disabled(true)`, and
  `.accessibilityHidden(true)`;
- `paneContent` outside the navigation-variant conditional;
- stable pane identity and no I/O in view initialization.

Do not replace the host with `AnyLayout`, duplicate it in both branches, or make
off-screen settings lazy. Resizing through the breakpoint must not rerun probe
tasks, reset scroll/focus, or make hidden controls reachable.

### P4. Add page hierarchy and bounded measure

Add title/subtitle metadata to `SettingsPane` and one shared page header:

- system proportional type;
- page column max 840 pt;
- regular combined group max 1,092 pt;
- 24 pt outer padding;
- 16 pt navigation/page gap;
- center the combined group in the canvas;
- left-align page text and controls.

General puts the app summary and common controls above the fold at 800 pt
content height. Every other pane introduces its page heading before the first
section.

### P5. Replace outer Form/Section geometry, not native controls

In `RafuSettingsView.form(for:)`, replace each outer grouped `Form` with a
non-lazy `ScrollView` and
`VStack(alignment: .leading, spacing: 24)`.

Convert outer page-grouping `Section` wrappers in every owned section file to
WP-00's `RafuSettingsSection`. Keep `Section` values that are semantically
nested inside a Picker/Menu native.

The shared container owns only:

- 6 pt radius;
- 14 pt inner inset;
- 36 pt normal minimum row height;
- theme separators between logical rows;
- 28 pt independent-section gap;
- header/content/footer structure and accessibility grouping.

Keep native `Toggle`, `Picker`, `TextField`, `Stepper`, `ColorPicker`,
`LabeledContent`, buttons, menus, labels, validation, focus, Keychain, network,
probe, usage, agent, language-server, and theme behavior. Do not hand-draw
their interaction.

Headers expose `.isHeader`; section containers use
`.accessibilityElement(children: .contain)` and source order equals visual and
VoiceOver order.

### P6. Larger-text and narrow-width behavior

Treat row/header numbers as minimums:

- rows expand for wrapped explanatory text;
- essential labels/reasons never use `textMuted` as their only carrier;
- controls reach native overflow/popup behavior before labels clip;
- category names remain readable in the compact variant;
- editor/terminal font settings are unrelated and unchanged.

### P7. Tests

Pin:

- all seven pane titles and unique glyphs;
- pure breakpoint: compact below 812, regular at/above 812;
- retained pane host exists once and outside variant selection;
- visited panes stay mounted, hidden panes disabled/accessibility-hidden;
- every converted page group uses `RafuSettingsSection`;
- heading and contain-not-combine semantics;
- page and combined maximum measures;
- editor route/native fallback/non-restoration/no-I/O-at-init contracts.

Run existing Conductor, Ensemble, AI provider, language-server, usage, and theme
settings tests without editing them.

## Acceptance and manual evidence

Focused checks:

```bash
./script/test.sh --filter \
  'SettingsCanvas|ConductorSettings|EnsembleSettings|AIProviderConfiguration|LanguageServer|Usage|RafuTheme|SettingsPresentation'
```

With the GUI lease:

- capture immediately below and at/above 812 pt of **available Settings canvas**
  width;
- repeatedly resize 792–832 pt with no oscillation, scroll jump, lost focus,
  state reset, or repeated task;
- at 900 pt editor width, no clipping; at 800 pt content height, General's
  common settings stay above fold;
- visit every pane twice and confirm a safe control/scroll position persists;
- verify the native Settings fallback without a workspace window;
- larger text expands rows/wraps copy;
- VoiceOver announces page and each section once, then controls in visual order;
- Full Keyboard Access reaches all categories and controls.

Capture Indigo, Khadi, converged surfaces, and Increase Contrast in regular and
compact variants.

## Verification and handoff

Complete all source, tests, and documentation before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Use the single Rafu Lightning GUI lease or report exact deferred checks. Commit
only owned paths, do not push, and remove `.build` after the green commit.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-50's adaptive, compact Rafu Settings hierarchy while preserving
pane lifetime, native controls, editor/native routing, and theme JSON
authority; verify and commit it locally."

You are in the dedicated worktree on branch codex/presentation-settings. Use
gpt-5.6-terra with xhigh reasoning.

Read AGENTS.md; the execution README; WP-00; WP-50;
pre-initial-push-workbench.md; parent Settings/P4/verification/risk sections;
ADR 0012 and ADR 0022; settings-surface.md; ui-design-language.md; and
skill-routing.md. Use swiftui-expert-skill and Build macOS Apps
swiftui-patterns Settings/split guidance.

Run `git status --short --branch`. Stop unless this is
codex/presentation-settings, clean, the initial `git rev-parse HEAD` equals the
coordinator-supplied exact `<FOUNDATION_SHA>`, and WP-00 is present. Touch only
the exact WP-50 source, test, plan, and allowed new-reference paths. Do not edit
the global themed-control scan, shared styles, WorkspaceSession, app/scene
roots, service/store logic, Package.swift, or shared indexes.

Use the shared attached tab. Rename the pane strip to adaptive navigation with
the pure 812 pt canvas-width breakpoint. Keep one retained pane host outside
the variant conditional. Add page metadata and bounded measure. Replace only
outer Form/Section geometry with RafuSettingsSection; keep every native control
and behavior. Preserve visited panes, hidden disabling/accessibility, native
fallback, non-restoration, and no-I/O-at-init. Verify large text and VoiceOver
order.

Add the exact tests and manual matrix in WP-50. Use the single Rafu Lightning
GUI lease or report precise deferrals.

Complete all changes before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change afterward. When holding the single GUI lease, run
`./script/build_and_run.sh --verify` and complete the manual matrix; otherwise
report the exact deferral. Stage only owned paths and create one local commit.
Do not push, merge, open a PR, or publish. After green gates and the successful
commit, remove only this dedicated worktree's `.build`; never remove the
primary checkout's cache. Report delivered behavior, SHA, renamed/changed
paths, gates, breakpoint/lifetime evidence, native-fallback and accessibility/
theme results, ADR/reference updates, deferred checks, risks, any intended
reference-index row, and the next dependency (merge WP-50 before WP-60).
Complete the Goal only after commit and handoff.
```
