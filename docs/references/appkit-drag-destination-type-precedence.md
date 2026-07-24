# AppKit drag-destination type precedence: "deepest registered destination wins"

- **Applies to:** `NSTextView` drag acceptance, real Finder file drops, multi-type pasteboard payloads, `NSView` registered drag types
- **Last verified:** Swift 6.2, macOS 26, 2026-07-24

## Rule or observed behavior

In AppKit's drag-and-drop system, **the deepest NSView in the view tree that has registered for the dragged type receives the drop**, regardless of a parent or sibling's registration. When a Finder file is dragged, the pasteboard often advertises MULTIPLE types:

- A Finder file drag typically includes BOTH `.fileURL` (the file path(s)) AND `public.utf8-plain-text` (the stringified path as fallback text)

Because `NSTextView` registers `public.utf8-plain-text` by DEFAULT (to support text pastes), a naive implementation where an `NSTextView` sits inside the editor canvas will steal the Finder drag and paste the file's path as editable text, **even if the parent SwiftUI drop handler is listening for `.fileURL`**. The SwiftUI handler never sees the drag because the `NSTextView` sits deeper and consumes it first.

**Original incomplete fix:** excluding `.fileURL`/`.URL`/`NSFilenamesPboardType` from `NSTextView.acceptableDragTypes` stops the editor's INTERNAL private-UTI payload (from tab/file drags) from being misread as text, but it does NOTHING for real Finder file drops — the text fallback is still registered and still consumes the drop.

**Correct fix:** classify the FULL set of type identifiers in the incoming pasteboard with PRECEDENCE:

1. `rafuEditorDrag` (private UTType, Rafu's internal tab/file drag) — always handle as internal payload
2. `.fileURL` / file-type identifiers — handle as Finder file drop  
3. `public.utf8-plain-text` and other text types — handle as text paste (or reject)

The implementation calls `pasteboard.availableTypeIdentifiers` and checks them in precedence order. If `rafuEditorDrag` is present, it's an internal drag; otherwise, check for file types; otherwise fall back to text. This ensures Finder file drops are CLASSIFIED correctly and forwarded to the appropriate handler, not stolen by the text view's default text registration.

## Why it matters

Without type classification, Finder file drops land as pasted file paths in the editor (wrong behavior, confuses users, makes files uneditable). The fix enables the three-zone drop model (tab reorder, split, move) to work correctly with both internal and external drag sources. It also proves that the correctness issue is not about `NSTextView` "stealing" the drop (a registration layer problem) but about lack of classification (a handling layer problem).

## Related to drag-and-drop-custom-uttype.md correction

The existing note `drag-and-drop-custom-uttype.md` (lines 25–35) incorrectly states that overriding `NSTextView.acceptableDragTypes` to exclude `.fileURL` is the "real fix" for "don't let file drags land as pasted text." That statement is INCOMPLETE and now STALE: the exclusion helps but does not solve the Finder drop bug. This reference note documents the ACTUAL fix (type classification + forwarding) and should be cross-linked from the updated drag-and-drop note.

## Reproduction or evidence

- Manual test: drag a `.txt` file from Finder onto the editor canvas before and after the fix
  - Before: file path is pasted into the text as editable characters
  - After: file is opened in a new tab (or split, depending on drop zone)
- Unit tests for `EditorDropForwarding.dragKind(_:)` pasteboard classification: mock pasteboards with various type combinations (Rafu drag only, Rafu + file, file only, text only, unknown types) and verify the returned `EditorDragKind` is correct
- Integration test with a real `EditorDropForwardingScrollView` accepting drops and verifying the correct handler is invoked

## Verification

```bash
swift build
swift test --filter EditorDrag
swift test
./script/format.sh --lint
./script/build_and_run.sh --verify
```

`swift test`: 1294 tests passing, 0 build warnings. `./script/format.sh --lint`: clean. `./script/build_and_run.sh --verify`: app launches successfully. Manual GUI verification (drag Finder files of various types to editor canvas, verify they open as tabs) pending user acceptance pass.

## SwiftUI group region also accepts `.fileURL` (2026-07-25)

The AppKit forwarding above only covers drags over the TEXT editor's scroll
view. `EditorGroupView`'s SwiftUI `.onDrop` (and the empty editor's) now
registers `[.rafuEditorDrag, .fileURL]`, so an external file dragged over a
terminal tab, an image/video preview, or the empty editor gets the same
split-preview overlay and drop handling (`EditorDropDelegate.
performExternalFileDrop` → `handleEditorFileDrops`). Deepest-destination
routing keeps this conflict-free: over text the scroll view still wins; the
tab strip's reorder delegate stays `.rafuEditorDrag`-only. A terminal view
that registers file types itself would still win over the group region
(standard path-paste behavior).

## Related code, ADRs, and phases

- `Sources/RafuApp/Editor/EditorDragClassification.swift` — pure `EditorDragKind` enum and classification logic
- `Sources/RafuApp/Editor/EditorDragAndDrop.swift` — `EditorDropForwardingScrollView` with `.fileURL` acceptance, `dragKind(_:)` classification, `EditorDropForwarding.performFiles`
- `Sources/RafuApp/Editor/RafuTextView.swift` — removed `acceptableDragTypes` exclusion (incomplete fix); added drag-destination overrides for direct AppKit drop handling
- `Sources/RafuApp/Models/WorkspaceSession.swift` — `handleEditorFileDrops(paths:on:edge:)` action routing
- [`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md) — REQUIRES CORRECTION: update to note this classification fix as the actual solution for Finder file drops
- `docs/plans/phases/pre-initial-push-workbench.md` — workbench file opening feature
