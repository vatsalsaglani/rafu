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
  while the board (not card content) has keyboard focus.
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
  (`deleteSelectedConnectionIfAny()`). Otherwise it removes the selected cards
  from the Canvas, undoable, with a confirmation when a terminal is running. It
  never deletes source files. **Escape** clears the edge selection and deselects
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
  `.subviews` with Space; the board's high-priority drag uses the opposite
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
  SwiftUI delegate and the bridge use `CanvasFileDrop`. Tab payloads are
  rejected on both paths (`EditorDropRouting.canvasAccepts` in SwiftUI; the
  bridge decodes the payload and accepts only `.file`).
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
