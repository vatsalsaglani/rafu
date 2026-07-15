# Editor working set and hibernation

- **Applies to:** document lifecycle, editor mounting, text storage management, tab selection/focus, editor splits, tab moves, and undo behavior
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-15

## Rule or observed behavior

### Bounded working set

A document's `NSTextView` and text storage remain **mounted** (live in memory) when *any* of these conditions hold:

1. The document is visible in any editor group in any window.
2. The document is marked dirty (unsaved edits).
3. The document is among the most-recently-accessed `N` documents by `accessSequence` timestamp, where `N = keepLoadedLimit = 8`.

All other documents **hibernate**: their `NSTextView` is unmounted, text storage released, but path, revision, file identity, cursor position, and scroll fraction are retained. Hibernation is signaled by `EditorDocument.loadState == .hibernated`.

A hibernated document reloads from disk on refocus (selection changes back to it or the editor group containing it becomes visible). Reload with restored selection position (via `restoredSelection`, clamped to current bounds) and scroll fraction (via `restoredScrollFraction`, best-effort). The document remains dirty across hibernation if applicable.

### Dirty documents are never hibernated

The hibernation policy treats dirty documents as ineligible for hibernation regardless of access recency or visibility. A dirty document that leaves the visible set stays mounted in the loaded state so that unmounting would not lose unsaved text.

### `pendingDirtyText`: exception for structural remounts

When SwiftUI tears down an editor-group subtree (via `EditorLayoutTreeView.renderedNode` AnyView type change during a group split or tab move), the underlying `NSViewRepresentable` calls `dismantleNSView`. Even a dirty document still mounted loses its `NSTextView` because the SwiftUI hierarchy is destroyed.

The fix captures dirty-document text at dismantleNSView time in `EditorDocument.pendingDirtyText` (marked `@ObservationIgnored`, a String or nil). When `load()` is called during the remount rebuild, it checks `pendingDirtyText` first; if present, restores that snapshot into text storage *without reading disk*, marks the document dirty, then clears `pendingDirtyText`. This ensures structural remounts do not silently lose edits.

`pendingDirtyText` is a transient, non-observed exception to the architecture invariant that live full document text lives only in TextKit. It is held momentarily across an app-triggered structural rebuild that TextKit cannot survive, and consumed immediately on restore.

### Undo cap

`CodeEditorView` vends an `NSUndoManager` via `undoManager(for:)` with `levelsOfUndo = 200` (named constant `undoLevelCap`). Undo history beyond 200 operations is discarded.

### Restoration placeholders

At workspace launch, `WorkspaceSession.restoreLastWorkspaceIfAvailable()` calls `applyRestoredHibernationPlaceholders()` at the end of restoration (after the final editor selection is set). This method invokes `updateHibernationStates(bypassNewestGrace: true)`, which bypasses the "keep-loaded-8 for recently accessed" grace and forces all non-visible restored tabs into the hibernated state immediately. Only the visible (selected) editor in each restored group loads content. This ensures that restoration respects the memory budget regardless of how many tabs were open in prior sessions, including sessions with ≤8 tabs that previously remained fully loaded. A hibernated restored tab materializes on first focus via the increment-4 reload path. Cross-launch cursor and scroll persistence is not preserved (restored tabs open at top-of-file on first focus).

## Why it matters

A bounded working set preserves the product's memory budget (idle workspace target: ~150 MB). Keeping only visible, dirty, and recently-touched documents in memory avoids the cost of fully mounting every open tab. Hibernation defers reloading until the document is accessed, and restore-on-refocus (selection + scroll) means refocusing a hibernated tab does not reset the cursor to the top or lose unsaved edits.

The `pendingDirtyText` exception handles a concrete failure mode: SwiftUI subtree teardowns (during layout changes) destroy the NSView subtree regardless of document state, so the transient snapshot bridges the gap between dismantleNSView and remount.

The undo cap prevents unbounded undo history from accumulating across long editing sessions.

## Reproduction or evidence

### Pre-existing data-loss bug (FIXED)

**BEFORE** this increment: background tabs were unmounted on deselect (EditorGroupView mounted only the selected document), dismantleNSView did not save text, and load() unconditionally read disk. The result: editing a file, switching tabs, and switching back *silently lost* unsaved edits. Also, every tab switch reset cursor and scroll to the top.

Reference notes `swiftui-appkit-boundary.md` and `local-editor-vertical-slice.md` *claimed* all tabs stayed mounted to prevent this, but the code contradicted them.

**FIX**: The bounded working set (visible ∪ dirty ∪ newest-8) now stays mounted, making those invariants true for the loaded set. Selection and scroll capture/restore in CodeEditorView.dismantleNSView/load fix the reset behavior.

Verified by: (a) tests added in EditorLayoutTests covering visible-document hibernation and non-hibernation across tab selection; (b) manual confirmation that editing a background tab, switching away, and back preserves edits and cursor position.

### Structural-remount data-loss (FIXED)

Splitting an editor group or moving a tab to another group changes the editor-layout tree's rendered node type (group → HSplitView), causing SwiftUI to teardown and rebuild the affected subtree, dismantling even a loaded dirty document.

**FIX**: `pendingDirtyText` captures the dirty text right before dismantleNSView; load() consumes it (reads from snapshot, not disk), restores the document to dirty state, and clears it. Non-dirty documents reload from disk (safe; they have no unsaved text).

Verified by: DocumentHibernationPolicyTests + EditorLayoutTests confirming split/move operations on dirty documents preserve text.

### Undo cap

Named constant `undoLevelCap = 200` set in CodeEditorView.undoManager(for:).

Verified by: typing 250+ characters/operations in a single buffer and confirming ⌘Z caps at 200.

## Known limitations

1. **Theoretical dual-remount race**: If the same document undergoes two structural remounts within a single `await DocumentGuardPolicy.decide` async gap, `pendingDirtyText` could be overwritten. In practice, this does not occur because no user edits happen during automated remounts, so the snapshot text is identical. A guard against the race (e.g., async-lock or timestamp) is unnecessary at this checkpoint.

2. **Override-flag loss on guard-large-file hibernation**: A clean (non-dirty) large file that is temporarily overridden to "Enable Highlighting" loses that override if it hibernates and later refocuses. `load()` re-runs `applyGuardDecision()`, resetting the override. The banner simply reappears on refocus. Dirty documents never hibernate so are unaffected. Durable fix deferred to a future phase (would require persisting the override state across hibernation).

3. **Scroll-fraction restoration best-effort on very large files**: Restoring scroll position via `scrollRangeToVisible(clamped restoredScrollFraction)` works well for typical files. On very large files (10+ MB, single line), clamping can shift the target range. Cursor restore via `setSelectedRange` is precise. This is acceptable for this checkpoint.

## Verification

Build commands:
```bash
swift build
swift test
```

All test suites green (184/184) with 13 new tests in DocumentHibernationPolicyTests and EditorLayoutTests.

App-launch verification:
```bash
./script/build_and_run.sh --verify
```

Manual confirmation:
- Open a file, edit it, switch to a second tab, switch back → edits preserved, cursor at last position.
- Split an editor group while a tab is dirty → edits preserved across the split.
- Move a dirty tab to another group → edits preserved.
- Focus a hibernated clean tab → content loads from disk, cursor and scroll restored.

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/DocumentHibernationPolicy.swift` — pure policy logic
- `Sources/RafuApp/Models/EditorDocument.swift` — `loadState`, `restoredSelection`, `restoredScrollFraction`, `pendingDirtyText`, `accessSequence`
- `Sources/RafuApp/Views/CodeEditorView.swift` — capture/restore in dismantleNSView/load, undoManager(for:)
- `Sources/RafuApp/Views/EditorGroupView.swift` — calls `updateHibernationStates` on selection change
- `Sources/RafuApp/Views/EditorLayoutTreeView.swift` — renders bounded working set, subject to struct teardowns
- `Sources/RafuApp/Models/WorkspaceSession.swift` — `updateHibernationStates()` method
- `Tests/RafuAppTests/DocumentHibernationPolicyTests.swift`
- `Tests/RafuAppTests/EditorLayoutTests.swift` — visible-document and structural-remount coverage
- `docs/references/swiftui-appkit-boundary.md` — ownership rule update
- `docs/references/local-editor-vertical-slice.md` — working-set behavior
- `docs/plans/phases/lane-1-memory-and-syntax-plan.md` — Increment 4 status
- AGENTS.md § Architecture invariants: "live full document text in NSTextStorage/TextKit, never cached in the model" (exception: `pendingDirtyText`)
