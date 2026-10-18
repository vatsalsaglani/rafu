# Canvas whiteboard kinds and the `.rafuensemble` file

## Applies to

The whiteboard card kinds (`.shape`, `.stroke`, `.text`), the Mermaid card
(`.mermaid`), the tool palette and creation layer, and the `.rafuensemble`
file format with file-bound boards. Code: `Canvas/Domain/CanvasWhiteboard.swift`,
`Canvas/Domain/CanvasEnsembleFile.swift`, `Canvas/Persistence/CanvasEnsembleFileStore.swift`,
`Canvas/Integration/WorkspaceCanvasStore.swift`, `Canvas/Whiteboard/**`,
`Canvas/Adapters/CanvasMermaidCard.swift`.

## Last verified

- Swift 6.2 Linux toolchain (ubuntu24.04), 2026-10-18: pure domain code and its
  tests compiled and passed in a scratch package (17 tests). **macOS build
  pending.** The views, the file store (imports `Darwin`) and the store tests
  were checked only with `swiftc -parse` and `swift-format lint --strict`.

## Rule

### Saved format compatibility

- `CanvasCardContent` keeps synthesized `Codable`. A case is encoded under its
  name, so new cases do not change old ones: `{"note":{"snapshot":…}}` stays the
  same. An unlabeled payload encodes as `{"shape":{"_0":{…}}}`; that key is part
  of the format now. `CanvasWhiteboardTests.legacyBoardCompatibility` holds a
  board written before the change.
- `CanvasDocument.version` stays 1. A board with a new kind does not load in an
  older Rafu (decode error, listed as unavailable). This was accepted rather
  than a version bump, which an existing test forbids for version 1 readers.
- Style names (`CanvasInk`, `CanvasFill`, …) decode leniently: an unknown name
  falls back to the default, so a newer board still opens.
- Stroke points are `CanvasUnitPoint`: card-relative 0…1, stored as two
  integers in 1/10 000 units. `init` quantizes, so a round trip is exact and a
  512-point stroke stays a few KB.

### Bounds (`CanvasLimits`)

Mermaid source 16 KiB, text 8 KiB, shape label 1 KiB, 512 points per stroke.
A file is at most 4 MiB, 64 assets, 512 KiB per embedded image, 1.5 MiB of
embedded images in total. Card rects stay within `CanvasRect.isValid`
(96 × 64 … 2000 pt): small strokes pad to the minimum; a drawing larger than
2000 pt scales down uniformly. Freehand input is thinned to 4× the point
limit before Ramer–Douglas–Peucker, because RDP is quadratic on a zigzag
(6 000 points took 8 s in a debug build before, 0.7 s after).

### File format

See the header comment of `CanvasEnsembleFile`. Key points: `format` is
`dev.rafu.ensemble`, `formatVersion` 1, a newer version is refused from the
header before the body is decoded; paths are workspace-relative; terminal
layouts are never written (they can hold machine paths); JSON is pretty and
key-sorted so it diffs well.

### File-bound boards

- A board opened from a `.rafuensemble` file saves back to it, not to
  Application Support. `WorkspaceCanvasStore.fileBindings` holds the path and a
  64-bit FNV-1a fingerprint of the bytes last read or written.
- Expected-version check: before an atomic replace, the store re-reads the
  file and needs both the stored revision and the fingerprint to match. An
  outside edit that does not bump the revision (Git checkout) is a conflict.
  The check-then-write window is not locked across processes.
- A per-workspace index (`ensemble-files.index`, 32 entries) in the App Support
  Canvas folder maps board IDs to file paths, so a restored tab reopens its
  file through `open(_:)`.
- "Save Ensemble As…" writes a new file inside the workspace with a new board ID
  and opens it as its own tab; the original board is unchanged (same model as
  "Save Copy"). "Export Ensemble…" writes anywhere, embeds small PNG/JPEG/GIF
  images, and opens nothing. Opening a file whose embedded images are missing
  asks before writing them; existing files are never replaced.
- Finder opens: a file inside an open workspace opens there; otherwise its
  folder opens as a workspace (the CLI rule) and the file opens when that
  window's root appears (Observation, no timer).
- Info.plist (`script/build_and_run.sh`) exports `dev.rafu.ensemble`
  (conforms to `public.json`, extension `rafuensemble`) as entry 1 of
  `UTExportedTypeDeclarations`, and the script asserts it.

### Tools and keys

- Palette shortcuts use a local key monitor gated by `@Environment(\.isFocused)`
  of the board's focusable ancestor, `!contentIsActive`, and no `NSText` first
  responder. The monitor sees keys before the board's `onKeyPress` handlers.
- **Text is X, not T**: T keeps "add terminal". Escape returns to Select.
- Shapes, strokes and text have no tap gestures in their face: the shell's
  header gesture is their move handle, and it calls
  `CanvasWhiteboardEditing.shared.requestEditing(card)` on a double-click.
  A Mermaid card takes a double-click on its body.

## Why it matters

The saved format is now a public, committed file. Changing a case name,
`CanvasUnitPoint` encoding or the file header breaks users' repositories.

## Verification

```bash
swift test --filter "CanvasWhiteboardTests|CanvasEnsembleFileTests|CanvasEnsembleFileStoreTests"
./script/build_and_run.sh --verify   # asserts the exported UTType
```

## Related

`docs/plans/phases/ensemble-canvas.md` (X5, X9 addendum),
[`canvas-interaction.md`](canvas-interaction.md),
[`mermaid-native-preview.md`](mermaid-native-preview.md),
[`drag-and-drop-custom-uttype.md`](drag-and-drop-custom-uttype.md).
