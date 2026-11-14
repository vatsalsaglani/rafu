# ADR 0025: Workspace Canvas and app previews

- Status: Accepted by the user's implementation direction, 2026-10-17.
- Scope: Optional local-workspace Canvas alongside file and Terminal Group tabs.
- Execution: One agent, sequential C0–C5 stages, local commits only.

## Decision

A Canvas is a named, typed editor resource owned by one workspace window. It
contains bounded file and image references, native notes, Terminal Group
references, explicit local web previews, native app references and optional
selected-window previews, and labeled relationships. Relationships execute no
commands or workflows. Existing Settings and Ensemble tabs keep their current
window-only behavior. Canvas does not replace the editor or the Ensemble graph.

This narrowly extends ADR 0002's editor-hosted surfaces. It permits bounded
WebKit use for a user-connected loopback web application only. ADR 0019 and
0020 keep document/media/Markdown/Mermaid rendering native. No extension host,
embedded coding agent, task runner, or inference credential authority is added.

Amendment (2026-11-07, [ADR 0035](0035-voice-through-gpt-live.md)): Ensemble
agents never receive Rafu-held credentials; Rafu features may use the user's
provider key from Keychain. Rafu Voice is such a feature: it reads the OpenAI
key into one request header and acts on boards only through the same undoable
board tools, marked "Rafu (voice)".

Native app cards use public NSWorkspace activation and ScreenCaptureKit's
single-window system picker. Captured frames are temporary, local previews.
Keyboard and pointer input belong to the actual app after Open App. No foreign
NSView embedding, private window APIs, synthetic input, Accessibility grant,
recording, audio capture, OCR, or agent transmission is part of this decision.
A closed or unavailable source returns to a useful app-reference card.

Terminal Groups retain one runtime owner, controller, and PTY. A presentation
lease permits one visible host at a time across its regular tab and Canvas.
Transfers invalidate old focus requests. Board zoom never repeatedly resizes
PTYs. Existing explicit start/close rules and ADR 0024's independent capacities
remain authoritative; a Canvas does not add another process allowance.

Live notes remain in native text storage. Observation carries small metadata.
A bounded text snapshot is taken for atomic save/recovery. Workspace-keyed
Application Support holds Canvas files, with expected-version checks and
cross-window conflict handling. Source files are never written by card removal.
Saved boards restore inertly: no process, browser load, app launch, capture, or
permission grant. Persist no terminal output, prompt, environment, command,
cookie, token, PID, foreign window ID, or captured frame.

The user's 2026-10-18 input correction changes card activation: a single click
focuses content inside the card, without replacing the board.
Command/Shift-click retains board selection;
dragging a header or summary moves the card. Background dragging pans the board.
Start, Connect, Choose Window, and Open App remain separate explicit actions.

Board/content focus is explicit. Terminals, local web apps, and notes accept
input inside resizable cards. The board stays visible. A visible Leave Content
action returns keyboard input to board commands. Native app cards remain
preview-only; Open App activates the separate application.

Each new terminal card contains one terminal. It reuses a one-pane internal
Terminal Group record for runtime ownership and inert restoration, but Canvas
does not expose group creation or splits. Existing multi-pane references keep
their stored record; Canvas shows the first pane, while the normal terminal
workspace retains access to the full group. Board zoom scales a fixed logical
card frame. Card resize changes that logical frame and the terminal size.
Terminal presentation was bounded to four surfaces per window; ADR 0024
Amendment 1 (2026-11-12) removed that bound for Ensemble terminals.

Canvas List and visible/menu/keyboard actions provide non-spatial access.
Undo restores references and geometry, never live resource capability.

Initial ceilings: 10 boards per workspace, 100 cards and 200 relationships per
board, 64 KiB per note and 2 MiB per encoded board, two web controllers and two
capture streams per window. Capture starts at bounded resolution and 10 fps.
Hidden captures stop; hidden web controllers unload. Existing terminals continue
to drain output when parked. These are ceilings, not performance claims.

## Execution and evidence

The baseline repair and planning commit is `0c4db05`. The user's latest direction
supersedes the proposed parallel worktree plan: use one checkout and one agent,
keep C0–C5 dependency order, and make local commits. Do not create an implementation
fan-out or push application code. Consult Astra at Medium only if needed.

C0 probes verify the SDK boundaries and native view transfer before integration.
Interactive picker permission/source-loss cases are checked through the finished
visible controls during C4/C5; no automatic permission request is added merely
to run a probe. Record untested OS versions or unavailable permissions explicitly.
Measurements and final checks are recorded in the active phase and Canvas reference.

## Consequences

WebKit and ScreenCaptureKit are replaceable adapters with explicit resource
lifetime. The Canvas store owns no terminal process or full source-file text.
Existing dirty documents and their undo stacks must survive all Canvas switches.
Missing or corrupt saved Canvas data cannot discard the rest of the workspace.
Multiwindow writes must detect conflicts rather than silently overwrite notes.

## Amendment (2026-10-19): moving a live Terminal Group onto a board

The user asked to drag terminal tabs and Agent History chats onto an Ensemble.
A one-pane Terminal Group tab can now move onto a board by an explicit drag
(centre zone) or the tab menu's "Move to Ensemble". The move keeps the same
runtime owner, controller, and PTY: the process is not restarted, the tab
leaves the editor, the group is parked, and the card takes the presentation
lease described above. Undo removes only the card; the group stays live and
parked and remains reachable from the Terminals list. Refused with a message:
more than one pane, already on a loaded board, board full, or a tab from
another window. Nothing else changes: no process starts without an explicit
user action, no new process allowance, no change to saved-board restoration. A
dropped Agent History row creates the existing resume card (existing
Resume in Ensemble rules). Detail: `docs/references/canvas-interaction.md`,
"Board drops".

Related: the ADR 0023 amendment of the same date lets an Ensemble terminal card
carry a chosen shell, persisted in the inert saved layout with no process
restoration, and restricts every Ensemble key equivalent to the time a board is
the selected tab.

## Amendment 2 (2026-10-19): undo of a move restores the editor tab

Supersedes the clause "Undo removes only the card" in Amendment 1 above. The
user decided that undo must be a real undo of the move: undo after moving a
terminal onto a board **restores the tab in its source editor group** (or, if
that group no longer exists, in the focused group), and the process keeps
running throughout. Redo parks it again. "Undo restores references and
geometry, never live resource capability" still holds — no process is started
or restarted; only the presentation lease and the tab's placement move.

Mechanism: `CanvasBoardState.undoRedoObserver` (one per board, attached lazily
by `WorkspaceSession`) plus a session-only
`movedTerminalCardSourceGroups` map. The source-group map is never persisted,
so after a relaunch an undo falls back to the focused group. VoiceOver
announces both the move and the undo.

## Amendment 3 (2026-11-06): native app cards removed

Supersedes the clauses "Native app cards use public NSWorkspace activation and
ScreenCaptureKit's single-window system picker", "Native app cards remain
preview-only", and the later Accessibility docking of the same card (see
`docs/references/canvas-native-boundaries.md`). The user decided to remove the
feature because it did not work as expected.

- The Mac App card kind, its Add menu and palette entries, the `app_open` and
  `app_inspect` agent tools, and Accessibility docking are removed. Rafu no
  longer uses `AXUIElement` or the Accessibility permission.
- A board saved while the kind existed still opens. `CanvasCardContent` decodes
  the legacy `nativeApp(bundleID:)` value through a private `Stored` enum and
  returns a note that reads "Mac App card: <bundle id>" and says the kind was
  removed. The card keeps its id, rect, title, and links. Nothing is marked
  dirty; the next edit saves the converted form. Encoding never writes
  `nativeApp`. Every other kind keeps its exact saved JSON shape.
- The Add popover and menu list Note, Terminal, File, Image, and Web App. The
  MCP `node_create` kind `app` is rejected as an invalid kind.

## Amendment 4 (2026-11-06): outside images are copied in with consent

The user dropped 11 screenshots from the Desktop onto a board. The drop was
refused ("Choose a file inside this workspace.") because a card may reference
only workspace-relative paths. The user decided that such a drop must work.

- A card never references a path outside the workspace root. This keeps the
  inert restore of this ADR: a reopened board can read only files that
  `CanvasPreviewLoader.checkedURL` resolves inside the root.
- A raster image from outside the workspace is **copied into the workspace**,
  after explicit consent, to `<root>/.rafu/ensemble-assets/<board-slug>/`
  (the parent folder is a per-workspace setting, `ensembleAssetFolder`). The
  card references the copy. The consent sheet offers "Always copy without
  asking in this workspace", stored per workspace root.
- Any other file from outside (text, PDF, SVG, folders) is still refused, now
  with a board notice instead of the save-failure banner.
- The copy is bounded (16 MiB per file), atomic (temporary file, then an
  exclusive rename), never overwrites (`-2`, `-3` suffixes), never follows a
  symlink, and is all or nothing per drop. Rafu never edits `.gitignore`.

Alternatives considered: referencing outside paths (breaks the root boundary
and inert restore), and embedding images in the board document (bounded by
`CanvasLimits.documentBytes` and duplicated in undo history). See
`docs/references/canvas-interaction.md`, "Drop preview ownership, board
notices, and outside images".

## Amendment 5 (2026-11-15): a user add starts the shell, the lease follows the card, wheel scroll reaches card content

The user reported three defects: a terminal added to a board still needed a
click on "Start Shell"; a running terminal showed a "not attached" placeholder
after a zoom-out, a move between terminals, or a resize; and the mouse wheel
and trackpad did not scroll inside Markdown/MDX cards (only the scrollbar
worked). Three durable decisions follow.

**1. An explicit user add of a terminal card is the explicit start.** Add menu,
Add popover, `T`, the empty-board seed, ⌃⌥1–9, the command palette, a chosen
shell, "Connect to new terminal", Duplicate, and "Start Terminal Here" start
the card's shell. This is the explicit user action that ADR 0004 and ADR 0023
require; it is not an automatic start.

- The card, with its one-pane group, still exists first (`addCanvasStoppedTerminal`
  keeps its behaviour); `startCanvasTerminalCard` then starts the pane. Duplicate
  and Connect start after the card has its final rect and edge.
- **Foreground** when the board is shown, zoom is at least 50 %, and the board is
  the selected tab of the focused editor group: the card claims the lease,
  takes focus, and the keyboard goes to the shell. **Background** otherwise: the
  card is selected, the shell starts without a view, the view and the editor
  tabs do not move. The card shows the terminal when it is next in view.
- Unchanged: saved boards restore inert (stopped panes, no process); undo and
  redo restore references and geometry, never a process; no command text is sent
  or run; agent start paths (`terminalStartRequest`, Agent History resume,
  hand-off, ADR 0026 background start) are unchanged. "Start Shell" remains for
  a restored card and for a start that failed.

**2. The presentation lease follows the card (supersedes the release of the
lease when a card unmounts, and the "Reveal" action of the inactive surface in
the phase plan).** The lease governs
which surface shows the one SwiftTerm view, not whether the process runs, and
not memory: the controller keeps its view and buffer while a card is unmounted.
Releasing it on every cull or zoom-out therefore had no benefit and caused the
placeholder.

- A card that scrolls out of view or zooms out keeps the lease. Releases happen
  only on board hide, window hide, card removal, Transfer Here, group close or
  hide, board prune (no card for the group), and undo of a move.
- A mounted card whose terminal is running and whose lease is free claims it at
  once, with no click. The placeholder with a "Show Here" button appears only
  when an editor tab or another Ensemble holds the lease. A second view of the
  same board that cannot present shows a text-only "This terminal is shown in
  another view." with no button.
- A terminal the user is working in (content-active) stays live down to 25 %
  zoom; every other terminal, and every other card kind, keeps the 50 % rule.
- Revealing a terminal (Terminals panel, `revealTerminalSession`, tab switcher)
  goes to its card when a card on an open Ensemble shows it, and opens an editor
  tab only otherwise. `revealTerminalGroup` itself is unchanged for move and
  undo flows. The Terminals panel and tab switcher label such a terminal "On an
  Ensemble", not "Hidden".
- There is still no mount cap and no snapshot face. "Board zoom never
  repeatedly resizes PTYs" and "one SwiftTerm view per PTY" still hold.

**3. Wheel and trackpad scroll goes to the card content under the pointer.**
This replaces "Scroll over an active terminal or web card belongs to that
content" and the earlier "board keeps every wheel event unless the card is
content-active" rule. A scroll view under the pointer that can still scroll in
the gesture's direction takes the gesture without a click; otherwise the board
pans, and ⌘/⌃ zoom. Rules, thresholds, and phase mapping:
`docs/references/canvas-interaction.md`, "Scroll routing".

Alternatives rejected: setting `terminalStartRequest` only (a request is not
consumed while the card is unmounted and it blocks other cards);
`CanvasTerminalStarter.start` (it moves the view); keeping the release on
disappear and reclaiming on every change; a snapshot face for a zoomed-out
terminal; a mount cap; scrolling content only for the selected or active card
(that is the complaint); per-card scroll geometry reports.

Detail and manual checks: `docs/references/ensemble-agent-terminal-tools.md`
section 9, `docs/references/canvas-interaction.md`, and
`docs/plans/phases/ensemble-canvas.md` (status 2026-11-15).

## Cross-reference (2026-11-12): agent starts without a card view

[ADR 0026](0026-canvas-live-session-links.md), amendment of 2026-11-12: when no
card view can host a terminal (the board is behind another tab, or the window is
hidden), a permitted agent start runs the pane itself and creates its terminal
view without mounting it. The presentation lease of this ADR is unchanged: it
governs which surface shows the view, not whether the process runs. Inert
restore and the explicit-start rules for the user are unchanged.
