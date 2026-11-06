# Files tree multi-selection, Move to Trash, and Copy Path

- **Applies to:** the Files navigator (`Views/WorkspaceSidebarView.swift`), its
  selection model (`Workspace/FileTreeSelection.swift`), the session API
  (`Workspace/WorkspaceSession+FileTree.swift`), `WorkspaceFileService.trash`,
  `EditorDocument.detachFromDisk`, the File menu items in
  `App/RafuAppCommands.swift`, and the status-bar notice in
  `Views/WorkspaceStatusBar.swift`.
- **Last verified:** Apple Swift 6.4.2 (swiftlang-6.4.2.1.9), macOS 27.0.1
  (26A434), 2026-11-06, branch `issues/files-tree`. Unit tests only; the GUI
  checks below are manual.

## Rule or observed behaviour

### Selection model

The tree selection is per window: `WorkspaceSession.treeSelection`, a
`FileTreeSelection` value with a set of absolute paths, an anchor, and a lead
(the moving end of a Shift range). `selectedTreePath` stays as a compatibility
accessor: get returns the anchor while it is selected (else the first selected
path); set replaces the whole selection with one path. Every older writer
(editor tab sync, `revealInSidebar`, Settings, Agent History) uses the setter,
so those paths always collapse a multi-selection to one row.

| Input | Effect | Opens a file? |
|---|---|---|
| Click | Select only this row; anchor = row | Yes, for a file |
| ⌘-click | Add or remove the row; anchor = row | No |
| ⇧-click | Select the visible range anchor…row | No |
| ⇧↑ / ⇧↓ | Move the lead one visible row; range anchor…lead | No |
| Control-click | Context menu only; the selection does not change | No |
| Return, Space, VoiceOver default action | Same as a plain click | Yes, for a file |

The click reads `NSEvent.modifierFlags` in the row's tap handler. Control is
not a selection modifier, because Control-click is the macOS secondary click.

"Visible order" is `FileTreeVisibleOrder`: a walk of the loaded listings
through expanded folders only, primary root first, then each additional root;
a collapsed root section shows no rows. The collapsed-root set moved from the
sidebar's `@State` to `session.collapsedTreeRootIDs` for this reason. It is
still ephemeral window state.

Rows never keep focus after a click (activation-only focus), so the List owns
⇧↑/⇧↓ through `.onKeyPress`. Plain arrows are ignored and keep the List's
behaviour.

Only the anchor row draws the strong innermost indent guide; every selected
row draws the selection fill and carries the `isSelected` accessibility
trait.

### Keep `body` cheap

A row reads `session.selectedTreePaths.contains(path)` and the selection
count only. The ordered targets of a context-menu action
(`treeContextTargets`, which walks the tree) are built inside the action, not
in the menu builder: every row re-evaluates when the selection changes.

### Move to Trash

- `WorkspaceFileService.trash(_:roots:)` uses
  `FileManager.trashItem(at:resultingItemURL:)` off the main actor. It never
  falls back to `removeItem`. It refuses a workspace root and any item outside
  every root, drops an item under another selected folder, and stops at the
  first failure (for example a volume without a Trash). The items already
  moved still get Undo; the failure shows in the workspace error alert.
- Paths compare after `standardizedFileURL` and
  `WorkspaceRootList.normalizedPath`.
- A confirmation always comes first. Cancel is the default button, so Return
  never trashes. The message names open documents (and file-bound Ensembles)
  with unsaved changes.
- After the move: a clean open document under a trashed path closes. A dirty
  one stays open: `EditorDocument.detachFromDisk()` gives it a synthetic
  temporary identity with the same name and makes it untitled, so ⌘S opens
  the save panel and never writes the trashed path back. A clean Ensemble
  board bound to a trashed `.rafuensemble` file closes through
  `closeCanvas(_:discarding: true)` (a saving close would write the file
  back). A board with unsaved changes stays open; its next save writes the
  file again.
- Undo is registered on the window's `UndoManager` (`@Environment(\.undoManager)`
  in the sidebar). Undo moves each item back only when its original path is
  free; Redo moves them to the Trash again. Documents that closed stay closed.
- The file work is async, so the Redo registration happens synchronously
  inside the Undo handler. `UndoManager` puts a registration on the redo
  stack only while it is undoing; one made from a later `Task` lands on the
  undo stack, and a second ⌘Z would trash the items again.

### ⌘⌫ and Ensemble > Delete Link

Two menu items use ⌘⌫: File > Move to Trash and Ensemble > Delete Link. A
menu key equivalent fires before the first responder sees the key, so each
item must be enabled only in its own context:

- Move to Trash is enabled only while the Files navigator is on screen, the
  Files List has keyboard focus (`@FocusState` mirrored into
  `session.isFilesTreeFocused`), and at least one row is selected.
- Delete Link is enabled only while a link is selected and the board content
  does not hold the keys (unchanged).

With focus in an editor or a terminal, both are off, so ⌘⌫ deletes to the line
start. Plain ⌫ is never a menu key.

### Multi-row drag (MVP)

SwiftUI's `.onDrag` makes exactly one dragging item. When a drag starts on a
row inside a multi-selection, the session remembers the ordered selection
(`treeDragSelection`). A drop on a tree folder or the tree background expands
the one dropped URL to that set when the URL is in it, skipping the
destination and its ancestors. The memory is cleared on any selection change
and when a drop uses it. Other drop sites (editor area, Ensemble boards,
Finder) still receive only the dragged row. `EditorDragPayload` is unchanged.

### Copy Path

| Keys | Command | Copies |
|---|---|---|
| ⇧⌘C | File > Copy Relative Path | Path relative to the root that holds it; root label in front only with more than one root; absolute when outside every root |
| ⌥⌘C | File > Copy Absolute Path | Absolute path |

The target is the Files selection while the Files List has focus, else the
selected file-backed document, else the Files selection. An untitled document
has no path. `PathCopier` is the one formatter for the menu commands and the
context menu (which copies one path per line for a multi-selection). A
2-second status-bar notice confirms the copy (and Move to Trash); it fades
with opacity only and not at all under Reduce Motion, and VoiceOver hears it
as an announcement. No other RafuApp menu, the editor's `keyDown`, SwiftTerm,
or the Ensemble key monitor binds ⇧⌘C or ⌥⌘C; a source-contract test keeps
each bound once.

### "Ask Siri" in the context menu

macOS adds "Ask Siri" to SwiftUI context menus (Finder and Xcode show it too).
It is not Rafu's item; leave it.

## Why it matters

A trash command that runs in the wrong focus context destroys files or steals
an editor key. A Shift range over hidden rows selects files the user cannot
see. Writing a dirty buffer back to a trashed path would silently recreate the
file.

## Evidence and verification

```sh
./script/test.sh --filter "FileTreeSelectionModelTests|FileTreeVisibleOrderTests|PathCopierTests|CopyPathShortcutContractTests|WorkspaceTrash|WorkspaceSidebarSingleClickTests"
./script/build_and_run.sh --verify
```

Manual checks in Rafu Lightning: ⌘-click and ⇧-click rows, ⇧↑/⇧↓; ⌘⌫ with
the Files List focused, with an editor focused (deletes to line start), and
with an Ensemble link selected (deletes the link); Edit > Undo after a trash;
⇧⌘C/⌥⌘C from the editor, a terminal, and the Files List; a second window;
VoiceOver on selected rows.

Related: [sidebar-single-click-opening.md](sidebar-single-click-opening.md),
[list-custom-disclosure-group-style.md](list-custom-disclosure-group-style.md),
[ADR 0002](../decisions/0002-native-workbench-navigation.md), and
[the 2026-11-06 fan-out](../plans/phases/issues-2026-11-06-fanout.md) (G2).
