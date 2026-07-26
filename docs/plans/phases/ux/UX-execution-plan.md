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

The menu-icon finding is worth internalising: the user's preference for fewer
popups and the platform's rendering limitation point at the same answer.
Inline SwiftUI surfaces render real views; menus do not.

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
| UX-00 | [`UX-00-canvas-route-and-theme.md`](UX-00-canvas-route-and-theme.md) | `ux/00-canvas-route-and-theme` | 1 (serial) |
| UX-03 | [`UX-03-agent-identity-and-terminals.md`](UX-03-agent-identity-and-terminals.md) | `ux/03-agent-identity` | **Merged 2026-07-26** (`9d1492f`) |
| UX-01 | [`UX-01-ensemble-as-editor-tabs.md`](UX-01-ensemble-as-editor-tabs.md) | `ux/01-ensemble-tabs` | 2 |
| UX-02 | [`UX-02-settings-as-editor-tab.md`](UX-02-settings-as-editor-tab.md) | `ux/02-settings-tab` | 2 |

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

## Definition of done for the set

1. No modal sheet remains for New Ensemble, New Ensemble Run, or Settings.
2. No control renders in the system accent where a theme token exists.
3. Every agent-bearing surface shows the correct vendor mark, including the
   places a `Menu` previously prevented it.
4. The terminals panel lists agents inline with icons, an honest loading
   state, and keyboard shortcuts.
5. `EditorCanvasView` routes through one explicit enum, not a 38-branch chain.
