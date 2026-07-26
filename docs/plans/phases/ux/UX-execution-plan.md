# UX — Editor-hosted surfaces, theme fidelity, agent identity

- **Status:** Ready (2026-07-26). Driven by the first real dogfooding pass in
  Rafu Lightning.
- **Standing preference, stated by the user and binding on every plan here:**
  **avoid modal sheets.** A surface that can be an editor tab should be an
  editor tab. New modal presentations need an explicit reason.

## What the dogfooding pass found

| Observation | Diagnosis | Plan |
|---|---|---|
| New Ensemble + New Ensemble Run are modals | preference: editor tabs instead | UX-01 |
| Segmented pickers and a Run button render **system blue** | 4 sites use raw `.pickerStyle(.segmented)` / `.borderedProminent`; `RafuSegmentedPicker` and `RafuProminentButtonStyle` already exist and are simply not adopted | UX-00 |
| Panel header buttons truncate ("New Ensem…") | 40 pt-wide panel cannot fit two text buttons | UX-01 |
| Agent icons are tiny dots in the terminal `+` menu | **Measured (UX-03):** the SVGs are authored `width="1em"`, so `NSImage` reports a 1×1 intrinsic size, and AppKit draws `NSMenuItem.image` at the image's own size honouring no SwiftUI layout — so `.resizable().frame()` has no effect there. An SF Symbol on the same item reports 18×14, which is why `Label(_:systemImage:)` survived | UX-03 ✅ |
| Codex icon differs between the file tree and agent surfaces | two different assets: `codex.svg` (file tree, pre-existing) vs `agent-codex.svg` (lobe, AT-01) | UX-03 |
| Settings is a separate window | preference: editor tab + a button bottom-right | UX-02 |
| Want agents listed under "New Terminal" with icons and shortcuts | the inline list is also the *fix* for the NSMenu limitation | UX-03 |

The menu-icon finding is worth internalising twice over. First, the user's
preference for fewer popups and the platform's constraint point at the same
answer — moving agents out of the menu fixed both. Second, it is not specific
to the agent catalog: the file-tree icons are authored `1em` too and would
fail identically in a menu. **Any `1em` SVG handed to AppKit is 1×1 unless
something stamps a size on it**, so a vendor mark belongs in an inline
SwiftUI surface, not an `NSMenuItem`.

## Why UX-00 goes first

`EditorCanvasView.body` is a **38-branch `if/else` chain**. UX-01 and UX-02
each need to add canvas modes to it, and both also need routing state on
`WorkspaceSession`. Inserting into that chain twice, in parallel, is a
guaranteed conflict and leaves the file worse.

UX-00 is deliberately small: replace the chain with one resolved
`EditorCanvasRoute`, and adopt the themed control styles that already exist.
It unblocks UX-01/UX-02 and fixes the blue controls in one pass.

## The four plans

| # | Plan | Branch | Wave |
|---|---|---|---|
| UX-00 | [`UX-00-canvas-route-and-theme.md`](UX-00-canvas-route-and-theme.md) | `ux/00-canvas-route-and-theme` | **Merged 2026-07-26** (`4349dea`) — UX-01/UX-02 unblocked |
| UX-03 | [`UX-03-agent-identity-and-terminals.md`](UX-03-agent-identity-and-terminals.md) | `ux/03-agent-identity` | **Merged 2026-07-26** (`9d1492f`) |
| UX-01 | [`UX-01-ensemble-as-editor-tabs.md`](UX-01-ensemble-as-editor-tabs.md) | `ux/01-ensemble-tabs` | **Merged 2026-07-26** (`6116891`) |
| UX-02 | [`UX-02-settings-as-editor-tab.md`](UX-02-settings-as-editor-tab.md) | `ux/02-settings-tab` | **Merged 2026-07-26** (`059b7cf`) |

**Wave 1:** UX-00 and UX-03 in parallel. UX-03 touches only the terminals
panel and the icon catalog; UX-00 touches canvas routing and control styles.
No overlap.

**Wave 2:** UX-01 and UX-02 in parallel, after UX-00 merges. Both add a case
to `EditorCanvasRoute` and a seam to `WorkspaceSession` — additive, at anchors
each plan names, which is a far smaller collision than the old chain.

## Shared-file ownership

| File | Owner | Everyone else |
|---|---|---|
| `Views/EditorCanvasView.swift` | UX-00 creates the route; UX-01 and UX-02 each add one case | UX-03: never |
| `Models/WorkspaceSession.swift` | UX-01 (Ensemble seam), UX-02 (settings seam) — anchored | UX-00 minimal, UX-03 never |
| `Support/RafuControlStyles.swift` | UX-00 only | consume the styles, never edit |
| `Views/ConductorRunsPanelView.swift` | UX-01 only | — |
| `Views/WorkspaceTerminalsPanelView.swift`, `Terminal/TerminalsPanelModel.swift` | UX-03 only | — |
| `Conductor/ConductorCLIIcons.swift`, `Support/FileIconProvider.swift` | UX-03 only | consume |
| `Settings/**` | UX-02 only | — |

## Worktrees

```bash
# Wave 1
git worktree add ../rafu-ux-route  -b ux/00-canvas-route-and-theme
git worktree add ../rafu-ux-agents -b ux/03-agent-identity
# Wave 2 (after UX-00 merges)
git worktree add ../rafu-ux-tabs     -b ux/01-ensemble-tabs
git worktree add ../rafu-ux-settings -b ux/02-settings-tab
```

Ground rules, gates, the isolation-based triage table, and the build-cache
deletion rule in `AGENTS.md` and
[`../conductor/README.md`](../conductor/README.md) apply unchanged. Local
builds are **Rafu Lightning**; never `pkill`/`pgrep` a bare `Rafu`.

## Wave 3 — the second dogfooding pass (2026-07-26)

Running the merged UX set surfaced six more issues. These were fanned out
directly as three goal-mode agents on ad-hoc worktrees rather than written up
as plan documents first, because each was a bounded presentation change with
no cross-cutting contract to land.

| # | Branch | Delivered |
|---|---|---|
| UI-01 | `ux2/01-theme-and-width` | Settings at full canvas width; `TabView` → `SettingsPaneStrip`; `View.rafuTheme(_:)` tints stock controls at the four scene roots |
| UI-02 | `ux2/02-ensemble-canvas` | New Ensemble as a full-width 3/12 + 9/12 workbench; icon grids for coordinator and allowed CLIs; single-pane live-Markdown goal; ensemble naming |
| UI-03 | `ux2/03-agent-grid` | Icon-only agent card grid in the terminals panel; Codex takes the OpenAI mark |

Three findings worth carrying forward:

- **`.tint` does not reach `TabView`'s macOS bar**, the same AppKit chrome
  that forced `RafuSegmentedPicker` to exist. Replacing the bar was the only
  option, not a preference.
- **The scan needed a different shape for stock controls.** Scanning for
  `Toggle(` is hopeless — dozens of legitimate sites, and correctness is not a
  property of the line the control sits on. Banning unsanctioned theme roots
  is the enforceable equivalent, because a root is the single place that
  decides those controls' colour.
- **Parallel ownership hid one fix again.** UI-01 found the `ColorPicker`
  accent seed but could not touch the file UI-03 owned, so it was closed in
  the integration pass. This is the same shape as the UX-01/UX-02 cross-clear
  gap: each branch internally correct, the union not. Budget an integration
  step for every parallel wave; do not merge and assume.

## Definition of done for the set

1. No modal sheet remains for New Ensemble, New Ensemble Run, or Settings.
2. No control renders in the system accent where a theme token exists.
3. Every agent-bearing surface shows the correct vendor mark, including the
   places a `Menu` previously prevented it.
4. The terminals panel lists agents inline with icons, an honest loading
   state, and keyboard shortcuts.
5. `EditorCanvasView` routes through one explicit enum, not a 38-branch chain.
