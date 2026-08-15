# TG-21 — Recursive Terminal Group renderer and focus bridge

## Status and execution slot

- **Status:** Planned.
- **Wave:** 2; parallel with TG-20 and TG-22.
- **Branch:** `terminal-groups/tg-21-renderer-focus`.
- **Required base:** exact `<TG10_MERGED_SHA>`.
- **Prerequisite:** TG-10 contracts are frozen.
- **Next dependency:** TG-30 integrates this renderer after Wave 2 merges.

## Goal

Build a reusable recursive group renderer, persistent divider bridge, and
first-responder bridge. The renderer consumes a frozen snapshot and sends
typed actions through closures. It does not know `WorkspaceSession`, mutate
editor layout, own a process, or start a shell.

Keep one SwiftTerm view per controller and preserve all current terminal theme,
scrollback, paste, selection, and teardown behavior.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-21-renderer-focus.md`
4. `docs/plans/phases/terminal-groups.md`
5. `docs/plans/phases/pre-initial-push-workbench.md`
6. `docs/decisions/0004-embedded-terminal.md`
7. `docs/decisions/0014-terminal-as-editor-tab.md`
8. `docs/decisions/0018-conductor-external-agent-orchestration.md`
9. `docs/decisions/0021-agent-terminals.md`
10. `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
11. `docs/plans/phases/editor-terminal-tabs.md`
12. `docs/plans/phases/terminal-manager.md`
13. `docs/references/skill-routing.md`
14. `docs/references/build-and-run.md`

Then read these lane-specific files:

- `Sources/RafuApp/Terminal/TerminalGroupModel.swift`;
- `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`;
- `Sources/RafuApp/Terminal/RafuTerminalView.swift`;
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift` as read-only;
- the terminal resource rendering in
  `Sources/RafuApp/Views/EditorCanvasView.swift` as read-only;
- the editor split renderer in the same file as pattern-only context;
- `Sources/RafuApp/Support/RafuWorkbenchStyles.swift`;
- `Tests/RafuAppTests/TerminalEditorTabTests.swift`;
- `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`;
- `Tests/RafuAppTests/EditorTabAndGroupPresentationTests.swift`;
- `docs/references/swiftui-appkit-boundary.md`;
- `docs/references/swiftui-macos-runtime-render-and-focus-tests.md`; and
- `docs/references/ui-design-language.md`.

Use these skills and read the named files completely before implementation:

1. project-local `swiftui-expert-skill`: `SKILL.md`, `latest-apis.md`,
   `state-management.md`, `view-structure.md`, `layout-best-practices.md`,
   `focus-patterns.md`, `accessibility-patterns.md`, and `macos-views.md`;
2. Build macOS Apps `swiftui-patterns`: `SKILL.md` and
   `references/split-inspectors.md`; and
3. Build macOS Apps `appkit-interop`: `SKILL.md`,
   `references/representables.md`, and `references/responder-menus.md`.

If implementation adds tasks, async streams, or cross-actor state, stop and
also use the root project-local `swift-concurrency-pro` review path.

## Exclusive ownership

### Production paths

- new `Sources/RafuApp/Terminal/TerminalGroupView.swift`;
- new `Sources/RafuApp/Terminal/TerminalGroupSplitView.swift`;
- `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`; and
- `Sources/RafuApp/Terminal/RafuTerminalView.swift`.

### Test paths

- new `Tests/RafuAppTests/TerminalGroupViewPresentationTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupFocusBridgeTests.swift`; and
- new `Tests/RafuAppTests/TerminalGroupSplitViewTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-appkit-split-focus.md`, only for a
  proved reusable `NSSplitView`, `NSViewRepresentable`, or first-responder
  fact.

All other paths are read-only. Do not edit `WorkspaceSession`,
`WorkspaceTerminalController`, `EditorCanvasView`, TG-10 contracts, commands,
persistence, `Package.*`, styles, shared indexes, or existing test files.

## Implementation contract

### V1. Snapshot-driven recursive view

Create `TerminalGroupView` with explicit inputs equivalent to:

- one `TerminalGroupSnapshot`;
- controller lookup for a pane;
- an action closure for focus, split fraction, close, restart, and start; and
- the current Rafu theme.

Render `.pane` as a focused pane view and `.split` as a nested
`TerminalGroupSplitView`. Use stable pane and split IDs. Do not derive identity
from array offsets or session UUIDs.

The view body must not sort, validate, decode, probe a shell, perform I/O, or
create a controller. Show an exact inert or unavailable placeholder when no
controller exists.

### V2. Narrow split bridge

Implement the smallest `NSSplitView` bridge needed to:

- render columns for Split Right and rows for Split Down;
- accept a normalized initial fraction;
- report user divider changes through a typed callback;
- preserve nested SwiftUI child content;
- apply usable minimum pane sizes;
- avoid a second state authority; and
- avoid decorative animation.

The SwiftUI snapshot remains authoritative. The coordinator stores only weak or
platform view references and does not own app state. Invalid fractions fall
back to `0.5`. Keep the saved user fraction separate from the effective
displayed fraction. Minimum-size constraints and window resize can clamp only
the effective fraction; they must not call the mutation closure or overwrite
the snapshot. Report a new normalized snapshot fraction only for an actual
user divider drag. When space returns, the bridge applies the unchanged saved
fraction again.

### V3. One focused leaf

Extend the existing terminal host with pane-aware focus inputs:

- `paneID`;
- `isFocusedPane`;
- `requestFocusToken` or an equivalent monotonic value; and
- `onDidBecomeFirstResponder`.

Only `isFocusedPane` can request first responder on mount or explicit focus
change. Do not let every mounted leaf schedule `makeFirstResponder`.

Override or observe `RafuTerminalView.becomeFirstResponder()` so a successful
pointer focus reports its pane ID to the group. Use a weak callback. Do not
retain the session or create an AppKit-owned focus model.

Keep a source-compatible single-terminal initializer until TG-30 performs the
cutover.

### V4. Pane chrome and states

Each pane provides a compact, accessible header outside the SwiftTerm viewport:

- pane name and provider identity;
- running, attention, exited, stopped, or unavailable status;
- workspace-relative folder;
- focused indication;
- close action;
- Restart for exited shell panes;
- Start Pane for safe stopped shell panes; and
- the exact fixed Agent or Ensemble message from TG-10, derived from the
  unavailable saved-pane kind.

Do not place an inset, corner mask, or opaque overlay on the terminal output.
Use the existing terminal surface style and theme tokens. Color never carries
state alone.

### V5. Accessibility and keyboard scope

Expose group, pane, status, focus, folder, split orientation, and actions to
VoiceOver. Pane order follows visual tree order. All header actions work with
Full Keyboard Access. The renderer does not install global key equivalents;
TG-41 owns app commands.

The AppKit bridge must not consume ordinary terminal input. It reports focus
only after AppKit makes the terminal view first responder.

### V6. Lifetime

Mounting a live pane reuses its controller's one existing terminal view.
Unmounting or hiding detaches the view without closing its process. Removing a
pane does not call `shutdown()` from the view; the runtime owns teardown.

A Start action only reports a typed request. After TG-30 reveals a parked
group and the runtime creates a committed controller, normal controller/view
mounting performs the current lazy spawn. The renderer does not promise batch
spawn success or rollback. An external spawn failure becomes that pane's
normal exited/error state.

Coordinators, representables, and callbacks must release when the pane or group
disappears. Do not retain `NSWindow`, `WorkspaceSession`, or controller beyond
the existing controller-owned view rule.

## Tests

Add headless or source-contract coverage for:

- stable recursive node rendering;
- column/row mapping;
- fraction fallback, effective clamp, and user-drag callback;
- temporary minimum-size clamping does not overwrite the saved fraction;
- nested split identity;
- only focused pane requests first responder;
- pointer focus callback uses the correct pane ID;
- focus callback release on dismantle;
- stopped, unavailable, exited, attention, and live pane labels/actions;
- no direct `WorkspaceSession` reference;
- no process creation or controller construction in `body`;
- no terminal viewport clip/mask/inset; and
- source-compatible current single-terminal host use.

Run existing terminal presentation, focus, editor-tab, and theme contract
filters read-only.

## Manual acceptance

No production call site uses the renderer on this branch. A GUI pass is
deferred to TG-30. If a focused local harness is available without adding a
package or app path, check nested divider drag and focus, but do not claim the
integrated gate.

## Verification and handoff

Complete all changes and the implementation record before the common final
sequence. Run `git diff --check`, commit only TG-21 paths, do not push or merge,
and remove this worktree's `.build` after the green commit.

The handoff reports renderer API, AppKit gap, coordinator ownership, focus
proof, accessibility states, tests, warnings, deferred integrated GUI checks,
branch, commit message, SHA, next dependency, and **Deviations**.

## Implementation record

To be completed by the TG-21 implementor before the final gate.

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-21 from
docs/plans/phases/terminal-groups/TG-21-renderer-focus.md: build Rafu's
snapshot-driven recursive terminal split view, persistent divider bridge, and
single-leaf AppKit focus bridge without taking process or workspace ownership;
verify and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run
`git switch terminal-groups/tg-21-renderer-focus` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-21-renderer-focus, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG10_MERGED_SHA>`.
Do not create or replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-21-renderer-focus.md;
docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/0023-terminal-groups-and-saved-layouts.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/references/skill-routing.md; docs/references/build-and-run.md; and every
lane-specific source, test, and reference path in TG-21. Before
implementation, read and use the complete
project-local swiftui-expert-skill with its latest-apis, state-management,
view-structure, layout, focus, accessibility, and macOS-views references;
Build macOS Apps swiftui-patterns with split-inspectors; and appkit-interop
with representables and responder-menus. If async or cross-actor work appears,
also use the root swift-concurrency-pro review path.

Edit only new TerminalGroupView.swift, new TerminalGroupSplitView.swift,
EditorTerminalTabContent.swift, RafuTerminalView.swift, the three new TG-21
tests, this plan's Status and record, and conditional
docs/references/terminal-group-appkit-split-focus.md only when its documented
trigger applies. Treat
WorkspaceSession, WorkspaceTerminalController, EditorCanvasView, contracts,
commands, persistence, styles, Package.swift, shared indexes, and existing
tests as read-only.

Implement V1 through V6. The recursive view consumes snapshots and closures.
Use a narrow NSSplitView bridge for real divider fractions. Only the focused
leaf requests first responder. Pointer focus reports one pane ID. Keep terminal
output unclipped and preserve the current single-terminal initializer until
TG-30. Do not start or close a process from a view.

Add the exact tests and run read-only terminal presentation, focus, editor-tab,
and theme regressions. Use one SwiftPM invocation at a time. Isolate a failing
test and never edit an unowned failure.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Run `git diff --check`.

Stage only TG-21 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm a clean branch, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Report renderer API, focus/AppKit ownership, divider behavior, accessibility,
paths, focused/full tests, warnings, deferred integrated GUI checks, risks,
reference need, branch, commit message, SHA, and next dependency. Include
Deviations with `None` when none. Complete the Goal only after commit and full
handoff.
```
