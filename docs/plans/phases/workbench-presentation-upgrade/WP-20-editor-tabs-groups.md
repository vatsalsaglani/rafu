# WP-20 — Attached editor tabs, split groups, and terminal tile identity

## Status and execution slot

- **Status:** Planned.
- **Wave:** 1; parallel.
- **Suggested branch:** `codex/presentation-editor-tabs`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact `<FOUNDATION_SHA>`.
- **Merge round:** after WP-10.

## Goal

Make every editor-owned tab feel attached to its content, frame recursive editor
groups with compact measured separation, and carry an existing terminal session
color around the actual live terminal tile. Preserve tab topology, drag/drop,
TextKit, SwiftTerm, focus, and process lifetime.

This lane does not edit Settings or Ensemble canvas tabs; WP-50 and WP-60 apply
the same foundation primitive to those owned canvases. It does not edit the
terminal manager; WP-30 consumes the same terminal-border resolver there.

## Required reading and skills

Read:

- `AGENTS.md`
- [`README.md`](README.md)
- [`WP-00-foundation.md`](WP-00-foundation.md)
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
- parent plan sections B, C, P1, P2, verification, and risks
- ADR 0022, ADR 0014, ADR 0004
- `docs/references/editor-tab-reorder-drop-zones.md`
- `docs/references/editor-gutter-ruler-tiling.md`
- `docs/references/terminal-signals-and-shell-catalog.md`
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with latest APIs, layout, view structure,
accessibility, focus, and macOS views. Use Build macOS Apps `swiftui-patterns`
and `appkit-interop` to review the existing TextKit/SwiftTerm boundaries. This
is presentation around those hosts, not authority to refactor them.

## Exclusive ownership

Source:

- `Sources/RafuApp/Views/EditorCanvasView.swift`

Tests:

- `Tests/RafuAppTests/EditorThemeColorApplicationTests.swift`
- `Tests/RafuAppTests/EditorLayoutTests.swift`
- `Tests/RafuAppTests/EditorDragAndDropTests.swift`
- `Tests/RafuAppTests/EditorTabSwitcherTests.swift`
- new `Tests/RafuAppTests/EditorTabAndGroupPresentationTests.swift`

Documentation:

- this plan's implementation record
- one uniquely named reference note only if the work proves a reusable
  splitter/overlay/host nuance not already documented

Do not edit `EditorLayout.swift`, `WorkspaceSession.swift`,
`EditorTerminalTabContent.swift`, `TerminalSessionColor.swift`,
`WorkspaceTerminalsPanelView.swift`, any Settings/Ensemble file, WP-00 support
files, `Package.*`, shared indexes, or another lane's files.

## Implementation

### E1. Adopt attached tabs in every editor-owned route

Replace the independent underline-only construction in
`EditorGroupTabBar`/tab items with WP-00's attached-tab primitive for:

- document tabs;
- terminal tabs;
- Git diff tabs;
- standalone blame/diff tabs.

Keep:

- current named drop coordinate space and captured tab frames;
- reorder and split drop delegates;
- insertion indicator;
- overflow menu;
- close-on-hover;
- dirty/exited states;
- drag provider and context menu;
- Markdown mode controls outside tab ownership.

The selected tab uses `tabActiveBackground`, top and side hairlines, no bottom
edge, and a bottom seam mask owned as a non-layout overlay by the full-width tab
bar. Convert `StitchedUnderline` to a secondary top `StitchedAccentEdge`; it is
not the only selected signal. Long labels keep their full `help` and accessible
name. The close action uses the foundation's scaled 22–28 pt hit region.

Do not make tab selection, cursor changes, or focus animated.

### E2. Frame recursive groups without changing topology

In `EditorLayoutTreeView` and `EditorGroupView`:

- retain `HSplitView`/`VSplitView` as the resize engine;
- put `appBackground` behind each split;
- measure a total 4 pt visual group-to-group band including the native divider;
- do not add 2 pt to both leaves and then add the divider again;
- use WP-00's `EditorGroupSurface` around tab cap plus content;
- use overlay cutouts and borders, never clipping/masking the composite;
- use neutral rest and stronger focused-document structure from the theme.

No edit to `EditorLayout`, no new layout preset, no rearrangement behavior, and
no terminal respawn is permitted.

### E3. Put terminal identity around the live tile

When the selected group tab is a terminal:

- resolve the existing `controller.sessionColor` through the loaded palette;
- invoke the shared `.editorGroup(isFocused:)` terminal-border context;
- keep a neutral structural boundary at rest and under a
  background-matching custom identity color;
- draw optional identity as a complete inset perimeter;
- strengthen focus to 2 pt while keeping identity visible;
- retain provider icon/name/status and selected-tab geometry;
- keep the tab's 2 pt leading marker as a redundant cue resolved from the same
  identity value.

`EditorTerminalTabContent` remains body-only and is WP-30-owned. Consume it
unchanged: it owns no second perimeter, inset, mask, or clip. Preserve its
SwiftTerm host, generation identity, responder path, exit overlay, theme
application, process lifetime, hide/close split, and teardown.

Consume `TerminalSessionColor` unchanged. Do not add automatic, random,
provider, or status colors. If either terminal-owned file appears to require a
change, record the exact dependency for WP-30 rather than editing it.

### E4. Regression and contract tests

Pin:

- shared attached-tab use in every editor tab item;
- selected fill/top-side/no-bottom geometry and seam overlay;
- non-hit-testing/accessibility-hidden seam/corner overlays;
- no mask/clip on TextKit or SwiftTerm host paths;
- one group-owned terminal perimeter;
- one identity resolution for tab marker and full tile;
- background-matching identity retains neutral structure and focus;
- layout/topology values and drag state are unchanged.

Existing behavior assertions remain behavior assertions; do not rewrite them
into weaker source scans merely to fit the new chrome.

## Acceptance and manual evidence

Focused checks:

```bash
./script/test.sh --filter \
  'EditorThemeColorApplication|EditorLayout|EditorDrag|EditorTabSwitcher|TerminalEditorTab|EditorTabAndGroupPresentation'
```

With the GUI lease, verify:

- single, 1×2, 2×1, 2×2, and 1+2 layouts;
- one tab, eight/overflow, dirty file, exited terminal, long names, hover,
  pressed, selected, keyboard focus, and inactive window;
- 1×/2×: complete separation is 4 pt including divider, attached tab has no
  bottom seam, borders remain one physical-pixel accurate;
- at a 1,200 pt window with Files visible and utility closed, 2×2 leaves remain
  at least 280 × 180 pt and each terminal reports at least 32 × 8 cells;
- uncolored, preset-colored, and custom-color-equal-to-editor-background
  terminals;
- type, scroll, select, drag, split, hide, reveal, and close a live session with
  no respawn, input loss, or altered lifetime.
- keyboard-only tab selection, overflow, close, reorder, and split routes;
- VoiceOver announces full tab names, selected/dirty/exited state, and the
  close action without relying on hue;
- default and largest supported accessibility text sizes keep essential tab
  text/actions reachable through truncation help or overflow without clipping.

Capture Indigo, Khadi, the converged fixture, and Increase Contrast; include at
least one 1× and one 2× measurement.

## Verification and handoff

Complete all files before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Run staged Rafu Lightning only with the GUI lease; otherwise hand off the exact
deferred matrix. Commit only owned paths, do not push, and remove `.build` after
the green commit.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-20's attached editor tabs, compact split-group framing, and
theme-owned live terminal tile identity without changing editor topology or
terminal lifetime; verify and commit an integration-ready result."

You are on branch codex/presentation-editor-tabs in its dedicated worktree. Use
gpt-5.6-sol with high reasoning.

Read AGENTS.md; the workbench-presentation-upgrade execution README; WP-00;
WP-20; pre-initial-push-workbench.md; parent plan sections
B/C/P1/P2/verification/risks; ADR 0022, ADR 0014, ADR 0004;
editor-tab-reorder-drop-zones.md;
editor-gutter-ruler-tiling.md; terminal-signals-and-shell-catalog.md; and
skill-routing.md. Use swiftui-expert-skill plus macOS swiftui-patterns and
appkit-interop for boundary review.

Run `git status --short --branch`. Stop unless the branch is
codex/presentation-editor-tabs, the tree is clean, the initial
`git rev-parse HEAD` equals the coordinator-supplied exact `<FOUNDATION_SHA>`,
and the WP-00 foundation is present. Touch only the source, test, and plan paths
owned by WP-20. Do not edit WorkspaceSession, EditorLayout, the terminal
manager, Settings, Ensemble, shared styles, Package.swift, or shared indexes.

Adopt the shared attached tab for every editor-owned tab; preserve frame
capture, reorder, split, overflow, dirty/exited, hover-close, and Markdown
controls. Frame groups around tab plus content with the measured divider-aware
4 pt band. Carry the existing session identity around the complete terminal
group through the shared resolver. Never mask or clip TextKit/SwiftTerm and
never add a second terminal border or a layout preset.

Add/retain the exact tests and manual checks in WP-20. Use the single GUI lease
for Rafu Lightning or list the exact deferred states.

Complete all changes before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change after the final test. When holding the single GUI lease, run
`./script/build_and_run.sh --verify` and complete the manual matrix; otherwise
report the exact deferral. Stage only owned paths and make one local commit. Do
not push, merge, open a PR, or publish. After green gates and the successful
commit, remove only this dedicated worktree's `.build`; never remove the
primary checkout's cache. Report delivered behavior, commit SHA, paths,
focused/full gate results, 1x/2x and theme/accessibility evidence, terminal
interaction results, ADR/reference updates, deferred checks, risks, any
intended reference-index row, and the next dependency (WP-20 merges after
WP-10). Complete the Goal only after the commit and handoff.
```
