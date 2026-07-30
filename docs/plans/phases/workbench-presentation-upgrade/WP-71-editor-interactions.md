# WP-71 — Editor tab visibility and Find focus routing

## Status and execution slot

- **Status:** Planned on 2026-07-30.
- **Wave:** Follow-up Wave 1; parallel with WP-72, WP-73, and WP-74.
- **Suggested branch:** `codex/presentation-editor-interactions`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact coordinator-supplied `<FOLLOWUP_BASE_SHA>`.
- **Issues closed:** WBP-001 and WBP-008.
- **Dependency:** all original presentation work through WP-60 is already in
  the base. This plan must finish before WP-90.

## Goal

Keep every open editor tab visibly identifiable until real horizontal overflow
is reached, and make Command-F and the supported Control-F route transfer first
responder to the active document's Find query immediately.

This is one lane because both corrections meet in `EditorCanvasView.swift`.
It must not change tab ownership, editor layout, document contents, Find
semantics, menu architecture, JSON theme authority, or the shared tab primitive.

## Required reading and skills

Read:

- `AGENTS.md`
- this plan and
  `docs/issues/workbench-presentation-follow-ups.md`
- `WP-20-editor-tabs-groups.md`
- ADR 0002, 0012, and 0022
- `docs/references/editor-tab-reorder-drop-zones.md`
- `docs/references/ui-design-language.md`
- `docs/references/skill-routing.md`
- the current implementations and tests named under Ownership

Use the project-local `swiftui-expert-skill`, reading its latest-API reference
and macOS layout/focus routes first. Use Build macOS Apps `swiftui-patterns`
for the tab strip and `appkit-interop` for `NSTextView`, keyboard events, and
first-responder behavior. Use `build-run-debug` for the staged Rafu Lightning
pass. No concurrency skill is required unless implementation introduces or
changes asynchronous or cross-actor behavior; it should not.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/Views/EditorCanvasView.swift`
- `Sources/RafuApp/Editor/DocumentFind.swift`
- `Sources/RafuApp/Editor/CodeEditorView.swift`
- `Sources/RafuApp/Editor/RafuTextView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`, limited strictly to
  document-Find presentation/focus routing

### Test paths

- `Tests/RafuAppTests/EditorFindTests.swift`
- new
  `Tests/RafuAppTests/EditorTabVisibilityPresentationTests.swift`
- new `Tests/RafuAppTests/EditorFindFocusRoutingTests.swift`

### Lane documentation

- this plan's implementation record
- one uniquely named reference note only if a reusable AppKit/SwiftUI
  first-responder nuance is proved during implementation

### Frozen and read-only

Do not edit:

- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`
- `Sources/RafuApp/Support/RafuMetrics.swift`
- `Sources/RafuApp/Support/RafuControlStyles.swift`
- `Sources/RafuApp/Support/RafuTheme.swift`
- `Sources/RafuApp/Editor/EditorLayout.swift`
- `Sources/RafuApp/App/RafuAppCommands.swift`
- `Sources/RafuApp/Views/FlatWindowChrome.swift`
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Tests/RafuAppTests/EditorTabAndGroupPresentationTests.swift`
- any terminal manager, utility, Settings, Ensemble, theme JSON, `Package.*`,
  shared index, or another follow-up plan path

If the correction genuinely requires a frozen path, stop and report a WP-90
dependency. Do not broaden ownership.

## Implementation contract

### E1. Prove whether tabs are missing or merely not rendering

Before changing layout, instrument or test the current runtime state:

1. Open at least three file tabs in one group.
2. Confirm the group still owns all tab IDs and resources.
3. Capture the tab-row frames, title-label bounds, resolved foreground colors,
   and horizontal-scroll content width.
4. Repeat with a mixed file/terminal tab set.

The screenshot is consistent with labels collapsing or inheriting an
ineffective foreground after WP-20, but that is a hypothesis. Do not “fix” the
model unless evidence shows the tabs were actually removed.

Add a regression that fails on the integrated base. Prefer a hosted/layout
assertion over a source scan because existing structural tests did not catch
the runtime defect.

### E2. Restore intrinsic tab identity without breaking overflow

In `EditorCanvasView.swift`:

- keep `EditorGroupTabBar`'s horizontal scroll container, named coordinate
  space, frame preferences, reorder insertion math, split targets, and shelf
  seam;
- keep `AttachedWorkbenchTab` as the shared selected-cap geometry;
- make the actual file and terminal `Button` labels carry explicit
  theme-derived active/inactive foreground semantics rather than relying on
  fragile nested inheritance;
- give icon, title, dirty/exited state, and close affordance stable layout
  priorities so sibling titles do not collapse while unused width exists;
- preserve bounded intrinsic document-tab width and allow horizontal overflow
  only when the sum of real tab widths exceeds the strip;
- preserve long-title truncation inside a visible tab rather than collapsing
  the entire inactive tab;
- keep immediate selection and close behavior. Add no decorative animation.

Do not change the shared tab style, introduce equal-width document tabs, or
replace the scroll/reorder system. WBP-002's equal-width navigation applies to
utility mode selectors, not document tabs.

### E3. Add an explicit, repeatable Find focus request

`defaultFocus` only helps during initial view insertion. The active document
needs a durable request that works when Find is newly inserted and when it is
already visible.

Implement a small main-actor focus contract:

1. Add a monotonically changing focus request identity to
   `DocumentFindState`, plus an intent-named method such as
   `requestQueryFocus()`.
2. `WorkspaceSession.showDocumentFind(includeReplace:)` must activate the
   correct selected document and issue that focus request every invocation,
   including repeated invocations while Find is already visible.
3. `DocumentFindBar` must observe the request identity and set its private
   `@FocusState` to `.query` after the field is installed. The initial
   presentation and every later request use the same path.
4. Do not use fixed sleeps, polling, global notifications, or a detached task.
   A main-actor view lifecycle/request identity is sufficient.
5. Preserve the query and established selection behavior when refocusing.
6. Dismissing with Escape must return first responder to the active editor
   without unexpectedly clearing the query.

The focus request is ephemeral UI metadata. It must not be serialized and must
not make document text observable in SwiftUI.

### E4. Route Control-F only from the editor

Command-F already has a menu/command route and remains read-only in
`RafuAppCommands.swift`.

Add the supported Control-F route narrowly through the editor bridge:

- pass an intent closure from the active `EditorDocumentView` /
  `CodeEditorView` boundary into `RafuTextView`;
- intercept the exact unmodified Control-F keyboard event before TextKit
  inserts it and call `showDocumentFind`;
- leave Command-F to the existing command system;
- do not capture Control-F in terminals, Settings fields, Search, commit
  messages, or other text inputs;
- preserve all other TextKit key bindings, marked-text handling, multi-caret
  behavior, and responder-chain commands.

Immediate typing after either shortcut must change only `state.query`.

## Tests

Add focused behavioral coverage for:

- three or more file tabs at sufficient width: every title has non-zero visible
  bounds and an active/inactive presentation;
- active, inactive, dirty, long-name, close, hover/focus, and inactive-window
  tab states;
- mixed file and terminal tabs;
- real overflow retains access, reorder frame capture, and selection;
- each Find invocation increments/changes the focus request, even while active;
- Find targets the selected document in the focused editor group;
- initial presentation and repeated presentation focus the query;
- immediate typing does not alter document text;
- Control-F is consumed by the editor bridge and unrelated control-key events
  are not;
- Command-F's existing command route remains valid;
- Escape returns focus to the editor and preserves the query;
- two groups and two windows keep independent Find state.

Read-only regression suites to run include:

- `EditorTabAndGroupPresentationTests`
- `EditorDragAndDropTests`
- `EditorLayoutTests`
- `EditorTabSwitcherTests`
- `EditorThemeColorApplicationTests`
- existing TextKit editing and multi-caret suites

## Manual acceptance

Using only staged Rafu Lightning:

1. Open one, three, and enough files to overflow a group. Verify all
   non-overflowed names remain visible and overflow scrolls.
2. Mix file and terminal tabs; select, close, reorder, restore, and drag them
   between split groups.
3. Verify dirty, exited, hover, pressed, focused, and inactive-window states.
4. From each split, press Command-F, type immediately, dismiss, then repeat
   while Find is already visible.
5. Repeat with Control-F. Confirm it does not hijack Search, Settings, a
   terminal, or a commit-message field.
6. Repeat with two workspace windows.
7. Cover all bundled themes plus one imported user JSON theme, Increase
   Contrast, largest supported text, Full Keyboard Access, and VoiceOver.
8. Cover a true 1× and 2× display when available; defer missing physical
   hardware evidence explicitly to WP-90.

No titlebar/chrome correction belongs in this lane; record any such symptom for
WP-72.

## Verification and handoff

Run the lane's focused tests first. Final sequence:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Nothing may modify a tracked file after the parallel suite. Run
`./script/build_and_run.sh --verify` under the shared GUI lease, or report the
exact deferred manual states to the coordinator.

Run `git diff --check`, stage only owned paths, and create one local commit. Do
not push, merge, open a PR, publish, or release. After green gates and the
commit, remove only this dedicated worktree's `.build`.

The handoff reports diagnosis, exact behavior, commit SHA, paths, focused/full
test totals, staged-app/manual evidence, deferred hardware checks, warnings,
new reusable nuances, and the WP-90 dependency.

## Implementation record

Pending. The implementor replaces this paragraph with the delivered behavior,
local commit SHA, exact verification evidence, deferred manual states,
warnings, and documentation-nuance classification before the final lane gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-71 for Rafu: restore visible identity for every open editor tab
until real horizontal overflow and make Command-F and the supported Control-F
route focus the active document's Find query immediately; preserve editor
layout, tab drag/reorder, TextKit behavior, theme authority, verify, and commit
the result locally."

You are in a dedicated worktree on branch
codex/presentation-editor-interactions. Use gpt-5.6-sol with high reasoning.

Read AGENTS.md, WP-71-editor-interactions.md, the follow-up issue ledger,
WP-20-editor-tabs-groups.md, ADRs 0002/0012/0022,
editor-tab-reorder-drop-zones.md, ui-design-language.md, skill-routing.md, and
every owned source/test file. Use the project-local swiftui-expert-skill with
its latest-API and macOS focus/layout references, Build macOS Apps
swiftui-patterns, appkit-interop, and build-run-debug.

Run `git status --short --branch`. Stop unless the branch is exactly
codex/presentation-editor-interactions, the tree is clean, and the initial
`git rev-parse HEAD` equals the coordinator-supplied exact
`<FOLLOWUP_BASE_SHA>`. Work only in WP-71's owned paths. Treat shared
workbench styles/metrics/theme files, EditorLayout, RafuAppCommands,
FlatWindowChrome, WorkspaceWindowView, terminal/utility/Settings/Ensemble
paths, EditorTabAndGroupPresentationTests, Package.*, shared indexes, and every
other lane as read-only.
If implementation proves a reusable platform/toolchain nuance, you may add one
uniquely named note under docs/references as required by AGENTS.md; do not edit
the reference index, and report the intended WP-90 index row. Otherwise add no
documentation-only churn.

First reproduce WBP-001 and prove whether the tab model, row frame, title
bounds, or resolved style is failing. Add a runtime/layout regression, not only
a source scan. Keep the existing horizontal scroll, named coordinate space,
drop-frame capture, reorder/split behavior, shelf seam, and
AttachedWorkbenchTab. Give the actual file/terminal Button labels explicit
theme-derived active/inactive semantics and stable intrinsic layout so every
non-overflowed tab remains named. Do not make document tabs equal-width and do
not edit the shared tab primitive.

Add a monotonic query-focus request to DocumentFindState. Make
WorkspaceSession.showDocumentFind issue it on every invocation. Make
DocumentFindBar consume it after field installation for both initial and
repeated presentation, without sleeps or polling. Route exact Control-F only
through the active RafuTextView/CodeEditorView bridge; preserve the existing
Command-F menu route and every unrelated TextKit key binding. Immediate typing
must change only the query, and Escape must return focus to the editor without
unexpectedly clearing it.

Add the focused tests and run the read-only editor drag/layout/switcher/theme/
TextKit regressions named in the plan. Manually verify one/three/overflow and
mixed tabs; active/inactive/dirty/exited/long/hover/focus states; Command-F and
Control-F in every split and two windows; unrelated text fields; themes,
Increase Contrast, larger text, Full Keyboard Access, VoiceOver, and available
1x/2x displays. Use only Rafu Lightning and the shared GUI lease.

Final order:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change after the parallel suite. Then run the staged-app
verification if the lease is available and `git diff --check`.

Stage only WP-71-owned paths and create one intentional local commit. Do not
push, merge, open a PR, release, or publish. After green gates and the commit,
remove only this worktree's .build. Report diagnosis, delivered behavior,
commit SHA, changed paths, exact focused/full test results, staged/manual
evidence, warning count, deferred hardware checks, reusable nuances, remaining
risks, and that WP-90 is next. Complete the Goal only after the green commit and
handoff.
```
