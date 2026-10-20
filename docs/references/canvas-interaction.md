# Canvas interaction model

## Applies to

The Canvas board of the macOS redesign: card interaction and keyboard map,
z-order, snapping and haptics, zoom faces, edge layering and geometry, link
state indicators, and the Notes Read/Edit modes. It does not cover the live
session transport; see [`canvas-live-sessions.md`](canvas-live-sessions.md) and
[`canvas-native-boundaries.md`](canvas-native-boundaries.md).

## Last verified

- Swift 6.2 Linux toolchain (swift.org, ubuntu24.04); **macOS build pending**.
- Nothing here was built or run on macOS. RafuCore imports `Darwin` and RafuApp
  imports SwiftUI/AppKit, so neither compiles on Linux. Statements below
  describe behaviour as implemented, not as observed in a running app.

## Rule

### Input map

Behaviour as implemented by W6a (code-read only; macOS build verification
pending).

- **Header moves, body interacts.** The 32 pt header is the move handle. The
  card body belongs to its content (terminal, web view, note, etc.). There is
  no footer.
- **Background drag** pans. **Space + drag** pans even over cards, but only
  while the board (not card content) has keyboard focus. The **Hand** tool
  pans the same way without Space (see "Hand tool and palette layering").
- **Shift + drag** on empty board draws a marquee selection.
- **Double-click:** on a header title it renames inline; on the header
  background it zooms to the card (animated); on empty board it opens the Add
  popover at that point with type-ahead (Note, Terminal, File…, Image…,
  Web App…, Mac App…). Double-click in a file card body opens the file at that
  line; a double-click on a note block enters Edit mode at that line.
- **Return** on one selected card enters its content; on a stopped terminal it
  starts the shell (an explicit key press); on a note it begins editing.
  **Option-Return** zooms to the card. **Arrow keys** move selected cards 8 pt
  (Shift: 40 pt); **Option-Command-arrows** resize one axis by 8 pt.
  **Tab / Shift-Tab** select the next/previous card in reading order and the
  viewport follows. **N** adds a note and **T** a terminal, only while the board
  has focus. Menu items show these keys as hints in their titles, because real
  arrow-key menu shortcuts would fire while a terminal or note has focus.
- **Delete (Backspace)** deletes the selected edge first
  (`deleteSelectedConnectionIfAny()`, one undo step). Otherwise it removes the
  selected cards from the Canvas, undoable, with a confirmation when a terminal
  is running. It never deletes source files. Rules for the edge path (round 4):
  - A non-empty card selection clears `selectedConnectionID` by every path
    (`selection.didSet`), so Delete never acts on a stale edge, and clearing
    the cards never brings an old edge back.
  - An edge is not focusable. Its click asks for board focus before and after
    `selectConnection` (the second request on the next main-actor turn),
    because leaving card content resigns the first responder in the same turn.
  - `CanvasEdgeDeleteKeyMonitor` (a local key monitor) deletes the selected
    edge on Delete/Forward Delete even when the board still has no focus. It is
    active only on the focused board, with an edge selected, the board taking
    keys and no label popover open, and it never takes the key from text input
    (`NSText` or any `NSTextInputClient`: editors, notes, terminals, fields).
  - The board also answers `.onDeleteCommand` with the same body.
  - The menu path is **Ensemble > Delete Link** (Command-Delete), enabled only
    with an edge selected and no card content active. Plain Backspace is never
    a menu key equivalent: it would take the key from text input. **Escape** clears the edge selection and deselects
  cards (in content, Escape goes to the content).
- **Zoom:** one 36 pt bar with a zoom capsule. Cmd-9 zooms to fit all cards,
  Opt-Cmd-9 fits the selection, Cmd-0 is actual size (100%); the percentage
  menu also offers 50% and 200%. Viewport scale is 10% to 400%.
  Cmd + scroll zooms about the pointer.
- **Return to Board is Ctrl-Tab**, handled by a local key monitor. Ctrl-Tab is
  also Next Tab in the app commands. The monitor wins only while a card's
  content is active; otherwise Next Tab keeps it. This is a known conflict, not
  an accident: do not "fix" it by removing either binding without choosing which
  one the user keeps.
- **Quick Open ⌘↩ adds a file.** With an Ensemble as the focused tab, ⌘P, a
  file row, then **Command-Return** adds that file as a card (Return still
  opens it). See "2026-10-20: Quick Open adds a file to the Ensemble".
- **Pointer feedback:** resize zones use `pointerStyle`. Resizing applies
  per-type minimum sizes with resistance and a spring.

### Inline card rename and board keys (round 4, code-read only)

- The inline title field (`CanvasCardRenameField`) opens on a double-click on
  the header title, on "Rename…" in the card menus, and from the list.
  **Return** and **clicking away** (focus loss) save; **Esc** cancels. The
  save is one undoable `board.edit`, the same as the Rename Card dialog.
  `CanvasInlineRename.committedTitle` trims the draft and saves nothing when
  it is unchanged or not a valid title (1 to 120 characters, no control
  characters). A stored title wins over the automatic agent title; only the
  automatic names "Terminal" and "Terminal Group N" show the agent title.
- **Board shortcuts stand aside while a title field is open.** The board's
  `.onKeyPress` handlers (Return, Space, Delete, arrows, Tab, Esc, N, T, ⌘A,
  ⌘Z) are on an ancestor of the field and can take the key before `onSubmit`
  (from code reading; confirm on a Mac). They now
  check `CanvasInlineRename.boardTakesKeys` (no card content active and
  `board.renamingCardID == nil`). Before this, a double-click selected the
  card, so Return reached the board's "enter content" handler, which handled
  the key: the field lost focus and the name was discarded. A rename from the
  context menu did not select the card, so it seemed to work.
- **The paused-links notice stacks below the tool palette.** Both are
  top-centre overlays on the board, so they are one `VStack`
  (`WorkspaceCanvasView.boardTopOverlay`: palette, then notice, 8 pt apart, 10
  pt from the top). `CanvasToolPalette` no longer pads or frames itself. The
  list view has no palette and keeps its own notice at the top.

### Pointer ownership, focus ring, and file drops (round 2, code-read only)

- **One pan owner.** The grid's drag gesture is masked `.all` without Space and
  `.subviews` with Space (or Hand); the board's high-priority drag uses the opposite
  masks. Exactly one pan/marquee gesture is enabled at a time. A new
  `startLocation` resets stale pan state, because SwiftUI may not call
  `onEnded` when a mask flips mid-drag.
- **Empty-board pan.** The dot grid reads `board.viewport` in `body` and passes
  values into the `Canvas` renderer. A viewport read only inside the renderer
  is outside Observation tracking, so an empty board (no card reads the
  viewport) never redrew while its viewport changed.
- **No system focus ring.** The board is `.focusable()` for its keys and
  `.focusEffectDisabled()`; the system ring outlined the whole board and could
  spill over the sidebar. Cards keep their own gold content-focus stroke.
- **`CanvasScrollBridge` takes no mouse events** (`hitTest` is nil). It
  handles scroll/zoom through a local monitor and is also the board's AppKit
  drop destination (`CanvasBoardDropTarget`) for the private editor drag type
  and file URLs. AppKit routes a drag to a registered `NSView` under the
  pointer; editors of the same group stay mounted (hidden) below the Canvas
  overlay, and SwiftUI `.onDrop` did not receive drags over AppKit subtrees
  (see `drag-and-drop-custom-uttype.md`, "AppKit subtree dead zone"). Both the
  SwiftUI delegate and the bridge use `CanvasFileDrop`. (Until 2026-10-19 tab
  payloads were rejected on both paths and only `.file` was accepted from an
  editor drag. The board now owns every drag; see "Board drops" below.)
- **Dropped content.** Folders are skipped without an error; raster image
  extensions become image cards; files outside the workspace still reject
  the whole batch.
- 2026-10-18 update (code-read only): the UI says "Ensemble" for the board. A
  frame is created from a selection with the shortcut Control-Command-G
  (`CanvasDiagramMenus.swift`, "Convert Selection to Frame"). Whiteboard tool
  keys (V H R O D A L P X M I, Text on X because T adds a terminal) and the
  `CanvasScrollBridge` `focusRingType = .none` setting are confirmed in code
  (`Canvas/Whiteboard/CanvasWhiteboardTool.swift` `key`,
  `Canvas/Adapters/CanvasScrollBridge.swift` lines 82 and 87).
- Mac checks still required: plain drag pans an empty board; Shift-drag
  marquee; Space-drag over a card; Files-tree and Finder drops with and
  without open documents in the group; a tab dragged over a Canvas tab still
  splits.

### Board drops (2026-10-19)

Replaces the earlier "file drops" description. Verified by build, lint, and
tests on main (macOS 27.0.1 (26A434); Apple Swift 6.4 (swiftlang-6.4.0.34.1)):
parallel 250 + 2522 tests passed, `--no-parallel` 250 + 2522 passed,
`./script/build_and_run.sh --verify` exit 0. Real mouse drags were NOT driven
by UI automation; the manual checks listed below are still open. (The
`CanvasScrollBridge.swift` header comment still says "File drops" for this
section.)

- **Cause of "cannot drag a History chat or a terminal tab onto the board".**
  The History row had only a `.contextMenu`, so no drag was ever built. The
  board accepted only `.rafuEditorDrag` (files) and `.fileURL`, and refused
  `.tab` payloads in both the SwiftUI delegate and the AppKit
  `CanvasScrollBridge`.
- **The board owns every drag over a visible board.** Both halves decode into
  one `CanvasBoardDropContent` (`.files`, `.agentSession`, `.tab`) and share
  the `CanvasFileDrop` policy, so a drop is handled once whichever half AppKit
  picks. Type priority: `rafuEnsembleDrag` > `rafuEditorDrag` > `fileURL`. The
  proposal is an explicit `.copy`.
- **Agent History row.** `CanvasBoardDragPayload.agentSession(provider,
  sessionID)` carries ids only (no title, path, or transcript), decodes at most
  16 KB, and rejects an id that `AgentHistoryResumeCommand.arguments(for:)`
  refuses. Drop creates the normal resume card at the drop point
  (`CanvasBoardDropGeometry.boardPoint`). The summary is looked up in
  `AgentHistoryStore.shared`, so a row dragged from another window works.
  Existing rules apply: folder rules, full board refusal.
- **Terminal Group tab.** A one-pane Terminal Group tab dropped in the CENTRE
  zone calls `moveTerminalGroupToEnsemble`, which moves the LIVE terminal (no
  restart). The tab leaves the editor, the group is parked, and the card takes
  the ADR 0025 presentation lease. **Superseded 2026-10-19 — see "Board drop
  previews, labels, and undo" below: undo now restores the tab in its source
  editor group, and the process keeps running.** Refusals,
  each with a message on the board: more than one pane; already on a board;
  board full; tab from another window. A drop in an EDGE band, or of a
  non-terminal tab, is forwarded to `handleEditorTabDrop` on the editor group
  that shows the board, so splitting still works under a visible board.
- **Menu path.** "Move to Ensemble" in the Terminal Group tab context menu
  (`moveTerminalGroupToCurrentEnsemble`).
- **Possible older bug, unverified.** Since commit bc795ec the bridge
  registers `rafuEditorDrag`, so it may have swallowed tab drags over a visible
  board and broken edge-split. The forward-to-group rule above is meant to fix
  that, but only a manual drag can confirm it.
- **Never route a drop with the cached `activeEditorDrag`.** A cancelled drag
  can leave it stale. Decode the incoming provider at drop time. The cache is
  only a `validateDrop` hint.
- Dead code `addCanvasTerminal` was removed.
- Manual checks still required: drag a History row onto an empty and a busy
  board, from a second window, and onto a full board; drag a one-pane terminal
  tab to the centre; drag it to an edge (must split); drag a two-pane group
  (refusal message); undo after a move; drag a file tab onto the board.

### Agent status on the board (2026-10-19)

Commit 9c6c095. An agent terminal card carries a header pill with its status
word, and the board bar `CanvasAgentSummaryBar` rolls the board up as
"N agents · N working", with an amber "N needs you" and a red "N failed" that
open jump menus routing through `focusCanvasCard`. Shell-only terminal cards
show none of this. The seven states, their precedence, and the deliberate
refusals (no cost, no sub-agent count, no tab badge) are
[ADR 0029](../decisions/0029-agent-status-vocabulary.md); the engineering
nuances are in
[`agent-hooks-and-now-playing.md`](agent-hooks-and-now-playing.md), "Agent
card status vocabulary". Counts never carry meaning by colour alone — the word
is always present.

### Board drop previews, labels, and undo (2026-10-19)

Commits 3380c53 (fixes), 5860a98, 2debd37, 5c72b84 (previews). Verified on
`main` at ba00643 (Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
(26A434)): format lint clean; build with 0 warnings, test targets included;
parallel suite 250 + 2631 tests passed; `--no-parallel` (CI mode) 250 + 2631
passed; `./script/build_and_run.sh --verify` launched Rafu Lightning. Real
mouse drags were not driven by UI automation; the manual checks below are
open. (The stale "File drops" wording in `CanvasScrollBridge.swift`'s header
comment is still there; only this document was corrected.)

**Preview contract.** The board's drop contract widened from a boolean
`targeted` to `update(CanvasDropPreview?)` plus a preview closure. A pure
`CanvasDropPreview` and `CanvasDropAction.resolve` decide what the preview
says, using the same `decide`/geometry rules as the drop itself, so the
preview cannot promise an outcome the drop refuses. The board then shows a
projected ghost card, an edge band, or a whole-board highlight, with a label
capsule. `CanvasBoardDropGeometry.defaultRect` / `defaultSize` are shared with
`CanvasBoardState.add`, so the ghost sits exactly where the card lands.

**Hover fidelity differs by path, deliberately.** On the AppKit
`CanvasScrollBridge` path the preview is exact, because `NSPasteboard` can be
decoded synchronously. On the SwiftUI delegate path there is no synchronous
decode, so the preview uses type presence plus same-window hints
(`activeEditorDrag`, the new `activeEnsembleDragHint`). The resulting labels
are generic for a cross-window drag but never wrong. **Hover must not decode
the provider on the SwiftUI path** — see
[`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md).

**New payload.** Terminals-panel group rows now drag
`CanvasBoardDragPayload.terminalGroup(id:)` on the private ensemble-drag type,
handled by `dropTerminalGroupOnCanvas`. This is what lets a **parked** group be
dragged: a parked group has no tab id, so the `.tab` payload could not name it.

**Undo restores the tab.** User decision 2026-10-19, recorded as Amendment 2 of
[ADR 0025](../decisions/0025-workspace-canvas-and-app-previews.md): undo after
moving a terminal onto a board restores the tab in its source editor group — or
the focused group if that group is gone — and the process keeps running; redo
re-parks it. Mechanism: `CanvasBoardState.undoRedoObserver`, one per board,
attached lazily by `WorkspaceSession`, plus a session-only
`movedTerminalCardSourceGroups` map that is never persisted (so after a
relaunch undo falls back to the focused group). VoiceOver announces the move
and the undo.

**Placement labels, and why they are ordered.** The Ctrl-Tab switcher's
placement text follows one precedence: canvas-owned ("On an Ensemble") beats
not-running, which beats "Hidden · Running". The Terminals list uses "On an
Ensemble" for the same state. An orphaned card — the group is gone after a
reopen — shows "No terminal yet" and a "Start Terminal Here" action;
`startTerminalHere` keeps the card's id and rect and starts no process.

**"Terminal view is not attached" on a stopped card** was a decision-order
bug: lease ownership was checked before running state. The order is now a pure
`CanvasTerminalCardBlock.decide(isRunning:ownsLease:)`, and "Show Terminal"
focuses (acquire + reveal) instead of taking the lease only.

Open manual checks: a real-mouse drag of each source onto each target; the
source ghost clears on drop and on Escape; undo and redo of a move; every
placement label; the orphaned-card path after a reopen.

### Shell choice and card navigation (2026-10-19)

Verified on `main` by lint, build, and the full suite in both modes
(Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434)): parallel
250 + 2545 tests passed, `--no-parallel` 250 + 2545 passed,
`./script/build_and_run.sh --verify` passed. Keys were not driven by UI
automation; the manual checks at the end are still open.

The user asked to choose the shell when adding an Ensemble terminal, to give
each shell its own shortcut, and for shortcuts to move between cards.

**Add surfaces.** `CanvasAddItem` (`CanvasAddMenu.swift`) lists the card kinds
plus one row per discovered shell, but only when the machine has two or more
shells. Titles come from `TerminalNaming.shellMenuTitle`. The Add popover's
type-ahead covers the shell rows as well ("fish" finds the fish row; "term"
matches both the terminal kind and the shell rows). The same shells appear as a
"Terminal with Shell" submenu in the board menu, the board's pull-down, and
Ensemble > Add to Ensemble, and as palette commands
"Ensemble: Add Terminal — <shell>". A card created with a chosen shell shows
the shell basename in its not-running block instead of "Default shell", because
the profile now stores the concrete approved path even when no shell was passed.

**New keys.**

- `Control-Option-1` … `Control-Option-9`: add a Terminal with the shell at
  that position in the catalog (1 is the default shell). With only one shell,
  `Control-Option-1` is plain Add Terminal.
- `Control-Command-Left/Right/Up/Down`: Focus Card Left/Right/Up/Down.
- `Control-Command-]` / `Control-Command-[`: Focus Next/Previous Card, in the
  existing reading order, wrapping.
- `Command-1` … `Command-9` are deliberately left free for future tab
  selection.

Shortcut data lives in `CanvasNavigationShortcuts.swift`, the items in
`CanvasCommands.swift`.

**Gating rule: declare an Ensemble key equivalent only inside the
board-and-session block.** A menu key equivalent is consumed app-wide before
the first responder reaches it (`RafuAppCommands.swift:303-308`), so a
permanently installed Ensemble key would be lost to every embedded shell. Every
new key is declared inside `CanvasCommands`' existing
`if let board, let session { … }` block, so the menu item *and* its key
equivalent exist only while an Ensemble board is the selected tab. This
existence gating was chosen over the optional
`.keyboardShortcut(KeyboardShortcut?)` overload because it is the file's proven
idiom. Follow it for any further Ensemble key.

**Shared-key nuance (one open question).** `Control-Command-arrow` is also
"Focus Terminal Pane" in `RafuAppCommands` (lines 468-483). On a board the card
items are `.disabled` whenever pane focus in the same direction is enabled.
Pane focus is never enabled on a board, because an Ensemble terminal card
always has exactly one pane (splits are refused on a board, and
`moveTerminalGroupToEnsemble` accepts a one-pane group only). **UNVERIFIED:**
that AppKit routes `Control-Command-arrow` to the enabled card item when a
disabled pane item with the same key equivalent exists in an earlier menu. This
needs a check on a Mac by hand.

**Ordering is geometry, not creation or z-order.** Direction keys compare card
centres and prefer a target that overlaps on the other axis; there is no wrap.
Creation order is invisible to the user and z-order changes with Bring to
Front, so neither can order navigation.

**Focus rule.** `focusCanvasCard(_:in:)`
(`Canvas/Integration/CanvasBoardNavigation.swift`) always reveals the target
card. A terminal card is entered through `board.focus`, and
`CanvasTerminalCard`'s `onChange(of: active)` is what makes SwiftTerm the first
responder — that step is not duplicated. Any other card kind is only selected,
so arrowing onto a note does not enter Edit mode. `focusedCardID` is updated so
repeated direction keys continue from the current card (`leaveContent` never
clears `focusedCardID`). Navigation is silent when there is no target.

**Deferred on purpose:** a shell parameter on the MCP `terminal_create` tool
(it is a consent surface; ADR 0021 and ADR 0025), per-shell shortcuts for
editor Terminal Groups, and numbered card focus.

Tests: `CanvasAddItemTests`, `CanvasBoardNavigationTests`,
`CanvasNavigationShortcutsTests`, `WorkspaceSessionShellLaunchProfileTests`,
and extended `CanvasLayoutMathTests`.

Manual checks still open: the shell submenu and the `Control-Option` keys on a
Mac with two or more shells; `Control-Option-2` inside an editor Terminal Group
reaching the shell instead of the board; `Control-Command` arrows and
`Control-Command-]`/`[` moving focus from inside a terminal card; arrowing onto
a note not entering Edit mode; save and reopen keeping the shell name;
VoiceOver labels on the new items.

### Hand tool and palette layering (2026-10-20)

Applies to `WorkspaceCanvasView`, `CanvasToolPalette`,
`CanvasWhiteboardCreationLayer` and `CanvasWhiteboardTool.swift`
(`CanvasBoardPanRouting`, `CanvasBoardPan`). Last verified: Apple Swift 6.4,
macOS 27.0.1, arm64, headless only (no live Lightning run).

- **Hand is Space-drag, latched.** `CanvasBoardPanRouting.panOverridesCards`
  is true while Space is down or the tool is Hand. Both pan masks read it, so
  the board's high-priority background pan takes a drag over cards, and a
  click (no movement) still reaches card chrome. Shift-drag does not start a
  marquee in Hand. The creation layer is inert for Select, Hand and Image
  (`drawsOnBoard`); Hand used to lay a full-board `DragGesture(minimumDistance:
  0)` over every card, with a `panStart` that only `onEnded` cleared.
- **The palette is outside every board gesture.** `boardTopOverlay` is an
  `.overlay(alignment: .top)` applied after `.highPriorityGesture` and the
  magnify gesture and before `.focusable()`, not a `boardLayers` ZStack child.
  A palette click that moves 5 pt in Hand selects the tool and does not pan.
  It stays inside `.focusable()` so `@Environment(\.isFocused)` still gates
  the letter keys.
- **Choosing a tool returns the keys to the board.** `choose` calls
  `board.backToBoard()` when content is active, then `focusBoard()`. Before,
  with a terminal or note active, Escape and V reached the card, and Hand could
  not be left from the keyboard. A Hand pan that starts over a card also
  focuses the board.
- **A cancelled drag ends the pan.** Each background-drag attachment has its
  own `@GestureState` (`gridDragIsLive`, `boardDragIsLive`); SwiftUI resets
  them on end and on cancel. When neither is live, `endBackgroundDrag()` runs,
  so `pan.isPanning` and the grab pointer cannot stay stuck when `onEnded` is
  skipped. Two states, not one shared state: a Space mask flip hands a live
  drag from one attachment to the other, and one shared state could reset
  mid-drag and restart the pan (code-read, not observed). The board-wide pointer is
  `grabIdle`/`grabActive` only in Hand.
- **Root cause status.** The reported freeze (Hand selected; palette, Select
  and keys do not respond; the process idle in its run loop) was NOT
  reproduced headlessly. In an `NSHostingView` harness, palette clicks worked
  in Hand before the fix too. The fix removes the Hand-only full-board
  zero-distance gesture and fixes the proven keyboard defect. Confirm on a Mac:
  Hand, pan over a live terminal card, then click Select, press Escape, press V.

Headless gesture diagnostics: an `NSHostingView` in an offscreen borderless
`NSWindow` takes synthetic `NSEvent.mouseEvent` events through
`window.sendEvent(_:)`, and `RunLoop.main.run(until:)` lets SwiftUI update, so
SwiftUI gestures can be driven from a test without moving the pointer. Do not
override `canBecomeKey` there: the test process cannot activate, so AppKit
treats every press as a first click and swallows it for views that refuse
first mouse (the Hand pan did not move). Keyboard paths that check
`window.isKeyWindow` cannot be driven this way. Do not commit such a harness;
it needs a run-loop wait.

Verification: `swift test --filter CanvasHandToolTests`.

### Z-order is array order

Stacking order is `board.cards` array order: the last card is on top.
Bring-to-front is an array reorder, not a separate z-index. It is **skipped**
for clicks inside native terminal or web bodies so that the first responder is
not stolen from them. Any new card type that hosts a native responder must
follow the same skip.

### Snapping and haptics

- `CanvasSnapper` computes snapping and guides while moving and resizing.
- Haptics use a throttled `.alignment` pattern (`RafuHaptics`), gated by the
  `canvasHapticsEnabled` user default (default on, toggle in Settings > General).
- Apple documentation says haptics are for user-initiated events and work on
  Force Touch trackpads. SwiftUI `sensoryFeedback` supports `.alignment` on
  macOS and `.levelChange` on macOS only. `.success`, `.error`, `.impact` and
  `.selection` are iOS and watchOS only. Therefore there is **no** success or
  failure haptic on the Mac, and **no** haptic for incoming agent messages.
- PTY resize happens once, on mouse-up, not during the drag.

### Zoom faces

`CanvasZoomFace` chooses how much of a card is drawn at the current zoom.

- Zoom never resizes a PTY. Only an explicit card resize does.
- Terminal and web cards **unmount** below 50% zoom and show a face instead.
  Web cards carry an explicit Load control.
- Notes also use zoom faces.

### Edge layering and geometry

- `CanvasEdgeLayer` draws edges **below** cards. `CanvasEdgeOverlay` draws
  **above** cards. `CanvasConnectionPorts` provides the connection ports. The overlay
  draws the arrowheads and port stubs of every edge (so connection points stay
  visible over card borders), the hovered or selected edge with its accent halo
  and draggable end handles, the connection drag preview with target and snap
  feedback, and the label / "Connect to new…" popovers.
- `CanvasEdgeGeometry` rules: edges leave from the facing sides of the two
  cards; endpoints on one side spread 8 pt apart; Bezier control distance is
  `clamp(0.4 * d, 24, 160)`; one pass bends the curve; hit test tolerance is
  6 pt; level of detail follows zoom tiers; a drag snaps to a port within 24 pt.
- Bezier math uses `Double` locals. Mixed `Double` and `CGFloat` expressions
  measured slow in `-warn-long-expression-type-checking` (2.8 s and 5.5 s) and
  were rewritten.
- Default labels "Related to" and "Session link" are treated as unlabelled.

### Link states and activity dots

States are Live, Paused, Disconnected(reason), Failed(reason); see
[`canvas-live-sessions.md`](canvas-live-sessions.md). `CanvasLinkStatusItem`
shows them. The message-activity dot is driven by a `TimelineView` that exists
**only while a link is active**, so an idle board has no per-frame work. With
Reduce Motion on, the badge pulses instead of animating the dot. State is never
carried by color alone.

### Notes: Read and Edit modes

- **Read mode** renders Markdown through MarkdownUI one top-level block at a
  time (`RafuNoteMarkdownStyling.swift`). Task checkboxes toggle through the
  TextKit buffer, so undo stays intact.
- **Edit mode** uses SF Pro with incremental syntax styling (`CanvasNoteSyntax`),
  formatting commands (`CanvasNoteFormatCommand`) and a Format menu. Cmd-B and
  Shift-Cmd-L conflict with app commands and are handled by a key monitor only
  while a note is being edited.
- **Links:** workspace files open in Rafu; `http`, `https` and `mailto` open in
  the system; every other scheme is ignored. Images load only from workspace
  files.
- **Known limits (MarkdownUI):** Cmd-C in Read mode copies rendered text, so a
  "Copy Note as Markdown" context item exists; links show no hover underline;
  inline code has no corner radius.

### Known skipped items

Not implemented, with the stated reason:

- Stop for a running terminal (no safe API).
- Image pixel size in the image card.
- Selection in the file excerpt card (excerpt is 40 lines or 8 KiB).
- A "last command" summary on terminal cards.
- A board-focus VoiceOver hint.
- Real arrow-key menu shortcuts (titles show hints instead).
- "Show Message Log..." (no message log exists).

## 2026-10-20: one Add palette, no List mode, no ⋯ overflow

Verified on `main` at 716370a (Apple Swift 6.4 (swiftlang-6.4.0.34.1),
macOS 27.0.1 (26A434)). This supersedes the List-mode and overflow-menu
statements above.

### List mode is gone

The board has one presentation. `⌃⌘1` and `⌃⌘2` are **freed** — do not treat
them as taken. The accessible path that List mode used to serve is now a
VoiceOver **"Cards" rotor** built with `accessibilityRotorEntry`; its `prepare:`
closure selects the card **and** reveals it, which is required because a rotor
destination off-viewport is otherwise unreachable.

### One Add palette

`CanvasAddPopover` is the single add surface, reached three ways: the bar's `+`
(which passes `boardPoint: nil`), a double-click on empty board (which passes
the point), and type-ahead. It presents a `LazyVGrid` of tiles including a
Service Icon tile, plus shell chips carrying their `⌃⌥n` hints. Navigation is a
pure value type, `CanvasAddPaletteNavigation`, so key handling is testable
without a board.

### The ⋯ overflow menu is retired

Its contents were redistributed rather than dropped: Export is its own button,
the link controls moved into the link popover as a `RafuSegmentedPicker`,
**Select All Cards** moved to the menu bar, and the Icon Library is reached
through the palette.

### Card title: one `Text`, with a separate `▾` menu

The title is a single `Text` with a `TabClickIntent` double-click rename, and
the card menu is a separate borderless SwiftUI `Menu`. **A borderless `Menu`
opens on mouse-down, so a double-click on the menu label is impossible** — the
rename gesture cannot live on the menu. The user accepted that split.

### Terminal Group cards

No accordion and no `expandedGroupIDs`: a Terminal Group card shows its panes as
chips in a flow `Layout`, with an `AgentStatusPill`, a hover/focus `⋯` backed by
the context menu, and a Start Agent card row.

`CanvasBoardState.ensembleSymbol` is `circle.hexagongrid`.

## 2026-10-20: Quick Open adds a file to the Ensemble

Last verified: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434).
Build and tests only; the key path was not driven with real input.

- **Path:** ⌘P (file mode), select a file row, **⌘↩**. The palette closes and
  `WorkspaceSession.addFileToSelectedCanvas(_:)` runs. Return keeps its meaning
  (Open). The footer shows "⌘↩ Add to Ensemble" only while an Ensemble is the
  focused tab (`PaletteFooterHints.text(boardActive:)`). VoiceOver gets the same
  action as the row's "Add to Ensemble" accessibility action.
- **Placement:** `CanvasBoardState.add` (now `@discardableResult`, returns the
  new `CanvasCardID`) at the middle of the visible board with the 24 pt cascade.
  `creationCenter` is cleared first, as every non-popover add path must. The
  card kind comes from `CanvasDroppedFileKind.content(forRelativePath:)`, so a
  raster image becomes an image card and everything else a file card, exactly
  as a drop does. One `edit`, so one undo step.
- **After the add:** `focusCanvasCard(_:in:)` reveals, selects and tracks the
  card (`focusedCardID`), and does not enter content.
- **No duplicate:** `CanvasFileCardLookup.existingCard(forRelativePath:in:)`
  finds the first `.file` or `.image` card with that path; the action then
  selects and reveals it instead of adding a second card.
- **Other folders are refused.** Board paths are relative to the primary
  folder. A match whose `rootID` is not `descriptor?.id` sets
  `board.errorMessage` to `WorkspaceSession.canvasFileOutsideFolderMessage`
  and adds nothing. A full board (`CanvasLimits.cards`) shows the capacity
  error.
- **Scope:** one row at a time. No ⇧⌘↩, no multi-select, no folder rows.
- **Key routing:** a local key monitor (`CommandPaletteKeyMonitor`), not
  `onKeyPress`. See pitfall 5 in
  [`command-palette-and-search-pitfalls.md`](command-palette-and-search-pitfalls.md).
- **Tests:** `Tests/RafuAppTests/Canvas/CanvasQuickOpenAddTests.swift`.
- **Manual check still required:** open an Ensemble tab, ⌘P, type a file
  name, ⌘↩: the palette closes and one selected card appears in the middle of
  the board; ⌘Z removes it; ⌘P and ⌘↩ on the same file again selects the
  existing card; ⌘↩ in a plain editor tab does nothing and the footer has no
  ⌘↩ hint; Return still opens the file in both cases; ⌘↩ while a note is in
  Edit mode behind the palette still goes to the palette.

## Why it matters

Canvas mixes gesture-driven custom views with native responders (terminal, web,
text). Most defects here are ownership defects: who gets the first responder,
which layer wins a hit test, which key binding wins. Recording the choices lets
the first Mac pass test the right places.

## Evidence

- `swiftc -parse -swift-version 6` over all Sources and Tests: 0 errors. Without
  `-swift-version 6`, bare `/regex/` literals are rejected; this is a toolchain
  nuance, not a source defect.
- `swift-format lint --strict --recursive Sources Tests`: clean.
- Pure-logic code (snapper, edge geometry, link state, layout math, note syntax,
  format commands) was compiled and tested in scratch SwiftPM packages outside
  the repository, with `import CoreGraphics/SwiftUI` swapped to `Foundation`,
  and with default isolation set to `MainActor` to mirror the GUI target. About
  250 Swift Testing tests passed across the redesign workstreams. The Canvas
  audit alone ran 107 or more tests in 8 or more suites. These runs are not the
  repository test suite, in either parallel or `--no-parallel` mode; neither
  mode has been run.
- Three compile audits read every changed symbol against its definition and
  checked risky SwiftUI/AppKit APIs against Apple documentation JSON.

## Verification commands

On a Mac, in this order (run one SwiftPM invocation at a time):

```bash
./script/format.sh --fix
./script/format.sh --lint
./script/build.sh
./script/test.sh --filter Canvas
./script/test.sh
./script/test.sh --no-parallel
./script/build_and_run.sh --verify
```

Manual checks still required (from the handoff follow-ups plus the items this
note names): Tab key reaching the board; terminal first-click focus; Ctrl-Tab
with a terminal active versus board focus; Space + drag and Shift + drag; haptics on a Force Touch trackpad; terminals and web
cards unmounting below 50%; Reduce Motion badge pulse; note Read/Edit toggling
with undo; edge layering with overlapping cards; inline rename (double-click,
type, Return / click away / Esc) on a terminal, note, and file card; the
paused-links notice below the palette at a narrow split width.

## Related

- Code: `Sources/RafuApp/Canvas/` (views, `CanvasSnapper`, `CanvasZoomFace`,
  `CanvasEdgeLayer`, `CanvasEdgeOverlay`, `CanvasConnectionPorts`,
  `CanvasLinkStatusItem`), `CanvasEdgeGeometry`, `CanvasLinkState`,
  `CanvasConnectionRules`, `CanvasLayoutMath`, `CanvasNoteSyntax`,
  `Support/RafuMotion.swift`, `Support/RafuHaptics.swift`.
- References: [`canvas-live-sessions.md`](canvas-live-sessions.md),
  [`canvas-native-boundaries.md`](canvas-native-boundaries.md).
- Phase: `docs/plans/phases/macos-redesign.md`.
