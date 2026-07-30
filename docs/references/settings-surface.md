# Settings surface — canvas first, native scene when no window exists

- **Applies to:** the Settings command and ⌘, routing, the editor-hosted
  Settings canvas, the status-bar affordance, the native Settings scene, and
  Settings restoration/layout changes.
- **Last verified:** Swift 6.2 language mode (Swift 6.3.3, Xcode 26.6),
  macOS 26.5.2, on 2026-07-26 (UX-02; pane strip and full-width canvas, UX2-01).

**Proposed successor:** the Settings section of
[`workbench-presentation-upgrade.md`](../plans/phases/workbench-presentation-upgrade.md)
proposes compact adaptive category navigation and a bounded, left-aligned
content region, with theme-owned compact section containers around unchanged
native controls. Until ADR 0022 is accepted and that work is implemented, the
pane-strip, full-width, grouped-Form, routing, and lifetime rules below describe
the verified surface. The successor must preserve the routing and pane-lifetime
rules.

## Rule or observed behavior

Rafu has one seven-pane `RafuSettingsView` and two hosts:

1. A focused workspace or welcome window routes Settings to
   `WorkspaceSession.showSettings()`, which presents `.settings` in the
   editor canvas.
2. With no focused workspace session — including when every window is
   closed — `SettingsCommandRouter` invokes SwiftUI's `openSettings` action.
   The registered native `Settings` scene remains the reachable fallback.

`RafuAppCommands` replaces `.appSettings` with one `Settings…` command using
⌘,. It delegates only the host decision to `SettingsCommandRouter`; it does
not duplicate Settings content. The bottom-right status-bar button calls the
same session activator and carries both `accessibilityLabel("Open Settings")`
and `help("Open Settings")`.

The canvas is window-scoped and intentionally non-restorable.
`WorkspaceSession.settingsVisible` is ephemeral and is absent from
`RestorableWorkspace`. A relaunch restores the user's code/layout, never the
Settings surface.

## Seven-pane layout

The panes are General, Appearance, AI, Language Servers, Usage, Agents, and
Ensemble, enumerated by `SettingsPane` and drawn by `SettingsPaneStrip`
(`Sources/RafuApp/Settings/SettingsPaneStrip.swift`).

UX-02 kept SwiftUI's native `TabView`; UX2-01 replaced it, because its macOS
bar paints the selected tab with `NSColor.controlAccentColor` and ignores
`.tint` — the same AppKit segmented-control chrome that forced
`RafuSegmentedPicker` to exist. Under Indigo or Khadi the selected pane was a
system-blue rectangle in an otherwise fully themed window.

The replacement keeps the bar's anatomy (centered row, glyph over label, one
selected pill); only the pill's fill moves to the theme's `accentSoft` wash,
matching `RafuIconButtonStyle`'s active-nav treatment. Every pane is a real
`Button`, so Full Keyboard Access reaches all seven and VoiceOver reports
`.isSelected`.

**Pane lifetime is load-bearing.** `RafuSettingsView` tracks a `visitedPanes`
set and renders visited panes in a `ZStack`, hiding the inactive ones with
`.opacity(0)` plus `.disabled(true)` and `.accessibilityHidden(true)`. This
reproduces what the tab view did — contents built lazily on first visit, then
retained — so each pane's `.task`-driven load still runs once per Settings
session. A plain `switch` would re-run every load on each revisit (visible
re-spinning in Usage, Language Servers and Agents); an eager `ForEach` over
all seven would fire every pane's I/O the moment Settings opens, breaking the
no-I/O-at-init contract. `.disabled` is not cosmetic: `.opacity(0)` alone
leaves a hidden pane's controls focusable under Full Keyboard Access.

`SettingsPane` is `nonisolated` on its primary declaration. The GUI target
defaults to `MainActor` isolation, under which a test cannot even form a key
path to `\.title`.

The former `760 × 620` frame was a window-sizing decision and no longer lives
inside `RafuSettingsView`. UX-02's 820-point centered measure is also gone
(UX2-01, from dogfooding): a Settings canvas hosted in a wide editor window
looked like a narrow column floating in empty space. The content now fills
the host's width and is top-aligned at any canvas size; readability comes
from the grouped `Form`'s own insets rather than an outer clamp. The native
fallback scene owns its own `760 × 620` default window size.

## Why the native Settings scene remains

A canvas requires a window-owned `WorkspaceSession`. Deleting the Settings
scene would therefore make ⌘, a silent no-op after the last window closes, or
force the command to manufacture a workspace-less editor window solely to
host preferences. Keeping the standard scene is simpler, matches macOS
expectations in the no-window state, and avoids changing workspace-window
lifecycle semantics.

This deliberately narrows AGENTS.md's “standard scenes and controls before
custom chrome” rule: Rafu uses the editor canvas as the primary Settings host
only while a workspace/welcome window already supplies relevant context. The
standard Settings scene remains authoritative as the lifecycle fallback, and
the primary action remains available through the app menu and ⌘,; the
status-bar icon is a secondary, labelled affordance.

## Exclusivity and routing

Settings is a peer of the Ensemble graph and run-detail canvases. Its
activator clears those flags (and any open Git diff/blame canvas); their
activators and terminal reveal clear `settingsVisible`. Selecting a document
also makes the editor route win. These invariants keep resolver precedence
defensive rather than user-visible.

A welcome window is allowed to resolve `.settings` despite having no
descriptor, because it still owns a session and exposes the Settings
status-bar button. When every window is closed, there is no route resolution:
the command goes directly to the native Settings scene.

## Reproduction or evidence

- `./script/test.sh --filter "RafuAppTests.SettingsCanvasTests"` exercises
  seven focused cases. In particular, the focused-session command test proves
  that the canvas opens without invoking the fallback, and the nil-session
  test proves that the native fallback closure is invoked.
- The restoration test encodes `RestorableWorkspace`, verifies that no
  `settingsVisible` key exists, and verifies that a fresh session starts with
  Settings closed.
- Existing Settings tests run unchanged in the full suite, preserving
  `.task`-driven loading and model initialization behavior.
- `./script/build_and_run.sh --verify` launched the Rafu Lightning bundle on
  2026-07-26. With the phase worktree open, ⌘, presented Settings inside the
  existing `rafu` editor window; the status-bar button also reopened it. The
  accessibility tree exposed all seven tabs and the status button as “Open
  Settings”. Under UX2-01 the content now fills the canvas width instead of
  sitting in a centered 820-point column.
- `./script/test.sh --filter "ThemedControlStyleScanTests"` covers both
  halves of the guard: the source scan (no `TabView`, no unsanctioned
  `rafuTheme` environment write) and a behavioral check that all seven panes
  are present with unique glyphs and the expected labels.
- After the user requested no further UI-control automation, the no-window
  branch was verified through the nil-focused-session command test and source
  audit rather than another automated macOS UI action.

## Verification

```bash
./script/format.sh --lint
./script/build.sh
./script/test.sh --filter "RafuAppTests.SettingsCanvasTests"
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

Manual fallback check when UI control is permitted: close every Rafu window
without quitting the app, press ⌘,, and confirm the native Settings window
opens with all seven panes.

## Related code, ADRs, and phases

- `Sources/RafuApp/App/RafuApp.swift`
- `Sources/RafuApp/App/RafuAppCommands.swift`
- `Sources/RafuApp/Settings/RafuSettingsView.swift`
- `Sources/RafuApp/Settings/SettingsCanvas.swift`
- `Sources/RafuApp/Settings/SettingsPaneStrip.swift`
- `Tests/RafuAppTests/ThemedControlStyleScanTests.swift`
- [`ui-design-language.md`](ui-design-language.md) (theme tint at scene roots)
- `Sources/RafuApp/Settings/SettingsCommandRouter.swift`
- `Sources/RafuApp/Editor/EditorCanvasRoute.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Views/WorkspaceStatusBar.swift`
- `Tests/RafuAppTests/SettingsCanvasTests.swift`
- [`editor-canvas-routing.md`](editor-canvas-routing.md)
- `docs/plans/phases/ux/UX-02-settings-as-editor-tab.md`
