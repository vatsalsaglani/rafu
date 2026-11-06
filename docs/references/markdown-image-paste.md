# Markdown image paste and drop

- Applies to: pasting (⌘V, Edit › Paste) and Finder-dropping images into a
  saved `.md`/`.markdown` document in the code editor (Markdown Edit and
  Split modes), `RafuTextView`, `CodeEditorView.Coordinator`, and the
  Settings › General › Markdown "Image folder" field.
- Last verified: Swift 6.2.4, macOS SDK 26.x, 2026-11-06

## Rule or observed behavior

- **Provenance.** The policy is adapted from Cider's note editor
  (`Features/Notes/NotesModel.swift`, `Editor/MarkdownEditor.swift`). Cider
  takes the first `image/*` clipboard file from its web view, refuses more
  than 25 MB, re-encodes to PNG with `NSBitmapImageRep`, caps at 40 MP, and
  writes into `<note-stem>.assets/`. It has no drop handler. Only the policy
  transfers; Rafu's editor is a TextKit 1 `NSTextView`, not a web view.
- **Who takes images.** Only a saved Markdown document (`isMarkdown`, not
  `isUntitled`) in an editable view. Everything else keeps `super.paste` and
  the existing drop forwarding byte for byte. The eligibility is a closure
  asked at paste and drop time, because a document can be saved or renamed
  after its editor is made.
- **Paste decision** (`MarkdownImagePastePolicy.decide`, pure):
  1. File URLs first. All image files (UTType conforms to `public.image`,
     extension compared lower-cased, SVG included) → copy them. Any non-image
     file → ordinary paste (the path text, as before).
  2. Raw data next: `public.png`, then `public.tiff`.
  3. If the pasteboard also has real text, the text wins. Office apps put a
     picture of copied cells or text beside the text itself; that must stay
     a text paste. A single `http`/`https`/`file` URL as the only text is a
     browser "Copy Image", so the image wins.
- **Drop decision.** An `.externalFiles` drag goes into the text only when
  every URL is an image file (`RafuTextView.insertsMarkdownImageDrop`). A
  mixed drop, a non-image drop, and every `.internalPayload` drag keep
  forwarding to `EditorDropForwardingScrollView` (open as editors / split).
  `draggingEntered`/`Updated`/`Exited`/`prepare` apply the same gate, so the
  split-preview overlay never appears for an image drop into Markdown, and
  the text view's own drop caret shows where the link will go.
- **Paste menu.** A plain-text `NSTextView` disables Paste when the
  pasteboard holds only image data. `validateUserInterfaceItem` enables it
  when the policy would take the image.
- **Caps** (checked before any full decode, all off the main actor in the
  `@concurrent` `MarkdownImageAssetWriter.store`):
  - PNG data and copied files: 25 MiB.
  - TIFF data: 64 MiB (TIFF is uncompressed; a 5K Retina screenshot is about
    59 MB).
  - 40 megapixels, read from `CGImageSourceCopyPropertiesAtIndex`. SVG has no
    pixel size and passes on bytes alone.
- **Storage.** PNG data is kept as it is; TIFF is decoded once and stored as
  PNG. Copied files keep their format and name. Pasted data is named
  `pasted-image-yyyyMMdd-HHmmss.png`. Names are made unique with
  `WorkspaceFileService.uniqueDestination` ("name 2.png"). The bytes go to a
  hidden temporary file in the folder and then to the final name with
  `renamex_np(…, RENAME_EXCL)`: the file appears whole and an existing file
  is never replaced.
- **Folder setting.** UserDefaults key `markdownImageFolder`, default
  `assets`, relative to the document's directory. `${name}` expands to the
  document's file name without its extension (`${name}.assets` gives
  Cider's layout). Refused: empty after expansion, leading `/` or `~`, any
  `..` component (checked after `${name}` expands). `.` components and
  repeated slashes are dropped. A blank field means the default.
- **Containment.** The folder is created one component at a time with
  `withIntermediateDirectories: false`, and after every component its
  `realpath` must be inside the document directory's `realpath`. A
  symlinked component that leaves the directory is refused before anything
  is created through it. Containment is the document directory, not the
  workspace root: external-open documents (ADR 0019) have no root, and the
  coordinator has no root list.
- **Link text.** `![Image](folder/name)`, one per line, with a leading
  newline when the caret is not at a line start. Every path component is
  percent-encoded down to unreserved ASCII (`A–Z a–z 0–9 - . _ ~`), so
  spaces, parentheses, and non-ASCII names make a valid link destination
  that `MarkdownImageReference.resolve(source:relativeTo:)` resolves to
  `.local` — the preview needs no change.
- **Insertion.** One `shouldChangeText` / `replaceCharacters` /
  `didChangeText` edit named "Insert Image(s)". It replaces the paste
  selection (or the drop point) when the text did not change while the
  image was written; otherwise it goes at the current selection. Several
  carets collapse to the target first. The document becomes dirty; the
  Split preview refreshes through `recordEditDelta`.
- **Undo removes the text only.** The stored file stays on disk. There is no
  asset cleanup, as in Cider. A second paste never cancels the first; only
  editor teardown cancels pending writes.
- **Errors** (invalid folder, escape, too large, unreadable, document moved
  while writing) beep and use the existing `document.errorMessage` alert.

## Why it matters

Without the gate a dropped image opens as an image tab (the pre-existing
behavior) and a pasted screenshot does nothing in a plain-text view. Without
the text-wins rule, copying cells from Excel or text from Word would insert a
picture instead of the text. Without component-wise `realpath` containment,
a symlinked `assets` folder could make Rafu write outside the document's
folder.

## Reproduction or evidence

- `Tests/RafuAppTests/MarkdownImagePasteTests.swift`: policy branches,
  folder templates, unique names, TIFF → PNG, `${name}`, percent-encoding
  round trip through `MarkdownImageReference`, symlink escape, caps, SVG.
- `Tests/RafuAppTests/EditorDragAndDropTests.swift`: all-image drop inserts;
  mixed, empty, non-Markdown, and internal drops forward.
- Manual: paste a ⌃⇧⌘4 screenshot into a saved `.md` in Edit and Split mode;
  drop two PNGs from Finder; drop a `.txt` (opens as before); ⌘Z.

## Verification

```bash
./script/build.sh
./script/test.sh --filter MarkdownImagePaste
./script/test.sh --filter EditorDragAndDrop
./script/build_and_run.sh --verify
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Markdown/MarkdownImagePaste.swift`
- `Sources/RafuApp/Editor/RafuTextView.swift` (drag overrides, `paste(_:)`,
  `insertMarkdownImageReferences`)
- `Sources/RafuApp/Editor/CodeEditorView.swift` (`insertMarkdownImages`)
- `Sources/RafuApp/Settings/MarkdownImageSettingsSection.swift`
- [`markdown-local-image-preview.md`](markdown-local-image-preview.md)
- ADR 0019 (external-open documents)
- `docs/plans/phases/issues-2026-11-06-fanout.md` (G3)
