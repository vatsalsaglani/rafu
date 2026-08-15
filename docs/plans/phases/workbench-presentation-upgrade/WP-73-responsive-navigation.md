# WP-73 — Responsive utility and Settings navigation

## Status and execution slot

- **Status:** Planned on 2026-07-30.
- **Wave:** Follow-up Wave 1; parallel with WP-71, WP-72, and WP-74.
- **Suggested branch:** `codex/presentation-responsive-navigation`.
- **Recommended model:** `gpt-5.6-terra` with xhigh reasoning.
- **Required base:** exact coordinator-supplied `<FOLLOWUP_BASE_SHA>`.
- **Issues closed:** WBP-002 and WBP-003.
- **Dependency:** all original presentation work through WP-60 is already in
  the base. This plan must finish before WP-90.

## Goal

Make equivalent utility mode selectors share one full-width rhythm, and make
compact Settings navigation feel like an intentional in-flow page hierarchy
rather than a floating menu over a compressed wide layout.

The wide Settings layout, pane lifetime, task ownership, JSON-theme palette,
native Settings fallback, and every Source Control behavior remain unchanged.

## Required reading and skills

Read:

- `AGENTS.md`
- this plan and
  `docs/issues/workbench-presentation-follow-ups.md`
- `WP-40-utility-panels.md` and `WP-50-settings.md`
- ADR 0002, 0012, 0014, and 0022
- `docs/references/settings-surface.md`
- `docs/references/ui-design-language.md`
- `docs/references/skill-routing.md`
- every owned source/test file

Use the project-local `swiftui-expert-skill`, reading its latest-API,
view-structure, layout, accessibility, and macOS references first. Use Build
macOS Apps `swiftui-patterns` for adaptive Settings/navigation composition and
`build-run-debug` for staged verification. No AppKit or concurrency work is
expected.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Views/GitInspectorView.swift`
- `Sources/RafuApp/Settings/RafuSettingsView.swift`
- `Sources/RafuApp/Settings/SettingsPaneNavigation.swift`

### Test paths

- `Tests/RafuAppTests/UtilityPanelPresentationTests.swift`
- `Tests/RafuAppTests/SettingsPresentationTests.swift`
- new `Tests/RafuAppTests/ResponsiveNavigationPresentationTests.swift`

### Lane documentation

- this plan's implementation record
- a uniquely named reference note only if a reusable SwiftUI adaptive-layout
  behavior is proved

### Frozen and read-only

Do not edit:

- `Sources/RafuApp/Support/RafuControlStyles.swift`
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`
- `Sources/RafuApp/Support/RafuMetrics.swift`
- `Sources/RafuApp/Support/RafuTheme.swift`
- `Sources/RafuApp/Settings/SettingsCanvas.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- individual Settings pane/section files
- Ensemble, terminal, editor, window-chrome, theme JSON, `Package.*`, shared
  indexes, or another follow-up plan path

Consume `RafuSegmentedPicker` and the existing Settings page/card primitives as
implemented. Do not add a shared primitive or theme token in this lane.

## Implementation contract

### R1. Stretch Source Control's top-level modes

`GitInspectorView` currently invokes `RafuSegmentedPicker` without its existing
`fillsWidth` behavior. Ensemble already demonstrates the desired semantic.

Change the Source Control selector to:

- pass `fillsWidth: true`;
- distribute `Changes`, `Worktrees`, and `History` as equal segments across
  the available panel content width;
- expose one useful accessibility label and the selected section as its value;
- preserve `session.gitInspectorSection` as the sole selection state;
- preserve every section, clean/no-repository/change state, Git refresh,
  worktree/history behavior, keyboard operation, and test identity.

Do not edit `RafuSegmentedPicker`, copy Ensemble's implementation, or hard-code
widths/colors. Review equivalent top-level selectors in the utility panels;
record an intentional exception rather than broadening source ownership.

### R2. Preserve the regular Settings layout

`SettingsPresentationLayout` currently switches at 812 points. Keep:

- the exact regular breakpoint unless measured evidence proves a one-point
  boundary defect;
- the left category rail and page column at and above the breakpoint;
- the one retained `paneContent` host;
- `visitedPanes`, page-specific `.task` lifetime, focus, scroll, and state;
- native Settings-window fallback behavior;
- existing page headings, cards, and content widths.

Add a regression for 812 points before changing compact composition so the wide
layout cannot silently drift.

### R3. Make compact Settings navigation part of the page flow

Immediately below the breakpoint, remove the detached centered selector from
above/outside the page hierarchy. Place compact navigation inside the existing
page column, immediately before the page header.

The compact control is one full-width disclosure/navigation surface:

- collapsed state is a row aligned to the page/card edges, showing the current
  category icon, title, and disclosure state;
- expanded state presents all seven categories as real, full-width Buttons in
  a vertical list below that row;
- expansion participates in layout and pushes the page down; it does not float
  over, obscure, or detach from the heading/card;
- selecting a category updates the existing selection binding, collapses the
  list, and leaves focus/state ownership coherent;
- Escape collapses when expanded; keyboard/VoiceOver users can reach every
  category in predictable order;
- the current category remains conveyed by text/selection semantics, not color
  alone;
- long localized names and largest supported text wrap or expand vertically
  without horizontal scrolling or clipped actions.

Use existing palette roles, hairlines, spacings, radii, and control semantics.
Do not recreate an `NSMenu`, add a popover, or turn the category list into an
overlay. The compact control should feel attached to the current Settings page,
not like a global toolbar control.

### R4. Keep adaptive state stable during resize

Repeatedly resizing through 811/812 points must not:

- recreate the pane content or repeat pane tasks;
- reset edits, scroll, or focus;
- leave the compact disclosure open in an impossible regular state;
- cause category order/selection to differ;
- produce a one-frame duplicate rail and compact control.

Keep expansion state private to `SettingsPaneNavigation` or the narrow
composition that owns it. Do not persist it.

## Tests

Add focused coverage for:

- Source Control passes full-width/equal-segment intent to the existing picker;
- all three Source Control selections and accessibility value;
- Source Control min/ideal/max utility widths and long labels/larger text;
- regular layout selected at 812 and compact immediately below it;
- compact navigation is inside the page column before the page header;
- collapsed/expanded category ordering and selection;
- expansion is in flow, not a menu/popover/overlay;
- selecting and Escape collapse correctly;
- every pane remains one retained host across selection and breakpoint
  transitions;
- pane tasks and `visitedPanes` do not restart/reset on resize;
- long category names and largest text have a vertical escape path;
- JSON theme roles, focus, disabled, selected, hover, and Increase Contrast
  remain.

Run read-only suites for:

- Settings pane state/task retention
- themed control styles
- all Git Inspector behavior
- Ensemble Runs selector presentation as the reference comparator

## Manual acceptance

Using staged Rafu Lightning:

1. Open Source Control at minimum, ideal, and maximum utility widths. Compare
   its three equal-width segments directly with Ensemble.
2. Verify no repository, clean, changed files, Worktrees, and History states.
3. Open every Settings pane at a wide width.
4. Resize slowly between 792 and 832 points, including exact 811 and 812
   evidence.
5. At the smallest supported width, open the category navigation, traverse all
   seven items, select each, and confirm the page is pushed down rather than
   obscured.
6. Make edits in stateful panes, scroll, resize across the breakpoint, and
   confirm values/task/state/focus survive.
7. Verify native Settings-window fallback.
8. Cover all bundled themes and one imported JSON theme, Increase Contrast,
   largest text, long localization stress, Full Keyboard Access, VoiceOver,
   key/inactive windows, and available 1×/2× displays.

## Verification and handoff

Run focused utility/Settings tests first. Final sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing may modify a tracked file after the parallel suite. Run
`./script/build_and_run.sh --verify` under the shared GUI lease, or list the
exact deferred visual states.

Run `git diff --check`, stage only owned paths, and create one local commit. Do
not push, merge, open a PR, publish, or release. After green gates and commit,
remove only this dedicated worktree's `.build`.

The handoff reports exact breakpoint/composition, state-retention proof, commit
SHA, changed paths, focused/full totals, staged/manual evidence, themes and
accessibility states, warnings, deferred hardware checks, any reference note,
and WP-90 dependency.

## Implementation record

Implemented on the local `codex/presentation-responsive-navigation` branch,
created from local `main` at `07c1fc5642ef331cf3c29530d5d6f36ad4ee9b08`.

- Source Control now uses the shared `RafuSegmentedPicker` with `fillsWidth:
  true`. Changes, Worktrees, and History use equal available widths. The
  picker has a Source Control section accessibility label and the selected
  section as its accessibility value.
- At widths of 812 points and greater, Settings keeps its regular rail and
  page layout. Below 812 points, category navigation is inside the page
  column, immediately before the page header. The retained `paneContent` host
  remains outside both layout variants.
- The compact category control is an in-flow full-width disclosure. Its
  collapsed row shows the current category. Its expanded list contains the
  seven existing full-width category buttons in the original order. Selection,
  Escape, and a return to the regular layout collapse the disclosure. Category
  names wrap vertically at large text sizes; the control does not use a Menu,
  overlay, or horizontal scroll.
- Focused presentation, Settings retention, themed-control, Git, and
  Ensemble comparator checks passed before the final lane sequence. The
  focused navigation run passed 19 tests in 3 suites. The Settings retention
  run passed 196 tests in 7 suites. The themed-control run passed 2 tests in 1
  suite. The Git and utility-panel run passed 84 tests in 9 suites.
- The first full parallel run exposed a pre-existing Ensemble Runs source
  contract failure in the base revision. With explicit user authorization, the
  minimal scope exception moves internal helper calls outside localized string
  interpolation. It preserves the rendered text and restores the existing
  naming contract without changing the comparator test.
- No reusable platform, SDK, toolchain, lifecycle, concurrency, security, or
  performance nuance was found. No reference note or WP-90 reference-index row
  is required.

The shared GUI lease was not available because another Rafu Lightning process
was active. Final staged-app checks therefore remain deferred for the exact
visual matrix in this work package: Source Control at minimum, ideal, and
maximum widths in every Git state; every Settings pane during continuous
792–832 point resizing and stateful edits across 811/812; native Settings
fallback; themes, contrast, large and localized text; Full Keyboard Access;
VoiceOver; inactive windows; and available 1x and 2x displays.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-73 for Rafu: make Source Control's Changes/Worktrees/History
navigation fill the utility-panel width and redesign compact Settings
navigation as a coherent full-width in-flow page hierarchy, while preserving
Git behavior, Settings pane lifetime, routing, native fallback, and JSON-theme
authority; verify and commit the result locally."

You are in a dedicated worktree on branch
codex/presentation-responsive-navigation. Use gpt-5.6-terra with xhigh
reasoning.

Read AGENTS.md, WP-73-responsive-navigation.md, the follow-up issue ledger,
WP-40, WP-50, ADRs 0002/0012/0014/0022, settings-surface.md,
ui-design-language.md, skill-routing.md, and every owned source/test file. Use
the project-local swiftui-expert-skill with its latest-API, macOS, layout,
accessibility, and view-structure references; use Build macOS Apps
swiftui-patterns and build-run-debug.

Run `git status --short --branch`. Stop unless the branch is exactly
codex/presentation-responsive-navigation, the tree is clean, and the initial
`git rev-parse HEAD` equals the coordinator-supplied exact
`<FOLLOWUP_BASE_SHA>`. Work only in GitInspectorView.swift,
RafuSettingsView.swift, SettingsPaneNavigation.swift,
UtilityPanelPresentationTests.swift, SettingsPresentationTests.swift, the new
ResponsiveNavigationPresentationTests.swift, and this plan record. Treat
RafuControlStyles/workbench styles/metrics/theme, SettingsCanvas,
WorkspaceSession, individual pane files, editor/window/terminal/Ensemble files,
theme JSON, Package.*, shared indexes, and every other lane as read-only.
If implementation proves a reusable platform/toolchain nuance, you may add one
uniquely named note under docs/references as required by AGENTS.md; do not edit
the reference index, and report the intended WP-90 index row. Otherwise add no
documentation-only churn.

In GitInspectorView, consume the existing RafuSegmentedPicker with
fillsWidth: true so Changes, Worktrees, and History divide the available width
equally. Add an accessibility label/value and preserve the existing selection
and every Git state/behavior. Do not edit or copy the shared picker.

Preserve the regular Settings rail/page layout at 812 points and the one
retained paneContent host. In compact mode, move category navigation inside
the page column immediately before the page header. Replace the detached
floating Menu with a full-width in-flow disclosure: current category row when
collapsed; seven real full-width vertical Buttons when expanded; expansion
pushes content down; selection or Escape collapses it. Preserve visited panes,
task/state/scroll/focus lifetime, category order, page cards/headings, and
native Settings fallback. Use only existing theme roles/metrics. Long
localized names and largest text need a vertical escape path, never horizontal
scroll or an overlay.

Add focused regressions for equal utility segments; accessibility; 811/812
selection; compact hierarchy/order/selection/Escape; retained pane host/tasks
across resizing; large text/theme/contrast. Run the read-only Git, Settings
retention, themed-control, and Ensemble comparator suites named in the plan.
Manually verify Source Control at min/ideal/max widths, every Git state, every
Settings pane, continuous 792-832 resize, stateful edits across the breakpoint,
native fallback, themes, contrast, larger/localized text, Full Keyboard Access,
VoiceOver, inactive windows, and available 1x/2x displays. Use only Rafu
Lightning and the shared GUI lease.

Final order:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change after the parallel suite. Then run the staged-app
verification if the lease is available and `git diff --check`.

Stage only WP-73-owned paths and create one intentional local commit. Do not
push, merge, open a PR, release, or publish. After green gates and the commit,
remove only this worktree's .build. Report delivered behavior, exact
breakpoint/layout, commit SHA, changed paths, focused/full test results,
staged/manual/accessibility evidence, warning count, deferred hardware checks,
reusable nuances, remaining risks, and that WP-90 is next. Complete the Goal
only after the green commit and handoff.
```
