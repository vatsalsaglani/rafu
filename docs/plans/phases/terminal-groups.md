# Terminal Groups — compound terminal tabs and saved layouts

## Status

In Progress on 2026-08-16 after ADR 0023 acceptance and ADR 0024 limits. This document defines
product scope and acceptance. TG-00 is complete on its lane; TG-10 is next
after an authorized merge. The worktree execution contract is in
[`terminal-groups/README.md`](terminal-groups/README.md).

The user asked for one terminal group to appear as one editor tab, with more
terminal panes added by keyboard, directional pane focus, a group name, and a
safe saved layout. This direction reverses the v1 non-goal for terminal splits
in [`terminal-manager.md`](terminal-manager.md). TG-00 records the reversal in
ADR 0023 before source work starts.

## Product outcome

A user can keep one task in one named **Terminal Group** tab. The tab can hold
one or more **terminal panes** in a recursive split layout. Each live pane owns
one existing `WorkspaceTerminalController`, one PTY, and one SwiftTerm view.
The group does not mirror a session and does not add a second terminal engine.

The feature keeps Rafu's terminal limits:

- A process starts only after a visible user action.
- Restoration never starts a process.
- Scrollback stays bounded.
- There is no task runner, command block, or automatic command execution.
- Workspace switch, window close, and app quit end all live sessions owned by
  that window.
- Rafu embeds no agent and stores no agent credential.

## Terms

- **Terminal Group:** one editor tab and one recursive pane tree.
- **Terminal pane:** one leaf in the group tree.
- **Terminal session:** one live or exited controller that can back one pane.
- **Saved Terminal Group:** a versioned metadata record. It is not a process
  snapshot.
- **Inert:** no controller, SwiftTerm view, PTY, child process, reserved
  capacity slot, or Process Resources registration exists.
- **Live terminal session:** a controller committed for a user-requested launch
  that has not naturally exited. It includes the short lazy interval before
  its SwiftTerm view mounts and starts the child process.
- **Reserved slot:** temporary capacity held during validated multi-start. It
  is not a session and does not appear in the UI.
- **Retained terminal pane:** any live, exited, stopped, or unavailable pane
  in an open or parked group. One window retains at most 24 terminal panes.
- **Live process:** a child process that has not exited. Close confirmation
  counts live processes, not exited panes, attention, or reserved slots.
- **Split Right:** add a pane on the right of the focused pane.
- **Split Down:** add a pane below the focused pane.

Do not use **vertical split** in product text. It can mean a vertical divider or
a vertical pane stack.

## Locked interaction contract

1. `Command-T` outside a Terminal Group opens a new one-pane group and uses
   the current safe terminal start-directory policy: the selected in-workspace
   file's directory, or the workspace root when there is no such file.
2. `Command-T` inside a Terminal Group performs **Split Right** from the
   focused pane. The new pane starts the preferred shell and gets focus.
3. `Shift-Command-T` performs **Split Down** only when a Terminal Group is the
   selected tab. It does not replace a future Reopen Closed Tab command outside
   this context.
4. `Control-Command-Left/Right/Up/Down` focuses the nearest pane in that
   direction. Focus does not wrap and does not move a pane.
5. Pointer focus updates the same focused-pane identity that keyboard commands
   use. Only the focused pane can request first responder when the group mounts.
6. A group starts with the unique default name `Terminal Group N`. The tab
   supports double-click rename. Menus and the command palette provide
   **Rename Terminal Group…**.
7. `Command-S` saves the selected Terminal Group. The first save uses the group
   name. `Shift-Command-S` provides **Save Terminal Group As…**. File-tab Save
   behavior does not change. A successful Save As also renames that open group
   to the validated saved-layout name.
8. `Control-backtick` hides or reveals the complete group. Hiding keeps all
   live sessions alive.
9. `Command-W` closes the complete group tab. If it has live processes, Rafu
   shows one confirmation with the live-process count.
10. A pane close action ends only that pane's session and collapses the
    redundant split. Closing the last pane closes the group.
11. A naturally exited session stays as an exited pane with Restart and Close
    actions.
12. `Control-Tab` lists one Terminal Group once. Pane movement stays with the
    directional focus commands.
13. `Control-Shift-backtick` always creates a new one-pane Terminal Group. The
    always-available **New Terminal Group** menu and palette action use the
    same route. `Command-T` remains contextual.
14. `Control-backtick` parks the selected Terminal Group. From another tab, it
    reveals the most recently parked group. If none is parked, it creates a
    new one-pane group.
15. **Set Pane Starting Folder…** lets the user choose a folder inside the
    workspace. It changes the pane's safe future-start profile; it does not
    send `cd` to a running shell. A split inherits the focused restartable
    pane's stored starting folder. A split from a nonrestartable pane uses the
    workspace root. Resolve symlinks and reject a folder that escapes the
    workspace. Revalidate before every start. Rafu never observes a live
    working directory for this.
16. A group save sheet, pane-folder picker, or group-close confirmation owns
    its window until it completes. Terminal Group shortcuts do not mutate the
    group or editor layout behind that modal request.

## Group layout and identity

- A stable `TerminalGroupID` identifies the outer tab resource.
- A stable `TerminalPaneID` identifies a leaf. It is not a session UUID.
- A stable split ID identifies each internal divider.
- One session UUID can occur in at most one pane.
- The group stores one focused pane ID.
- One group contains at most six panes, including stopped, exited, and
  unavailable panes. This bound is separate from the window's live-session
  limit.
- One window retains at most 24 terminal panes across open and parked groups.
  New, Split, and Open Saved Group reject an operation that would exceed this
  bound without changing groups, tabs, controllers, or processes.
- Right and down splits form one recursive binary tree. Closing a leaf removes
  the leaf and its parent split, then promotes the sibling.
- Divider fractions use a normalized value and restore when valid. The renderer
  uses a narrow `NSSplitView` bridge because the current SwiftUI split path does
  not report divider changes.
- The default fraction is `0.5`. Invalid or unsupported fractions fall back to
  `0.5`; minimum pane size can temporarily override a saved fraction.

## Safe save and restoration contract

Saved groups are workspace-local application data below Rafu's Application
Support root. They are not written into the repository.

Named saved layouts and open-tab restoration use different identities.
`SavedTerminalGroupID` identifies one reusable named layout. A named record
uses record-local saved pane and split IDs and never stores runtime IDs.
Opening the same saved layout more than once is allowed. Each opening creates
fresh runtime group, pane, and split IDs. A window-restoration snapshot can
retain the runtime IDs for one specific open tab because each instance already
has unique IDs.

Save only:

- schema version;
- an opaque workspace key derived from the standardized workspace root, never
  the raw absolute root;
- saved-layout ID and group name;
- record-local saved pane and split IDs;
- recursive topology and normalized divider fractions;
- explicit user pane name and theme-token color, when set;
- one fixed saved-pane kind: ordinary shell, unavailable Agent Terminal, or
  unavailable Ensemble terminal;
- an approved ordinary-shell profile;
- its explicit, workspace-relative starting folder;
- focused pane;
- inert outer editor-tab placement for workspace restoration.

Never save:

- PID, PTY, controller, or live session UUID;
- terminal output, screen state, scrollback, transcript, or history;
- current command or process tree;
- environment values;
- credentials, tokens, notification reply IDs, or Ensemble capability;
- `TerminalProcessSpec`;
- an automatically observed live working directory;
- the raw absolute workspace root or an absolute child folder;
- an OSC-reported terminal title or computed display name;
- provider/model identity, runtime error text, or an arbitrary unavailable
  label/reason; or
- named-layout runtime group, pane, split, or session IDs.

Opening a saved group creates stopped placeholders with fresh runtime IDs. The
user must select **Start Pane** or **Start All Restartable Panes**. Start All
targets stopped ordinary-shell panes only and leaves unavailable Agent and
Ensemble placeholders unchanged. It validates all target folders, shells, and
capacity before it reserves or starts a process. A preflight failure starts
zero processes. After preflight, normal lazy view mounting starts each target.
A later external spawn or shell startup failure becomes that pane's exited or
error result and does not stop other panes. Rafu does not claim that it can
undo external process side effects. A missing shell or folder produces an
exact error. Rafu does not silently choose a substitute.

Only ordinary shell profiles are restartable in v1. A direct Agent Terminal or
an Ensemble terminal can appear in a live Terminal Group, but its saved pane is
an unavailable placeholder. Rafu saves no Agent or Ensemble launch descriptor
in v1. This preserves ADR 0021's ephemeral Agent Terminal rule and ADR 0018's
capability boundary. The unavailable UI text is derived from the fixed
saved-pane kind. The exact messages are
`Agent Terminal profiles are not saved in this version.` and
`Ensemble terminal profiles are not saved in this version.` They are not
persisted free-form text.

## Lifecycle and resource contract

- The maximum is 200 live terminal sessions per workspace window, across
  ordinary shells, Agent Terminals, Ensemble coordinator terminals, and
  Ensemble role terminals.
- Every creation path must use one capacity preflight. A rejected multi-start
  starts zero sessions.
- Stopped placeholders and exited panes do not count as live sessions.
- The 200-retained-pane window bound counts live, exited, stopped, and
  unavailable panes. It is independent from the 10-pane group bound and the
  200-live-session window bound. A window contains at most 20 groups.
- A capacity reservation counts only while one validated start transaction is
  in progress. It cannot be shown as a pane or counted as a live process.
- Hiding a group keeps its sessions alive and records group-level MRU order.
- Revealing a session used by attention, Agent Terminal, or Ensemble code must
  reveal its group and focus its exact pane.
- Closing a group reports the actual live-process count, ends every live child
  session, and performs the existing
  coordinator or Ensemble cleanup for each affected session.
- Close confirmation revalidates the affected sessions and live-process count
  before cleanup. A stale confirmation performs no cleanup or mutation.
- One window cannot read or mutate another window's groups.
- No restored placeholder registers with `ProcessResourceRegistry`.
- Terminal output remains bounded to the existing SwiftTerm scrollback limit.

## Presentation contract

- The editor tab shows the group name, a terminal-group glyph, the total pane
  count when greater than one, and aggregate attention.
- Each pane keeps its own name, status, color, directory, provider identity,
  close action, restart action, and attention state.
- The Terminal Manager shows a group row with child pane rows. A pane row
  reveals the group and focuses that pane. Group actions include Rename, Save,
  Hide Group, Close Group, and Start All Restartable Panes when stopped
  ordinary-shell placeholders exist.
- A saved-layout section provides Open and Delete actions with full keyboard
  and accessibility paths.
- Color is supplemental. Labels, glyphs, state text, focus, and attention must
  remain clear without hue.
- Pane focus and tab changes are immediate. Do not add decorative motion.

## Compatibility contract

- `EditorTabResource.terminal(sessionID:)` remains decodable during migration.
  A decode failure must not clear the complete workspace restoration payload.
- New presentation uses `EditorTabResource.terminalGroup(groupID:)`.
- `WorkspaceSession.revealTerminalSession(_:)` remains available because
  attention, Agent Terminal, and Ensemble callers use it.
- Existing direct manager entry points remain as temporary adapters until all
  callers move to the aggregate API. TG-90 removes only adapters that have no
  callers.
- Existing file tabs, editor group drag and drop, `Command-W`, file Save, and
  document restoration keep their behavior.
- Deleting a named saved layout does not close an open group. Every open group
  in every window for that workspace that refers to it becomes unsaved and
  will not restore unless the user saves it again.

## Acceptance contract

1. One Terminal Group is one editor tab in the tab strip and in Control-Tab.
2. `Command-T` opens a group or splits right, based on selected-tab context.
3. `Shift-Command-T` splits down only in an active group.
4. `Control-Command-Arrow` and pointer clicks keep one correct focused pane.
5. Right, down, mixed, and nested split trees render and collapse correctly.
6. Rename, Set Pane Starting Folder, Save, Save As, Open Saved Group, Delete
   Saved Group, Start Pane, and Start All Restartable Panes have visible,
   menu, keyboard, and accessibility paths.
7. Restoration creates no process and stores none of the prohibited data.
8. The 10-pane group bound, 200-retained-pane window bound, and 200-live-session
   window bound are independent. A window contains at most 20 groups. A rejected New, Split, Open, capacity, or
   Start All preflight changes no state and starts zero processes. A later
   external failure uses the documented per-pane result.
9. Hide/reveal, pane close, group close, workspace switch, window close, and app
   quit keep the lifecycle contract.
10. Direct Agent and Ensemble sessions work live, but restore only as
    unavailable placeholders without capability data.
11. The Terminal Manager, attention surfaces, Resources, and group tab remain
    consistent for the same sessions.
12. Two windows keep independent runtime groups and safely share named-layout
    updates for the same workspace.
13. VoiceOver, Full Keyboard Access, Increase Contrast, Reduce Motion, Reduce
    Transparency, and larger text keep all actions and state readable.
14. Release measurements record memory and typing behavior with 1, 4, and 6
    visible active panes, plus memory and zero-process evidence for 24 inert
    retained panes.
15. The same named layout can open twice without a shared runtime ID, focus,
    expansion state, or session.
16. Save, folder-picker, and close-confirmation modal states block all group
    shortcuts from changing covered state.

## Explicit non-goals

- tmux or process survival across app relaunch;
- SSH terminal profiles;
- task runners, command blocks, or shell command injection;
- terminal output persistence;
- pane drag and drop or pane reorder in v1;
- cross-workspace saved-layout sharing;
- saved Agent Terminal launch profiles;
- saved Ensemble launch profiles or capability;
- session mirroring;
- more than six panes in one group;
- more than 24 retained terminal panes in one window; and
- more than six live terminal sessions in one window.

## Execution

Use the plans in [`terminal-groups/README.md`](terminal-groups/README.md):

- TG-00 records the durable product decision.
- TG-10 lands shared source contracts without behavior change.
- TG-20, TG-21, and TG-22 form the first parallel wave.
- TG-30 performs the serial workspace cutover.
- TG-40, TG-41, and TG-42 form the second parallel wave.
- TG-90 performs integration, security review, measurement, and documentation
  close-out.

No implementation worktree may start from an uncommitted plan set or a moving
branch name. The execution README defines exact SHA and merge rules.
