# WP-10 — Recessed window shell and workbench deck

## Status and execution slot

- **Status:** Planned.
- **Wave:** 1; runs in parallel with WP-20 through WP-60.
- **Suggested branch:** `codex/presentation-shell-deck`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact `<FOUNDATION_SHA>` containing merged WP-00.
- **Merge round:** first, before WP-20.

## Goal

Make Files and the window rails read as the edge-attached rear plane while the
editor plus optional utility area becomes one narrowly inset working deck.
Preserve both native splitters, window-scoped state, status-bar composition, and
flat titlebar behavior.

This lane owns only the shell. WP-40 owns utility-surface fill and rail-button
adoption; WP-20 owns editor groups. Do not pull those edits into this branch.

## Required reading and skills

Read:

- `AGENTS.md`
- [`README.md`](README.md)
- [`WP-00-foundation.md`](WP-00-foundation.md)
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
- parent plan sections A, P1, verification, and risks
- ADR 0022, ADR 0012, and ADR 0002
- `docs/references/ui-design-language.md`
- `docs/references/build-and-run.md`
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with latest APIs, layout, accessibility, macOS scenes,
window styling, and macOS views. Use Build macOS Apps `swiftui-patterns` and
`window-management`. Use `appkit-interop` only if current split/window behavior
cannot be understood without crossing the existing bridge; do not replace it.

## Exclusive ownership

Source:

- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Sources/RafuApp/Views/WorkspaceSidebarView.swift`
- `Sources/RafuApp/Views/FlatWindowChrome.swift`, verification first and edit
  only if the duplicate top band reproduces

Tests:

- `Tests/RafuAppTests/FlatWindowChromeTests.swift`
- new `Tests/RafuAppTests/WorkbenchDeckPresentationTests.swift`

Documentation:

- this plan's implementation record
- one uniquely named reference note only for a newly verified reusable
  window/split nuance

Do not edit `WorkspaceNavigatorView.swift`, `WorkspaceStatusBar.swift`,
`EditorCanvasView.swift`, a WP-00 support file, any model, `Package.*`, shared
indexes, or another plan's source/test paths.

## Implementation

### S1. Establish the one-deck composition

In `WorkspaceWindowView.windowContent`:

1. Keep the existing outer AppKit-backed `HSplitView` as the direct Files/work
   owner.
2. Keep the existing inner `HSplitView` as the direct editor/utility owner.
3. Wrap only that inner editor/utility branch in:

   ```text
   appBackground
   └─ 4 pt external padding
      └─ WorkbenchDeckSurface
         └─ existing inner HSplitView
   ```

4. The 4 pt padding is outside the deck. Add no padding inside the editor or
   utility content.
5. Files, both activity rails, and the 24 pt status bar remain outside the
   deck and edge-attached.
6. Preserve current min/ideal/max widths, layout priorities, visibility
   bindings, restoration, and drag targets.

Use WP-00's `WorkbenchDeckSurface`. Do not duplicate its corner overlay,
border, theme resolution, or metrics.

### S2. Preserve the Files leaf

`WorkspaceSidebarView` remains an unrounded source-list/file surface on
`sidebarBackground`:

- retain list density, stable tree identity, selection behavior, file badges,
  hover/context actions, header actions, and divider;
- do not wrap rows or the whole Files leaf in cards;
- make only the minimal composition adjustment needed for the new deck edge;
- do not adopt rail-button styling here because the buttons live in
  `WorkspaceNavigatorView.swift`, owned by WP-40.

### S3. Resolve the duplicate-top-band evidence

Reproduce the supplied capture against current code before editing
`FlatWindowChrome.swift`:

- key and inactive window;
- normal and full-screen;
- utility open and closed;
- restored second window.

If no duplicate band exists, leave `FlatWindowChrome.swift` unchanged and
record that the capture was stale. If it reproduces, constrain the fix to
existing state application in `FlatWindowChrome`/`WorkspaceWindowView`.
Retain:

- no `NSToolbar`;
- native traffic lights;
- existing full-screen reapplication;
- existing drag regions and safe areas;
- independent window ownership.

Do not invent a new titlebar or safe-area compensation layer.

### S4. Tests

Add source/composition contract coverage that pins:

- exactly one deck around editor plus optional utility;
- Files, rails, and status outside the deck;
- external 4 pt inset with no content padding;
- no shadow, material, blur, mask, or clip around either native split;
- unchanged sidebar/utility width bounds and priorities;
- existing `FlatWindowChrome` key/full-screen behavior.

Do not add snapshot-test infrastructure.

## Acceptance and manual evidence

Automated focused checks include:

```bash
./script/test.sh --filter 'FlatWindowChrome|WorkbenchDeckPresentation'
```

Before handoff, verify or explicitly defer to the merge-round GUI lease:

- Indigo, Khadi, the converged fixture, and Increase Contrast with utility
  closed/open;
- 1× and 2×: the inset is 4 pt (4/8 physical pixels) within one physical pixel,
  border 1 pt, corner 6 pt;
- Files stays flush behind the deck with no card or shadow;
- both splitters drag through min/ideal/max bounds with their full native hit
  targets;
- key/inactive, normal/full-screen/restored, and two windows;
- no duplicate top band;
- the status bar remains a flush 24 pt edge.

Record window content size in points and `backingScaleFactor` for measured
captures.

## Verification and handoff

Finish tests and documentation, then:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Run `./script/build_and_run.sh --verify` only while holding the coordinator's
single GUI lease. Otherwise list the exact deferred shell states for the merge
round. Nothing modifies a file after the final parallel test.

Commit only owned paths, do not push, and remove this worktree's `.build` after
the green commit. The handoff must state whether `FlatWindowChrome.swift`
changed and why.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-10's recessed Rafu workbench shell from the shared foundation,
preserve native split/window behavior, verify it, commit it locally, and provide
an integration-ready handoff."

You are in the dedicated worktree on branch
codex/presentation-shell-deck. Use gpt-5.6-sol with high reasoning.

Read completely: AGENTS.md;
docs/plans/phases/workbench-presentation-upgrade/README.md;
WP-00-foundation.md; WP-10-shell-deck.md;
docs/plans/phases/pre-initial-push-workbench.md; the parent
workbench-presentation-upgrade.md sections named by WP-10; ADR 0022, ADR 0012,
ADR 0002; ui-design-language.md; build-and-run.md; and skill-routing.md. Use
swiftui-expert-skill, Build macOS Apps swiftui-patterns, and window-management.

Run `git status --short --branch`. Stop unless the branch is
codex/presentation-shell-deck, the tree is clean, the initial
`git rev-parse HEAD` equals the coordinator-supplied exact `<FOUNDATION_SHA>`,
and WP-00's RafuWorkbenchStyles.swift exists. Implement only WP-10-owned paths.
Do not edit WorkspaceNavigatorView, EditorCanvasView, shared styles, models,
Package.swift, or shared indexes. Preserve every splitter bound, drag target,
restoration path, status-bar edge, and per-window state. Reproduce the
duplicate top band before changing FlatWindowChrome; leave it byte-identical if
the issue is stale.

Add the focused tests and complete the manual states in the plan when you hold
the single Rafu Lightning GUI lease. If the lease is unavailable, defer those
named states to the coordinator and say so precisely.

Complete all edits before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may modify a file after the final test. Stage only owned paths and make
one local commit. When holding the single GUI lease, run
`./script/build_and_run.sh --verify` after the test and complete the manual
matrix; otherwise report the exact deferral. Do not push, merge, open a PR, or
publish. After green gates and the successful commit, remove only this
dedicated worktree's `.build`; never remove the primary checkout's cache.
Report delivered behavior, commit SHA, changed paths, exact gates,
measured/manual evidence, whether the top-band capture reproduced, ADR/
reference updates, deferred checks, risks, any intended reference-index row,
and the next dependency (WP-10 merge before WP-20). Mark the Goal complete only
after the commit and handoff are complete.
```
