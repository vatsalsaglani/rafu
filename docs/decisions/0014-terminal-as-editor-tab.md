# ADR 0014: Terminal sessions as editor-tab peers

- **Status:** Proposed
- **Date:** 2026-07-19

## Context

ADR 0004 placed the embedded terminal as a bottom panel of the editor area
(a `VSplitView` panel with its own tab strip). During the 2026-07-19
UI-issue-fix batch (issue #4 of `docs/issues/issues_ui.md`), the user asked
for a terminal session to also be presented as a first-class **editor tab**
— a peer of file tabs in the same tab strip/split machinery — rather than
being confined to the bottom panel. This is the placement change anticipated
by [`editor-terminal-tabs.md`](../plans/phases/editor-terminal-tabs.md)'s
increment T1, landed narrower than that phase's full T1–T4 scope: only tab
placement shipped in this batch, not the cwd-aware spawn helpers, attention
dots, session-move commands (T3), or ADR-anticipated placeholder restoration
(T2/TD4).

## Decision

- `EditorLayout` gains a terminal tab resource (`EditorTabResource.terminal`)
  that participates in the same tab chrome, switching, and drag/drop as file
  tabs.
- Terminal tabs are **ephemeral**: they are **not** restored across an app
  relaunch, unlike file tabs and splits. This is narrower than the T2
  "inert placeholder + Start Shell button" restoration design sketched in
  `editor-terminal-tabs.md` — that richer restoration behavior remains
  future scope (TD4 still open), not implemented here.
- The underlying `WorkspaceTerminalController`/`WorkspaceTerminalManager`
  engine, lazy spawn, bounded scrollback, per-window ownership, and
  workspace-switch teardown from ADR 0004 are unchanged — only the tab's
  *placement* (panel vs. editor tab) is new.

## Alternatives considered

- **Keep the terminal panel-only** (status quo). Rejected — the user
  explicitly asked for tab placement so a terminal session can sit beside
  file tabs in a split, matching the "agent in one tab, its diff in the
  next" workflow `editor-terminal-tabs.md` describes.
- **Ship the full T1–T4 scope in this batch** (placeholder restoration,
  attention dots, session-move commands, hibernation-exemption cap).
  Rejected for this batch — the issue-fix batch scoped only the tab
  placement change (issue #4); the richer lifecycle policy remains the
  dedicated `editor-terminal-tabs.md` phase's job.

## Consequences

- Supersedes ADR 0004's "bottom panel" placement boundary for terminal
  presentation; every other ADR 0004 bound (lazy spawn, bounded scrollback,
  no task runners, no automatic command execution, per-window ownership)
  still applies unchanged.
- Because terminal tabs are ephemeral, a user who relies on a terminal tab's
  layout position across relaunches loses it — this is an explicit,
  documented trade-off pending the T2 restoration design, not a bug.
- `editor-terminal-tabs.md` remains the owning phase document for T2–T4
  (lifecycle policy, agent-workflow polish, cap/measurement close-out); this
  ADR should be revisited (or superseded) if that phase changes the
  restoration or cap decisions it currently leaves open (TD1–TD4).

## Revisit trigger

When `editor-terminal-tabs.md`'s T2 (lifecycle policy, including placeholder
restoration) lands, update this ADR's restoration statement or supersede it
rather than silently changing behavior against this record.

## Related plan, reference, and implementation paths

- Plan: [`editor-terminal-tabs.md`](../plans/phases/editor-terminal-tabs.md)
- Superseded boundary: [`0004-embedded-terminal.md`](0004-embedded-terminal.md)
- `Sources/RafuApp/Models/WorkspaceSession.swift`
- `Sources/RafuApp/Editor/EditorLayout.swift`
- `Tests/RafuAppTests/TerminalEditorTabTests.swift`
- `Tests/RafuAppTests/EditorLayoutTests.swift`
