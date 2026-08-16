# TG-41 — Terminal Group commands and save UI

## Status and execution slot

- **Status:** Implemented on lane; awaiting authorized merge.
- **Wave:** 4; parallel with TG-40 and TG-42.
- **Branch:** `terminal-groups/tg-41-commands-save-ui`.
- **Required base:** exact `<TG30_MERGED_SHA>`.
- **Prerequisite:** TG-30 workspace API is frozen.
- **Next dependency:** TG-90 starts after all Wave 4 branches merge.

## Goal

Add the complete menu, keyboard, command-palette, and Save As UI for Terminal
Groups. Route every action through the frozen workspace API so menu validation,
keyboard scope, toolbar/palette actions, and visible UI use one behavior.

Do not implement a second group, save store, process action, or focus owner.

## Required reading and skills

Read these common files completely, in order:

1. `AGENTS.md`
2. `docs/plans/phases/terminal-groups/README.md`
3. `docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md`
4. `docs/plans/phases/terminal-groups.md`
5. `docs/plans/phases/pre-initial-push-workbench.md`
6. `docs/decisions/0004-embedded-terminal.md`
7. `docs/decisions/0014-terminal-as-editor-tab.md`
8. `docs/decisions/0018-conductor-external-agent-orchestration.md`
9. `docs/decisions/0021-agent-terminals.md`
10. `docs/decisions/0023-terminal-groups-and-saved-layouts.md`
11. `docs/plans/phases/editor-terminal-tabs.md`
12. `docs/plans/phases/terminal-manager.md`
13. `docs/plans/phases/terminal-groups/TG-30-workspace-integration.md`,
    including its implementation record
14. `docs/references/skill-routing.md`
15. `docs/references/build-and-run.md`

Then read these lane-specific files:

- `Sources/RafuApp/App/RafuAppCommands.swift`;
- `Sources/RafuApp/Views/CommandPaletteView.swift`;
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`;
- the frozen Terminal Group command/save request API in
  `Sources/RafuApp/Models/WorkspaceSession.swift`;
- `Sources/RafuApp/Views/IgnoreSuggestionSheet.swift` and
  `Sources/RafuApp/Views/GitHubPublishSheet.swift` as sheet patterns;
- `Tests/RafuAppTests/SearchCommandPaletteTests.swift`;
- `Tests/RafuAppTests/WorkspaceCloseActionTests.swift` as read-only;
- `docs/references/command-palette-and-search-pitfalls.md`;
- `docs/references/editor-window-close-resolution-order.md`;
- `docs/references/window-scoped-modifier-key-switcher.md`;
- `docs/references/swiftui-appkit-boundary.md`; and
- `docs/references/ui-design-language.md`.

Use these skills and named references:

1. project-local `swiftui-expert-skill`: complete `SKILL.md`,
   `latest-apis.md`, `state-management.md`, `view-structure.md`,
   `focus-patterns.md`, `accessibility-patterns.md`,
   `sheet-navigation-patterns.md`, and `macos-views.md`;
2. Build macOS Apps `swiftui-patterns`: complete `SKILL.md`,
   `commands-menus.md`, and `components-index.md`; and
3. Build macOS Apps `appkit-interop`: complete `SKILL.md` and
   `responder-menus.md`.

If this lane adds task or cross-actor behavior, also use the root
`swift-concurrency-pro` review path.

## Exclusive ownership

### Production paths

- `Sources/RafuApp/App/RafuAppCommands.swift`;
- `Sources/RafuApp/Views/CommandPaletteView.swift`;
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`;
- new `Sources/RafuApp/Views/TerminalGroupSaveSheet.swift`; and
- new `Sources/RafuApp/Views/TerminalPaneStartingFolderPicker.swift`.

### Test paths

- `Tests/RafuAppTests/SearchCommandPaletteTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupCommandPresentationTests.swift`;
- new `Tests/RafuAppTests/TerminalGroupSaveSheetTests.swift`;
- new `Tests/RafuAppTests/TerminalPaneStartingFolderPickerTests.swift`.

### Lane documentation

- this plan's Status and implementation record; and
- optional `docs/references/terminal-group-command-routing.md`, only for a new
  reusable menu, responder, command registry, save sheet, or accessibility
  fact.

All other paths are read-only. Do not edit `WorkspaceSession`, runtime,
renderer, store, editor canvas, Terminal Manager, switcher, Agent/Ensemble
code, `Package.*`, ADR, or shared index.

## Implementation contract

### K1. Contextual New Terminal commands

Add one command registry route for each action. Menu and palette entries use
the same workspace method and validation.

- **New Terminal Group**: `Command-T` when no Terminal Group is selected. It
  opens one preferred-shell pane.
- **Split Terminal Right**: `Command-T` when a Terminal Group is selected.
- **Split Terminal Down**: `Shift-Command-T` only when a Terminal Group is
  selected.
- **New Terminal Group**: `Control-Shift-backtick` in every workspace context.
  This action and its menu/palette row always create a new one-pane group,
  even when another Terminal Group is selected.

The `Command-T` menu title can change with context, or two mutually exclusive
validated items can share the key equivalent. There must be one enabled action
for one key event. `Shift-Command-T` must not shadow a future Reopen Closed Tab
outside Terminal Group context.

Keep `Control-backtick` on the frozen TG-30 toggle route: park the selected
group, otherwise reveal the most recently parked group, otherwise create one.

When the Terminal Group Save/Save As sheet, pane-folder picker, or group-close
confirmation is active for a window, that modal request owns command input.
`Command-T`, `Shift-Command-T`, `Control-Shift-backtick`, `Control-backtick`,
`Command-S`, `Shift-Command-S`, `Command-W`, and
`Control-Command-Arrow` must not mutate the group, editor layout, or another
window behind it. Only that modal's explicit Save, Confirm, Cancel, Return, or
Escape route can complete or dismiss it. Menu and palette validation report
the same modal reason.

### K2. Directional focus commands

Add **Focus Terminal Pane Left/Right/Up/Down** with
`Control-Command-Arrow`. Enable them only for a selected Terminal Group and
only when a pane exists in that direction. At an outer edge, the key does not
wrap or move the editor group.

Use menu key equivalents so AppKit resolves them before SwiftTerm input. Test
that the terminal view does not receive the command chord. Do not bind
Option-Command-Up/Down or Control-Tab.

### K3. Group actions

Add menu and palette actions for:

- Rename Terminal Group…;
- Save Terminal Group;
- Save Terminal Group As…;
- Set Pane Starting Folder…;
- Close Terminal Pane;
- Start Terminal Pane;
- Start All Restartable Panes;
- Hide Terminal Group; and
- Close Terminal Group.

Enable each action from frozen workspace state. Close Group routes through
confirmation. Close Pane is not `Command-W`; `Command-W` keeps closing the
outer selected tab through the existing command.

### K4. Pane starting folder

Add **Set Pane Starting Folder…** to the selected pane's visible actions,
menu, and palette. Present one native folder picker scoped to the current
window. Seed it from the pane's stored profile folder. Submit only the selected
URL to the frozen workspace validation API.

Enable it only for an ordinary-shell pane with a safe launch profile. Disable
it with an exact reason for Agent, Ensemble, or unavailable panes.

The workspace API resolves symlinks, rejects traversal or a folder outside the
workspace, and returns bounded error text. A valid selection updates only the
safe future-start profile. It
does not send terminal input, restart a controller, or read a live working
directory. The workspace root is a valid explicit choice. Two windows own
independent picker state.

### K5. Contextual Save

Replace the current Save command with one contextual route:

- selected file/untitled document: current document Save behavior and
  `Command-S`;
- selected Terminal Group: Save Terminal Group and `Command-S`;
- neither: disabled.

Add **Save Terminal Group As…** with `Shift-Command-S` only for a selected
Terminal Group. Do not add document Save As behavior in this phase.

First Save uses the current group name and creates an ID. A name conflict or
invalid name presents the save sheet instead of overwriting another layout.
Later Save updates the same ID. Save As always opens the sheet and creates a
new ID. After the store succeeds, Save As also renames only that open group to
the validated saved-layout name and associates the new ID. A failed, cancelled,
or stale Save As changes neither its group name nor its association.

### K6. Save sheet

Create a focused native sheet with:

- group layout summary and pane count;
- editable saved-layout name, seeded from the group name;
- clear text that only metadata and ordinary shell profiles are saved;
- clear text that restore is stopped and does not save output;
- validation/error text;
- Cancel and Save actions; and
- default/cancel key equivalents.

The sheet does not read or write the store. It submits a name through the
workspace API and displays frozen request state. Keep state private. Do not
expose a live session ID in accessibility or error text.

Host the sheet from `WorkspaceWindowView` using the existing per-window
session. Two windows can present independent save sheets.

The saved-layout name and the live group name are one value after successful
Save As. A later Save writes that current group name to the associated record;
it cannot silently restore the pre-Save-As name.

### K7. Command palette honesty

Command palette rows show current title, shortcut, enabled state, and a short
reason when disabled. Search ranking and mode parsing remain unchanged. Do not
duplicate business logic or start a Task from row construction.

Core actions remain reachable by visible tab/pane/manager UI, menu, keyboard,
and palette. No action is available only through a context menu.

## Tests

Pin:

- one `Command-T` action enabled in file/no-tab/group contexts;
- `Shift-Command-T` group-only scope;
- always-available `Control-Shift-backtick` New Terminal Group;
- exact `Control-backtick` park, MRU reveal, and create fallback route;
- four directional keys and outer-edge disabled state;
- no collision with multi-caret, Control-Tab, current toggle, Agent Terminal,
  Ensemble, Go to Definition, or Find References shortcuts;
- file Save unchanged;
- group Save and Save As routing;
- first Save, update, conflict-to-sheet, and Save As request state;
- successful Save As renames only its target group; failed, cancelled, or stale
  Save As preserves the prior name and saved ID;
- sheet name trim, empty, duplicate, Cancel, Save, and store error display;
- starting-folder seed, inside-workspace acceptance, outside-workspace error,
  symlink-escape error, Cancel, and no terminal-input action;
- two-window sheet and folder-picker ownership;
- every group shortcut is blocked behind each save sheet, folder picker, and
  close confirmation without mutating the covered group or another window;
- palette titles, shortcuts, enabled reasons, and one shared action route; and
- no command chord forwarded to SwiftTerm.

Run read-only workspace-close, editor Save, terminal integration, switcher,
Agent Terminal, and Ensemble command regressions.

## Manual acceptance

Under the Rafu Lightning GUI lease, place SwiftTerm first responder and verify
all keyboard commands. Also verify:

- `Command-T` from file, empty editor, one-pane group, and nested group;
- `Shift-Command-T` inside and outside a group;
- `Control-Shift-backtick` while a file or another group is selected;
- `Control-backtick` park, most-recent reveal, and no-parked fallback;
- four focus directions and outer edges;
- file Save remains unchanged;
- first Save, repeat Save, Save As, duplicate name, Cancel, and error;
- Set Pane Starting Folder inside/outside the workspace;
- rename, Start Pane/Start All Restartable Panes, hide, pane close, and group
  close menu/palette paths;
- two windows;
- Full Keyboard Access and VoiceOver; and
- no plain terminal input is consumed beyond the exact command chords.

## Verification and handoff

Complete all changes and the implementation record before the common final
sequence. After the parallel suite, run Rafu Lightning under the shared GUI
lease or report all exact deferrals. Run `git diff --check`, commit only TG-41
paths, and remove this worktree's `.build` after the green commit.

The handoff reports the shortcut matrix, Save routing, palette/menu parity,
sheet and accessibility evidence, tests, warnings, paths, branch, commit
message, SHA, next dependency, and **Deviations**.

## Implementation record

Status: Implemented on lane; awaiting authorized merge

Implemented on `terminal-groups/tg-41-commands-save-ui` from
`7bb2488ab17b3e09614e3a5dc69db2030140aab3`.

- Contextual Terminal Group commands, Save/Save As, command-palette routes,
  native save and rename sheets, and the window-scoped folder picker route
  use the WorkspaceSession action API.
- Focused tests cover request ownership, cancellation, teardown reset, modal
  blocking, forwarding completion to the existing rename/folder validators,
  action-specific availability, capacity boundaries, shortcut routing, and
  metadata-only sheet validation and layout summaries.
- Save-sheet submission is window-owned state. It keeps the request modal
  until the existing saved-layout mutation succeeds. A conflict or store
  error leaves the request and old group state in place. The submission epoch
  prevents an old workspace operation from dismissing a newer request.
- Contract corrections: splitting a classified or nonrestartable pane stays
  available when the normal group and window limits permit it; it creates a
  fresh ordinary-shell pane at the workspace root. Start All considers only
  stopped ordinary-shell panes with available profiles.

Security and concurrency review: the picker keeps a selected URL only until
the synchronous WorkspaceSession validation completes. Save completion uses
the existing store task, workspace generation, mutation epoch, and an added
window presentation epoch. It does not start a second persistence task.
The Save control and Return route both use the same 80-Unicode-scalar name
validation. Interactive dismissal and Cancel are disabled while the existing
store task is in flight. New Save As requests clear old bounded store errors.
Synchronous save setup failures use the same group-and-presentation-epoch
completion guard as asynchronous failures, so a sheet stays available for a
corrected retry.

Added TG-41 tests include `exitedShellDisablesStartAll`,
`liveClassifiedPaneFolderReasons`,
`terminalGroupSaveSheetSubmissionDismissesOnlyAfterSuccess`,
`terminalGroupSaveSheetConflictKeepsRequestAndGroup`,
`terminalGroupSaveSheetCancellationBeforeSubmitPreservesState`, and
`staleTerminalGroupSaveCompletionKeepsNewerRequest`. These use the existing
TG-30 `TerminalGroupIntegrationStore` actor. TG-41 adds no second store
fixture.
`terminalGroupSaveSheetCancellationDuringSubmissionWaitsForSuccess` and
`terminalGroupSaveSheetDisableAndDismissAudit` cover the in-flight cancel,
interactive-dismiss, and invalid-draft safeguards.

Authorized deviation: TG-30 omitted the required per-window presentation
request seam. The merge owner authorized this lane to add only ephemeral
WorkspaceSession request state and request/update/complete/cancel methods for
rename and pane starting folder, plus the computed modal-input gate. The state
is not persisted and completion delegates to the existing validation methods.

The merge owner also authorized the narrow read-only directional query through
`WorkspaceSession.swift`, `TerminalGroupRuntime.swift`,
`WorkspaceTerminalController.swift`, and `TerminalGroupRuntimeTests.swift`.

### Verification evidence

- Coordinator verification ran the combined focused TG-41 filter in parallel:
  91 tests, 0 suites, 0 failures, 0.044 seconds, exit 0. This is coordinator
  verification, not worker verification.
- Worker build: `./script/build.sh` completed successfully in 13.68 seconds.
  SwiftPM reported one pre-existing unhandled-fixture warning for
  `Tests/RafuAppTests/Fixtures/workbench-converged-surfaces.json`.
- Full parallel suite did not complete: the one worker process hung with its
  Swift Testing helper idle on the main run loop after more than five minutes.
  The owned `swift-test` and helper were stopped. This is not a full-pass
  result. Rafu Lightning GUI verification is not run yet.

### Review and handoff state

- Security: selected folder URLs are security-scoped only around synchronous
  validation. The presentation state keeps no live process, output, CWD, or
  controller reference.
- Concurrency: the existing store mutation task remains the only save task.
  Workspace generation, mutation epoch, and presentation epoch reject stale
  completion effects.
- Accessibility: menus retain keyboard routes; sheets use named text fields,
  visible bounded validation, standard Cancel/Save controls, and disabled
  duplicate-submit state. No VoiceOver or live keyboard pass has run yet.
- Manual deferral: Rafu Lightning menu, sheet, second-window, Full Keyboard
  Access, and VoiceOver checks need the later GUI verification step.
- Deviation: an earlier worker attempt started duplicate focused-test waiters
  while a cold dependency checkout held SwiftPM. The duplicate waiters were
  stopped without terminating the original invocation. Later focused evidence
  above is the coordinator's clean verification result.
- Risk / coordinator correction: `TerminalGroupSessionIntegrationTests.swift`
  is TG-30-owned and still asserts that an in-flight Save As has no pending
  request. TG-41 intentionally keeps the same request open and modal. The
  coordinator/TG-90 correction should expect that request for the target
  group, proposed name `Copy`, and `isPendingTerminalGroupSaveSubmission == true`
  while suspended; after release it should expect a nil request and false
  submission state. TG-41 does not edit that out-of-scope test.

### Changed paths

- `Sources/RafuApp/App/RafuAppCommands.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Terminal/TerminalGroupRuntime.swift`
- `Sources/RafuApp/Terminal/WorkspaceTerminalController.swift`
- `Sources/RafuApp/Views/CommandPaletteView.swift`
- `Sources/RafuApp/Views/TerminalGroupSaveSheet.swift`
- `Sources/RafuApp/Views/WorkspaceWindowView.swift`
- `Tests/RafuAppTests/TerminalGroupCommandPresentationTests.swift`
- `Tests/RafuAppTests/TerminalGroupRuntimeTests.swift`
- `Tests/RafuAppTests/TerminalGroupSaveSheetTests.swift`
- `docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md`

## Goal Mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement TG-41 from
docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md: add the exact
Terminal Group menu, keyboard, palette, contextual Save, Save As, and native
save-sheet routes through Rafu's frozen workspace API; preserve file and
terminal responder behavior, verify, and commit locally."

Run `git status --short --branch` before any branch change. Stop if the
worktree is not clean. Then run
`git switch terminal-groups/tg-41-commands-save-ui` and run
`git status --short --branch` again. Stop unless the branch is exactly
terminal-groups/tg-41-commands-save-ui, the tree is clean, and the initial
`git rev-parse HEAD` is the merge-owner-supplied exact `<TG30_MERGED_SHA>`.
Do not create or replace a branch, rebase, or modify user work.

Read AGENTS.md; docs/plans/phases/terminal-groups/README.md;
docs/plans/phases/terminal-groups/TG-41-commands-save-ui.md;
docs/plans/phases/terminal-groups.md;
docs/plans/phases/pre-initial-push-workbench.md;
docs/decisions/0004-embedded-terminal.md;
docs/decisions/0014-terminal-as-editor-tab.md;
docs/decisions/0018-conductor-external-agent-orchestration.md;
docs/decisions/0021-agent-terminals.md;
docs/decisions/0023-terminal-groups-and-saved-layouts.md;
docs/plans/phases/editor-terminal-tabs.md;
docs/plans/phases/terminal-manager.md;
docs/plans/phases/terminal-groups/TG-30-workspace-integration.md, including its
implementation record; docs/references/skill-routing.md;
docs/references/build-and-run.md; and every lane-specific source, test, and
reference path in TG-41. Read and use the complete project-local
swiftui-expert-skill with the exact TG-41
references; Build macOS Apps swiftui-patterns with commands-menus and
components-index; and appkit-interop with responder-menus. Use root
swift-concurrency-pro only if task or actor behavior changes.

Edit only RafuAppCommands.swift, CommandPaletteView.swift,
WorkspaceWindowView.swift, new TerminalGroupSaveSheet.swift, new
TerminalPaneStartingFolderPicker.swift, TG-41-owned tests, this plan's record,
and conditional docs/references/terminal-group-command-routing.md only when its
documented trigger applies. Treat
WorkspaceSession, runtime, renderer, store, editor canvas, manager, switcher,
Agent/Ensemble code, Package.swift, ADRs, and shared indexes as read-only.

Implement K1 through K7. Command-T opens a group or splits right by context.
Shift-Command-T splits down only in a group. Control-Shift-backtick always
creates a group. Control-backtick follows park/MRU/create order.
Control-Command-Arrows focus without wrap. Add the per-window starting-folder
picker without sending input or reading live CWD. Route document and group Save
correctly. Save As uses one per-window native sheet and never reads the store
directly. A successful Save As renames only its target group. Menus and palette
use the same action and validation. Block all group shortcuts behind a save
sheet, folder picker, or close confirmation. Preserve Command-W and every
current shortcut outside the exact Terminal Group context.

Add all focused tests and run the named read-only regressions. Use one SwiftPM
invocation at a time. Isolate failures and never edit an unowned failure.

Set this plan's Status to `Implemented on lane; awaiting authorized merge` and
complete all tracked changes and the implementation record before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
The last command is the full parallel suite. Nothing may modify a tracked file
after it. Under the GUI lease, run Rafu Lightning and the complete TG-41
shortcut/save matrix or report exact deferrals. Run `git diff --check`.

Stage only TG-41 paths and create one intentional local commit. This prompt
authorizes that commit only. Do not push, merge, open a PR, publish, release,
or edit main. Confirm clean status, record branch, commit message, and SHA,
then remove only this worktree's `.build` as the last filesystem step.

Report shortcut matrix, menu/palette parity, Save/Save As behavior,
accessibility/manual evidence, paths, focused/full tests, warnings, risks,
reference need, branch, commit message, SHA, and next dependency. Include
Deviations with `None` when none. Complete the Goal only after commit and full
handoff.
```
