# WP-30 — Terminal manager presentation and current-session state

## Status and execution slot

- **Status:** Implemented on `codex/presentation-terminal-manager` (2026-07-29);
  local commit and verification evidence are recorded in the worktree handoff.
- **Wave:** 1; parallel.
- **Suggested branch:** `codex/presentation-terminal-manager`.
- **Recommended model:** `gpt-5.6-sol` with high reasoning.
- **Required base:** exact `<FOUNDATION_SHA>`.
- **Merge round:** before WP-40.

## Goal

Give the terminal manager one compact header, an adaptive provider launcher, and
clear session rows whose unique current state follows the focused visible
terminal. Consume the same identity/border resolver as the editor tile without
changing shell processes, attention behavior, hide/close semantics, or session
lifetime.

## Required reading and skills

Read:

- `AGENTS.md`
- [`README.md`](README.md)
- [`WP-00-foundation.md`](WP-00-foundation.md)
- [`../pre-initial-push-workbench.md`](../pre-initial-push-workbench.md)
- parent plan sections C, D/Terminals, P2, verification, and risks
- ADR 0004, ADR 0014, ADR 0016, and ADR 0022
- `docs/plans/phases/terminal-manager.md`
- `docs/references/terminal-signals-and-shell-catalog.md`
- `docs/references/editor-window-close-resolution-order.md`
- `docs/references/skill-routing.md`

Use `swiftui-expert-skill` with latest APIs, layout, lists, focus,
accessibility, and macOS views. Use Build macOS Apps `swiftui-patterns`.
`WorkspaceSession` is `@MainActor`; if the work touches tasks, process I/O,
notifications, or cross-actor state rather than the planned read-only
presentation seam, stop and use the root `swift-concurrency-pro` review path.

## Exclusive ownership

Source:

- `Sources/RafuApp/Terminal/EditorTerminalTabContent.swift`
- `Sources/RafuApp/Terminal/TerminalSessionColor.swift`
- `Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift`
- `Sources/RafuApp/Models/WorkspaceSession.swift`

Tests:

- `Tests/RafuAppTests/TerminalEditorTabTests.swift`
- `Tests/RafuAppTests/TerminalIdentityTests.swift`
- `Tests/RafuAppTests/TerminalsPanelTests.swift`
- new `Tests/RafuAppTests/TerminalManagerPresentationTests.swift`

Documentation:

- this plan's implementation record
- one uniquely named reference note only for a genuinely new reusable terminal,
  actor, or accessibility nuance

Do not edit `EditorCanvasView.swift`, `TerminalsPanelModel.swift`,
`WorkspaceNavigatorView.swift`, any Conductor adapter/process file, WP-00
support files, `Package.*`, shared indexes, or another lane's files.

WP-00 must already have moved the editor-tab vendor-mark source contract out of
`TerminalsPanelTests.swift`. Stop if that ownership split is missing.

## Implementation

### T1. Expose exactly one current terminal

In `WorkspaceSession`, expose one read-only presentation value derived from the
existing focused group's selected terminal:

- it returns the visible terminal selected in the focused editor group;
- it returns no value when a document/diff/canvas is focused or no terminal is
  visible;
- it does not use `terminal.selectedID` as a second list selection;
- it adds no persisted state and no setter;
- reveal/focus remains the only way a click moves the current state.

Keep all topology, restoration, close, park, hide, attention, and process
methods unchanged.

### T2. Use one primary terminal header

Fold the existing terminal count header into WP-00's
`RafuUtilityPanelHeader`:

- one title, optional count/context, add action, and common close action;
- 34 pt default minimum, expanding for larger user text;
- no duplicate outer/inner noun;
- quick launches remain a real secondary section.

The panel must still build and remain operable on this branch before WP-40
removes the old outer utility header. Temporary duplicated chrome on this
isolated branch is acceptable; do not edit the outer host to hide it. WP-30
must supply the complete concrete header so the final WP-40 merge can remove
the compatibility header safely.

### T3. Replace the icon strip with an adaptive launcher

Use an adaptive grid of provider launch cells:

- 34 pt default minimum height, at least 86 pt wide, 6 pt spacing;
- icon plus one-line short display name;
- full provider name and readiness/reason in tooltip and accessibility label;
- explicit unavailable/loading reason, not opacity alone;
- larger text expands height or wraps within the documented cap;
- preserve probe, refresh, launch, model, auth, shortcut, and error behavior.

Do not change adapter discovery or start a probe from a view initializer.

### T4. Compact and clarify session rows

Make rows 48 pt minimum with 6 pt gaps and the parent plan's compact
title/caption/action hierarchy. Pass `isCurrent` from the session presentation
value and consume the shared `.managerRow(isCurrent:needsAttention:)` border
context.

Current, attention, identity, parked, running/exited, rename, and hover/menu
states remain separate:

- exactly one current row may use close-fit selected geometry and
  `.isSelected`;
- VoiceOver value includes **Current terminal** on that row;
- a background row never looks selected merely because
  `terminal.selectedID` points to it;
- attention includes text/icon as well as stronger structure;
- neutral structure survives a custom identity equal to the row background;
- color remains supplemental to provider/name/status.

Preserve reveal, rename, color, hide, close, close-all, menus, and attention
counts.

### T5. Keep the SwiftTerm body presentation-free

Verify `EditorTerminalTabContent` remains the one SwiftTerm body host and does
not acquire:

- a second border;
- an inset around the text viewport;
- a corner mask/clip;
- a new focus or generation owner.

Edit it only to remove an existing duplicate presentation that would violate
the WP-00/WP-20 group-owned contract. Do not change process, responder, theme,
exit, or teardown behavior.

`TerminalSessionColor` retains preset/custom encoding and storage behavior. Add
only a pure presentation seam if required to consume the foundation resolver.

### T6. Tests

Pin:

- current-session derivation for file, no focus, one terminal, two terminal
  groups, parked, hidden, exited, and focus switches;
- exactly one current row and no `selectedID` visual state;
- separate current/attention/status/parked/identity inputs;
- adaptive launcher cells include visible short name, full help, accessible
  readiness/reason in probing/ready/unavailable states;
- neutral edge survives a background-matching custom color;
- no real shell/SwiftTerm mount in unit tests;
- existing reveal/hide/close/rename/color/attention/lifetime behavior.

## Acceptance and manual evidence

Focused checks:

```bash
./script/test.sh --filter \
  'TerminalsPanel|TerminalAttention|TerminalIdentity|TerminalEditorTab|TerminalManagerPresentation'
```

With the GUI lease, verify utility widths 250, 310, and 460 pt; all providers;
empty, one-session, and four-session lists; current/background/attention/
exited/parked/uncolored states; and a focus switch between two visible terminal
groups. Exactly one row must update immediately.

Complete keyboard-only launch, reveal, rename, color, hide, and close. VoiceOver
must announce provider, readiness/reason, current terminal, status, parked, and
attention without hue. Exercise provider cells and terminal rows in
rest/hover/pressed/selected/current/disabled states, including unavailable
providers, and confirm shape/text communicate the state without hue. Capture
Indigo, Khadi, converged surfaces, Increase Contrast, and default plus largest
supported accessibility text sizes.

## Verification and handoff

Finish all edits and documentation before:

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
```

Use only the Rafu Lightning GUI lease, or list deferred checks for the
coordinator. Commit only owned paths, do not push, and remove `.build` after the
green commit.

## Implementation record

- `WorkspaceSession.currentTerminalSessionID` is a read-only presentation seam
  derived from the focused editor group's visible selected terminal. It adds no
  persisted state or setter and deliberately ignores `terminal.selectedID`.
- The terminal manager now supplies its complete shared utility header,
  adaptive named provider cells, and 48 pt session rows. Current, attention,
  identity, status, and parking feed independent presentation inputs through
  WP-00's manager-row resolver.
- Focused coverage pins file/no-focus, one-terminal, two-group focus switching,
  parked/hidden, exited, non-editor canvas, exactly-one-current, launcher state,
  neutral-edge collision, lifecycle regressions, and the unclipped SwiftTerm
  body contract without mounting a shell.
- Probe, launch/model/auth/error, reveal, rename, color, hide, close, close-all,
  attention, process, responder, exit, and teardown implementations were not
  changed. `EditorTerminalTabContent` and `TerminalSessionColor` required no
  edits.
- No new reusable platform, SDK, actor, lifecycle, security, or accessibility
  nuance was discovered, so no ADR, reference note, or reference-index row is
  required.
- The single Rafu Lightning GUI lease was not held in this parallel worktree.
  The coordinator's merge-round lease retains the complete manual matrix:
  `build_and_run.sh --verify`; widths 250/310/460 pt; all provider and
  empty/one/four-session states; current/background/attention/exited/parked/
  uncolored rows; immediate unique current-row focus switching; keyboard-only
  launch/reveal/rename/color/hide/close; VoiceOver provider/readiness/reason/
  current/status/parked/attention announcements; rest/hover/pressed/current/
  disabled states; and Indigo, Khadi, converged surfaces, Increase Contrast,
  default text, and largest supported accessibility text.

## Goal-mode start prompt

```text
First call `create_goal` with the following objective and do not include a
`token_budget` key:
"Implement WP-30's compact terminal manager and unique focused-terminal current
row using Rafu's shared presentation contract, preserving every terminal
lifecycle and attention behavior; verify and commit it locally."

You are in the dedicated worktree on branch
codex/presentation-terminal-manager. Use gpt-5.6-sol with high reasoning.

Read AGENTS.md; the workbench presentation execution README; WP-00; WP-30;
pre-initial-push-workbench.md; the parent plan sections named by WP-30; ADRs
0004, 0014, 0016, and 0022; terminal-manager.md;
terminal-signals-and-shell-catalog.md;
editor-window-close-resolution-order.md; and skill-routing.md. Use
swiftui-expert-skill and macOS swiftui-patterns. If you cross into async,
process, notification, or cross-actor behavior, stop and take the root
swift-concurrency-pro review path.

Run `git status --short --branch`. Stop unless the branch is
codex/presentation-terminal-manager, the tree is clean, the initial
`git rev-parse HEAD` equals the coordinator-supplied exact `<FOUNDATION_SHA>`,
WP-00 is present, and the test-ownership split named by WP-30 has landed. Touch
only WP-30-owned paths. Never edit EditorCanvasView, WorkspaceNavigatorView,
adapters, shared styles, Package.swift, or shared indexes.

Add one read-only current-terminal presentation seam derived from the focused
visible group. Build the concrete terminal header, adaptive named launcher, and
48 pt session rows. Consume the shared manager-row resolver. Keep current,
attention, identity, status, and parking separate. Preserve all probe,
reveal/rename/color/hide/close, process, responder, exit, and teardown behavior.
Keep EditorTerminalTabContent body-only and unclipped.

Add the exact focused tests and manual/accessibility states in WP-30. Use the
single Rafu Lightning GUI lease or hand off the named deferred checks.

Complete all edits before:
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh
Nothing may change afterward. When holding the single GUI lease, run
`./script/build_and_run.sh --verify` and complete the manual matrix; otherwise
report the exact deferral. Stage only owned paths and create one local commit.
Do not push, merge, open a PR, or publish. After green gates and the successful
commit, remove only this dedicated worktree's `.build`; never remove the
primary checkout's cache. Report delivered behavior, SHA, paths, gate results,
current-row cases, manual/theme/VoiceOver evidence, lifecycle preservation,
ADR/reference updates, deferred checks, risks, any intended reference-index
row, and the next dependency (merge WP-30 before WP-40). Complete the Goal only
after commit and handoff.
```
