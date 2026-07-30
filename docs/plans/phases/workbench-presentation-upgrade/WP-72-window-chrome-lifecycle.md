# WP-72 — Flat window chrome across tab and split topology changes

## Status and execution slot

- **Status:** Planned on 2026-07-30.
- **Wave:** Follow-up Wave 1; parallel with WP-71, WP-73, and WP-74.
- **Suggested branch:** `codex/presentation-window-chrome-lifecycle`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact coordinator-supplied `<FOLLOWUP_BASE_SHA>`.
- **Issues closed:** WBP-004 and WBP-007.
- **Dependency:** all original presentation work through WP-60 is already in
  the base. This plan must finish before WP-90.

## Goal

Make ADR 0012's flat-window chrome an invariant across SwiftUI/AppKit hosting
topology changes, specifically drag-to-split and every tab-close path, without
changing editor layout, tab lifecycle, terminal teardown, traffic lights,
full-screen behavior, or accessibility title semantics.

WBP-004 and WBP-007 deliberately share one lane. Both reproduce when an editor
group is mounted, replaced, collapsed, or removed, and both require the same
central AppKit lifecycle correction. Separate branches would edit the same two
files and risk competing timing patches.

## Required reading and skills

Read:

- `AGENTS.md`
- this plan and
  `docs/issues/workbench-presentation-follow-ups.md`
- `WP-10-shell-deck.md` and `WP-20-editor-tabs-groups.md`
- ADR 0012 and ADR 0022
- `docs/references/flat-window-chrome-titlebar-merge.md`
- `docs/references/editor-tab-reorder-drop-zones.md`
- `docs/references/build-and-run.md`
- `docs/references/skill-routing.md`
- the current owned source and tests

Use Build macOS Apps `window-management`, `appkit-interop`, and
`build-run-debug`. Use the project-local `swiftui-expert-skill` with its
macOS/AppKit lifecycle references and Build macOS Apps `swiftui-patterns` for
the bridge invocation. No concurrency skill is expected; do not introduce
unstructured asynchronous ownership to solve a window lifecycle problem.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Views/FlatWindowChrome.swift`
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`

### Test paths

- `Tests/RafuAppTests/FlatWindowChromeTests.swift`
- new `Tests/RafuAppTests/WindowChromeTopologyLifecycleTests.swift`

### Lane documentation

- this plan's implementation record
- a uniquely named reference note if the investigation proves a reusable
  AppKit hosting/topology nuance not already covered by
  `flat-window-chrome-titlebar-merge.md`

### Frozen and read-only

Do not edit:

- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Editor/EditorLayout.swift`
- shared workbench styles, metrics, themes, or JSON theme files
- terminal manager, utility, Settings, Ensemble, `Package.*`, shared indexes,
  or another follow-up plan path

Do not add callbacks to every close, drag, or split mutator. Window chrome is a
window-level invariant and must remain owned at the window bridge.

## Implementation contract

### C1. Reproduce and classify the AppKit reset

Before editing, capture the window state immediately before and after:

- completing a tab drag into a horizontal and vertical split;
- cancelling a split drag;
- closing a selected/background file tab;
- closing a live/exited terminal tab;
- collapsing the last group after its final tab closes.

Inspect:

- `styleMask` and `.fullSizeContentView`;
- `titleVisibility`;
- `titlebarAppearsTransparent`;
- `titlebarSeparatorStyle`;
- `isMovable`;
- content-view base, additional, and effective top safe-area inset;
- titlebar/backdrop class names, hidden state, and alpha;
- when those values reset relative to the SwiftUI topology transaction.

Establish whether AppKit restores stock values, replaces the content/frame
view, or both. Add a failing headless regression around the proved seam before
the fix.

### C2. Give `FlatWindowChrome` an explicit topology reapply input

Add one value-semantic reapply token/generation to `FlatWindowChrome`. The
representable's update path passes it to the coordinator. A changed token means
the SwiftUI workbench topology or selected canvas changed and AppKit may have
reasserted stock titlebar/safe-area state.

In `WorkspaceWindowView.swift`, derive that token from already observable,
bounded UI identity such as:

- editor layout topology/group identity;
- the tab identities whose insertion/removal mounts or removes hosting
  content;
- the selected canvas/window title identity when it can cause AppKit to update
  its title machinery.

The token is not persisted and must not copy document text or terminal output.
Do not edit `WorkspaceSession` or `EditorLayout` to manufacture a revision.

The same bridge invocation must cover file, terminal, Settings, Ensemble, and
other editor-hosted canvases. Do not add feature-specific window calls.

### C3. Reapply centrally, idempotently, and in bounded passes

Refactor the coordinator so notification-driven and topology-driven paths call
one named, testable scheduling method:

- apply immediately;
- coalesce duplicate requests for the same attached window/token;
- perform only the minimum bounded post-transaction passes proved necessary to
  catch a replaced frame/content view;
- cancel pending work on detach or window replacement;
- never poll, recurse indefinitely, use a repeating timer, or retain a dead
  window/view;
- keep all window mutation on the main actor.

Reuse the already verified full-screen/key/main notification machinery. Avoid
stacking a second unrelated delayed-pass system.

After every pass, the invariant remains:

- `.fullSizeContentView` present;
- title hidden;
- titlebar transparent;
- no titlebar separator;
- background fallback matches the themed sidebar surface;
- top safe area cancelled at the content-view source;
- private titlebar backdrop/decoration views scrubbed;
- `isMovable == false`, with movement available only through explicit drag
  handles;
- traffic-light visibility matches the current full-screen/hover state.

Preserve `.navigationTitle(session.windowTitle)`. The logical window title
still matters for accessibility, Window menu behavior, and restoration even
though its visual title is hidden.

### C4. Keep the fix topology-neutral

The correction must not:

- alter split fractions, drop zones, group collapse, selected-tab fallback, or
  restoration;
- bypass dirty-file confirmation;
- alter terminal close/termination behavior;
- remove standard window buttons;
- add a fake title bar or an opaque top overlay;
- paint over the symptom instead of restoring the AppKit contract;
- flash the stock band for one frame before hiding it.

If tests show a frame-view replacement invalidates the safe-area cancellation,
recalculate against the current content view in the shared apply path rather
than caching the old view.

## Tests

Headless `NSWindow` coverage must deliberately restore stock chrome values,
fire a topology reapply, and assert:

- title hidden and transparent;
- `.fullSizeContentView`;
- separator `.none`;
- zero effective top safe area;
- `isMovable == false`;
- themed fallback color;
- backdrop views scrubbed when constructible in the seam;
- traffic lights preserved and correctly hidden/revealed;
- duplicate token updates coalesce;
- a changed token re-applies;
- detach/window replacement cancels stale scheduled work;
- notification and topology routes share the invariant;
- full-screen/key/main behavior remains.

Add source/composition coverage proving `WorkspaceWindowView` passes one
bounded topology token to one chrome bridge. Do not replace the headless AppKit
test with a source scan.

Read-only regression suites include:

- `WorkbenchDeckPresentationTests`
- editor layout and drag/drop tests
- file-close/dirty-confirmation tests
- terminal editor-tab and teardown tests
- workspace restoration tests

## Manual acceptance

Use staged Rafu Lightning and capture before/after evidence for:

1. Context-menu and drag-created horizontal/vertical splits.
2. Cancelled split, split resizing, tab movement, and group collapse.
3. Closing selected, background, and final file tabs.
4. Closing live and exited terminal tabs through the tab close affordance,
   Command-W, and Terminal Manager.
5. Settings, Ensemble, diff, and other canvas routes that share the window.
6. Window-title changes caused by workspace/document selection.
7. Key/inactive transitions, full-screen entry/exit, restoration, and a second
   independent workspace window.
8. 1× and 2× displays, all bundled themes, an imported JSON theme, Increase
   Contrast, and Reduce Transparency.

Record whether any single-frame band flash occurs, not merely the settled
state. Preserve traffic-light hover behavior and explicit window dragging.

## Verification and handoff

Run focused chrome/topology tests first. Final sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing may modify a tracked file after the parallel suite. Run
`./script/build_and_run.sh --verify` under the shared GUI lease.

Run `git diff --check`, stage only owned paths, and create one local commit. Do
not push, merge, open a PR, publish, or release. After green gates and commit,
remove only this dedicated worktree's `.build`.

The handoff reports the proved reset timing/root cause, topology token,
coalescing/bounded-pass behavior, commit SHA, paths, focused/full totals,
staged/manual evidence including flash observation, warnings, any reference
note, deferred hardware states, and WP-90 dependency.

## Implementation record

Pending. The implementor replaces this paragraph with the root cause, delivered
invariant, local commit SHA, exact verification evidence, deferred manual
states, warnings, and documentation-nuance classification before the final lane
gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-72 for Rafu: make flat window chrome survive drag-to-split and
every file/terminal/canvas tab-close topology change without a titlebar band or
flash, preserve AppKit window semantics and editor/terminal behavior, verify,
and commit the result locally."

You are in a dedicated worktree on branch
codex/presentation-window-chrome-lifecycle. Use gpt-5.6-sol with high
reasoning.

Read AGENTS.md, WP-72-window-chrome-lifecycle.md, the follow-up issue ledger,
WP-10, WP-20, ADRs 0012/0022, flat-window-chrome-titlebar-merge.md,
editor-tab-reorder-drop-zones.md, build-and-run.md, skill-routing.md, and every
owned source/test file. Use Build macOS Apps window-management,
appkit-interop, build-run-debug, the project-local swiftui-expert-skill with
its macOS/AppKit lifecycle references, and swiftui-patterns.

Run `git status --short --branch`. Stop unless the branch is exactly
codex/presentation-window-chrome-lifecycle, the tree is clean, and the initial
`git rev-parse HEAD` equals the coordinator-supplied exact
`<FOLLOWUP_BASE_SHA>`. Work only in FlatWindowChrome.swift,
WorkspaceWindowView.swift, FlatWindowChromeTests.swift, the new
WindowChromeTopologyLifecycleTests.swift, and this plan record. Treat
EditorCanvasView, WorkspaceSession, EditorLayout, shared styles/metrics/themes,
terminal/utility/Settings/Ensemble files, Package.*, shared indexes, and every
other lane as read-only.
If implementation proves a reusable platform/toolchain nuance, you may add one
uniquely named note under docs/references as required by AGENTS.md; do not edit
the reference index, and report the intended WP-90 index row. Otherwise add no
documentation-only churn.

First reproduce split and close failures and inspect style mask, title
visibility/transparency/separator, isMovable, effective top safe area, current
content/frame view, backdrop classes, and reset timing. Add a failing headless
NSWindow regression at the proved seam.

Add one explicit value-semantic topology reapply token to FlatWindowChrome and
derive it in WorkspaceWindowView from bounded observable editor/group/tab/
canvas identity. Do not edit WorkspaceSession or EditorLayout and do not add
callbacks to every close/split mutator. Route topology and existing window
notifications through one central main-actor, idempotent scheduler: immediate
apply plus only the bounded coalesced post-transaction passes evidence
requires; cancel stale work on detach/window replacement; never poll or use a
repeating timer.

Preserve the logical navigation title, traffic lights, fullSizeContentView,
transparent/hidden title, no separator, window-level safe-area cancellation,
backdrop scrubbing, themed background fallback, explicit drag handles,
fullscreen/key/inactive/restored behavior, editor split geometry, dirty-file
confirmation, and terminal teardown. Do not paint a fake overlay over the
symptom and verify there is no single-frame native band flash.

Add the headless invariant/coalescing/detach tests and run the read-only deck,
layout/drag, file-close, terminal-close, and restoration regressions named in
the plan. Manually cover complete/cancel/remove split; selected/background/
final file close; live/exited terminal close through all paths; Settings,
Ensemble, and other canvases; title changes; key/inactive/fullscreen/restored/
second-window states; themes, contrast/transparency, and available 1x/2x
displays. Use only Rafu Lightning and the shared GUI lease.

Final order:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change after the parallel suite. Then run
./script/build_and_run.sh --verify and `git diff --check`.

Stage only WP-72-owned paths and create one intentional local commit. Do not
push, merge, open a PR, release, or publish. After green gates and the commit,
remove only this worktree's .build. Report root cause, delivered invariant,
commit SHA, changed paths, exact focused/full test results, staged/manual/flash
evidence, warning count, deferred hardware checks, reusable nuances, remaining
risks, and that WP-90 is next. Complete the Goal only after the green commit and
handoff.
```
