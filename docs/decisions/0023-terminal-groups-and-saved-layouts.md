# ADR 0023: Terminal Groups and saved layouts

- **Status:** Accepted
- **Date:** 2026-08-16

## Context

Rafu already provides lazy, bounded terminal sessions as editor-tab peers. A
session can be parked, revealed, closed, and observed in the Terminal Manager.
That model does not let one task use a named compound tab with several terminal
panes, or save a safe reusable layout without restoring a process.

The user directed Rafu to add a Terminal Group. This supersedes only the
terminal-presentation, restoration, start-directory, and capacity details named
below. It does not change the shell safety boundary, Agent Terminal boundary, or
Ensemble trust boundary.

## Decision

### Product terms and interaction

- A **Terminal Group** is one editor tab that owns one recursive tree of
  terminal panes. A **terminal pane** is one leaf in that tree. A **terminal
  session** is one live or exited controller that can back one pane.
- **Split Right** adds a pane to the right of the focused pane. **Split Down**
  adds a pane below it. Do not use “vertical split” in product text.
- `Command-T` creates a new one-pane group outside a group. Inside a group, it
  performs Split Right; the new pane starts the preferred shell and gets focus.
  `Shift-Command-T` performs Split Down only in the selected group.
  `Control-Shift-backtick` always creates a new one-pane group.
- `Control-Command-Left`, `Right`, `Up`, and `Down` move focus to the nearest
  pane in that direction. Focus does not wrap or move a pane. Pointer focus
  updates the same focused-pane identity. Do not assign `Option-Command-Up` or
  `Option-Command-Down`; editor multi-caret actions own those shortcuts.
- A group starts with the unique default name `Terminal Group N`. The user can
  rename it by double-clicking the tab or through **Rename Terminal Group…**.
- `Command-S` saves the selected Terminal Group. `Shift-Command-S` uses **Save
  Terminal Group As…**. A successful Save As renames the open group to the
  validated saved-layout name. File-tab Save behavior does not change.
- `Control-backtick` parks the selected group. Otherwise it reveals the most
  recently parked group. When no group is parked, it creates a new one-pane
  group. `Control-Tab` lists one group once, not once per pane.
- **Set Pane Starting Folder…** selects an in-workspace folder only for a
  future user-requested start. It never sends `cd` to a running shell. A split
  inherits a restartable focused pane’s stored folder; otherwise it uses the
  workspace root. Rafu resolves symlinks, rejects an escape, and revalidates
  before each start. An observed live working directory stays live-only.
- A group save sheet, pane-folder picker, or group-close confirmation owns its
  window until it completes. Terminal Group shortcuts do not mutate the group
  or editor layout behind that modal request.

### Layout, identity, and limits

- `TerminalGroupID`, `TerminalPaneID`, and split IDs are stable runtime IDs.
  A session UUID occurs in at most one pane. Each group stores one focused pane
  ID. Right and down splits form one recursive binary tree. Closing a leaf
  removes its parent split and promotes the sibling. Closing the last pane
  closes the group.
- Divider fractions are normalized. The default and invalid fallback are `0.5`.
  A minimum pane size can temporarily override a saved fraction.
- A group has at most six retained panes. A window has at most 24 retained
  panes across open and parked groups. A retained pane is live, exited, stopped,
  or unavailable. These are separate from the six-live-session window limit.
- The six-live-session window limit includes ordinary shells, Agent Terminals,
  Ensemble coordinator terminals, and Ensemble role terminals. A **live
  session** is a controller committed for a user-requested launch until its
  child process exits, including the short lazy interval before its SwiftTerm
  view mounts and starts the child process. A **reserved slot** exists only
  during a validated multi-start transaction; it is not a session, live
  process, or UI item. A **live process** is a child process that has not exited.
- New Group, Split, and Open Saved Group reject an operation that exceeds a
  retained-pane limit without changing groups, tabs, controllers, or processes.
  Start All validates folders, shells, and capacity before it reserves or
  starts a process. A preflight failure starts zero processes. A later external
  spawn or shell-start failure is an honest result for that pane and does not
  undo another pane’s external side effect.

### Saved layouts and restoration

A **Saved Terminal Group** is versioned workspace-local application metadata.
It is not a terminal-session or process snapshot. `SavedTerminalGroupID` and
record-local saved pane and split IDs are distinct from runtime group, pane,
split, and session IDs. Opening the same saved layout more than once creates
fresh runtime IDs for every opening.

Saved data may contain only:

- schema version and an opaque workspace key derived from the standardized
  workspace root, never the raw root;
- saved-layout ID, group name, record-local pane and split IDs, recursive
  topology, normalized divider fractions, and focused pane;
- an explicit user pane name and theme-token color when set;
- one fixed saved-pane kind: ordinary shell, unavailable Agent Terminal, or
  unavailable Ensemble terminal;
- an approved ordinary-shell profile and an explicit workspace-relative pane
  starting folder; and
- inert outer editor-tab placement for workspace restoration.

Saved data must never contain a PID, PTY, controller, session UUID, output,
screen, scrollback, transcript, history, command, process tree, environment,
credential, token, notification reply ID, Ensemble capability,
`TerminalProcessSpec`, observed working directory, raw absolute workspace path,
absolute child path, OSC title, computed display name, provider or model
identity, runtime error text, arbitrary unavailable reason, or named-layout
runtime IDs.

Open and window restoration create inert stopped or unavailable placeholders.
They create no controller, SwiftTerm view, PTY, child process, reservation, or
Process Resources registration. The user must select **Start Pane** or **Start
All Restartable Panes**. Only ordinary shell profiles restart in v1. Agent
Terminal and Ensemble panes restore only as fixed unavailable placeholders;
they contain no launch descriptor or Ensemble capability. The fixed messages
are `Agent Terminal profiles are not saved in this version.` and `Ensemble
terminal profiles are not saved in this version.`

**Start All Restartable Panes** targets stopped ordinary-shell panes only. It
leaves unavailable Agent Terminal and Ensemble placeholders unchanged.

### Lifecycle and safety boundary

- Every live pane still uses one existing `WorkspaceTerminalController`, one
  PTY, and one SwiftTerm view. Spawn remains lazy and only follows a visible,
  explicit user action. Scrollback remains bounded.
- Rafu has no task runner, command block, shell command injection, or automatic
  command execution. It embeds no agent and stores no agent credential.
- Hiding a group keeps its live sessions alive. Revealing an attention, Agent
  Terminal, or Ensemble session reveals its group and focuses its exact pane.
  Closing a pane ends only that pane’s session. Closing a group counts its live
  processes, confirms once when needed, then prepares, cleans up, and finalizes
  every affected child session. A stale confirmation does nothing.
- Naturally exited sessions remain exited panes with Restart and Close actions.
  Exited panes count toward the 24-retained-pane limit. Workspace switch,
  window close, and app quit end all live sessions owned by that window. One
  window cannot read or mutate another window’s groups.

## Superseded guidance

This ADR supersedes only these earlier statements:

- ADR 0004’s workspace-root-only start directory, bottom-panel/controller-only
  presentation, one-controller-per-panel-tab model, and session-level
  `Control-backtick` and tab-close rules, including its 2026-07-21 amendment.
- ADR 0014’s one-session-per-terminal-tab presentation, session-level parking,
  no-layout-restoration rule, and one-session terminal-tab close rule. Legacy
  `EditorTabResource.terminal(sessionID:)` remains decodable during migration;
  a decode failure must not erase the complete restoration payload.
- `terminal-manager.md`’s v1 non-goal for splits inside one tab, its
  session-level toggle and MRU rules, its one-session close rule, and its
  unbounded exited-session trade-off.
- ADR 0018’s statement that the workspace UserDefaults restoration schema is
  untouched, and its terminal-cap wording. The Ensemble still never restores a
  live role session.

## Consequences

- Terminal Groups are the current terminal-layout contract. Their staged
  implementation is in [`terminal-groups.md`](../plans/phases/terminal-groups.md).
- Existing direct manager entry points remain temporary adapters while callers
  move to group ownership. `WorkspaceSession.revealTerminalSession(_:)` remains
  available for attention, Agent Terminal, and Ensemble callers.
- A deleted named layout does not close an open group. It makes each open group
  for that layout unsaved; the group will not restore until the user saves it
  again.
- The new state adds no process persistence, command execution path, Agent
  launch profile, or Ensemble capability persistence.

## Alternatives considered

- **Persist and restore live terminals.** Rejected. A live process, its PTY,
  output, environment, and capability state are not safe restoration data.
- **Save Agent or Ensemble launch descriptors.** Rejected. It would weaken ADR
  0021’s tokenless interactive boundary and ADR 0018’s delegated-auth and
  memory-only capability boundary.
- **Build a separate group terminal engine.** Rejected. The existing bounded
  controller, PTY, and SwiftTerm boundary remains the one terminal engine.

## Revisit trigger

Revisit this decision before adding process survival across relaunch, remote
terminal profiles, task execution, pane drag or reorder, cross-workspace saved
layouts, more than six panes per group, more than 24 retained panes per window,
more than six live sessions per window, a saved Agent profile, or a saved
Ensemble profile or capability.

## Related

- [ADR 0004](0004-embedded-terminal.md)
- [ADR 0014](0014-terminal-as-editor-tab.md)
- [ADR 0018](0018-conductor-external-agent-orchestration.md)
- [ADR 0021](0021-agent-terminals.md)
- [`terminal-groups.md`](../plans/phases/terminal-groups.md)
