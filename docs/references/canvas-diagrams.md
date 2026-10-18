# Canvas diagrams: icon packs, frames and export

## Applies to

Workstream X9 of the Ensemble canvas round 2: `Sources/RafuApp/Canvas/Diagram/**`,
the built-in Common pack in `Sources/RafuApp/Resources/DiagramPacks/common.json`,
imported vendor icon packs, one-click vendor downloads, frames, and PNG / PDF /
animated GIF export.

## Last verified

- Mac review: Apple Swift 6.4, macOS 27.0.1 (26A434), arm64, 2026-10-18.
  Canonical Lightning build/launch and full package tests. Live Mermaid
  editing exposed the export path issue described below; the fixed PNG export
  was opened and its flowchart pixels inspected. The follow-up Mac pass
  downloaded the pinned Google Cloud pack through the Lightning UI and
  imported 19 icons. AWS and Azure runtime downloads were not repeated.
- Initial Linux verification: Swift 6.2 (swift.org, ubuntu24.04), 2026-10-18.
- Pure logic (search, vendor layout detection, archive and SVG checks, frame
  math, GIF planning, export bounds) passed 26 Swift Testing tests in a scratch
  package, including runs over the real file listings of the three official
  vendor ZIPs downloaded on 2026-10-18.

## Rules

### Contracts

- Value types: `CanvasFrame(title:memberIDs:style:)` and
  `CanvasServiceIcon(packID:iconID:label:)`; both `Codable`, `Equatable`,
  `Sendable`, with `validate()` (called from `CanvasCardContent.validate()`).
  An unknown `CanvasFrameStyle` decodes as `.neutral`.
- `CanvasDiagramCardFace(card:board:)` draws `.frame` and `.serviceIcon`; X5's
  `CanvasWhiteboardCardFace` routes to it and `usesCardChrome` is false for both.
- `@MainActor enum CanvasDiagramService`: `searchIcons(query:limit:)`,
  `createFrame(title:memberIDs:in:session:)` (a `CanvasID` or a
  `CanvasBoardState`), `addServiceIcon(_:at:in:session:)`, and
  `export(boardID:target:format:session:theme:)`.
- Board helpers (`CanvasDiagramBoardActions.swift`): `cardIDsMovingTogether(with:)`,
  `moveFrame(_:by:)`, `createFrame`, `convertSelectionToFrame`, `addServiceIcon`,
  `setServiceIconLabel`, `setFrameStyle`, `selectFrameMembers`.

### Frames

- A frame is a card stored **before** its earliest member in `board.cards`
  (array order is z-order), so it draws behind them.
- The card drag (`CanvasCardShell.startMove`) and click-raise move the set
  `cardIDsMovingTogether(with:)`, so members move and rise with their frame.
- A safety net in the frame face covers every other path (keyboard move, Align,
  agent edits, Bring to Front): members whose rects did not change in the same
  step follow a frame that moved without resizing, and a raised frame is put
  back behind its members. These follow-ups use `setRect` / `refreshResources`
  and add no undo step of their own; the triggering edit's undo restores both.
  The safety net only runs while the frame face is mounted.
- A frame is at most 2,000 pt per side (the stored `CanvasRect` bound), so a
  frame around a very wide selection does not fully enclose it.

### Icon packs

- Common: SF Symbols listed in `common.json` (57 entries). The file is a
  SwiftPM `.copy` resource; the test decodes it from the source tree.
- Imported packs live in `<Application Support>/DiagramPacks/<pack id>/` with
  `index.json` and `icons/`. Pack ids: `aws`, `azure`, `google-cloud`,
  `custom-<slug>`. Re-importing a vendor replaces its pack.
- Import order: `zipinfo -1` listing (every entry name must pass
  `isSafeArchiveEntry`: no absolute, `~`, drive, `..`, backslash or control
  characters), `zipinfo -t` totals (≤ 60,000 entries, ≤ 2 GiB uncompressed,
  archive ≤ 1 GiB), `ditto -x -k` into a private temp folder, then a scan that
  keeps only regular, non-symlink `.svg` / `.png` files ≤ 2 MiB. PNGs must have
  the PNG signature; SVGs must not contain scripts, event handlers,
  `foreignObject`, entities, a DOCTYPE or external `href`/`url()`. The pack is
  staged and moved into place in one step, so a failure leaves no partial pack.
  All processes run as an executable plus an argument array.
- Real layouts (2026-10-18): AWS `Architecture-Service-Icons_*/Arch_<Category>/<size>/Arch_<Name>_<size>.svg`
  (plus `@5x` PNGs, `Resource-Icons_*`, `Category-Icons_*`, `Architecture-Group-Icons_*`,
  `__MACOSX` and `.DS_Store` noise); Azure
  `Azure_Public_Service_Icons/Icons/<category>/<nnnnn>-icon-service-<Name>.svg`;
  Google Cloud `Unique Icons/<Product>/SVG/<File>-512-color[-rgb].svg`, where
  the folder holds the real product name. Results: AWS 808 icons in 28
  categories, Azure 712 in 29, Google Cloud 19. Every SVG in the three packs
  passed the SVG policy.

### One-click download

- Pinned URLs, sizes and SHA-256 in `CanvasIconPackDownloads.sources`
  (computed from files fetched on 2026-10-18):
  - AWS `d1.awsstatic.com/.../Icon-package_07312026...zip`, 13,988,918 bytes,
    `d2d166c4…6526`.
  - Azure `arch-center.azureedge.net/icons/Azure_Public_Service_Icons_V24.zip`,
    1,033,184 bytes, `921594cc…1141`.
  - Google Cloud `services.google.com/fh/files/misc/core-products-icons.zip`,
    318,678 bytes, `6531a10f…ce`.
- The fetch happens only after a click and a confirmation alert that shows the
  vendor, the source URL, the size and the vendor's terms page. The request URL,
  every redirect hop, and the final URL must be HTTPS on the vendor allowlist; the
  body is capped at 200 MiB and must match the pinned hash; the file is then
  imported through the same importer as a user-chosen ZIP.
- `CanvasIconPackRedirectPolicy` checks each redirect before URLSession sends
  it. A final-URL check alone is too late: an intermediate redirect can already
  contact an unapproved host. Downloads use a private ephemeral session and
  do not send cookies. The redirect regression test covers an unrelated host,
  another vendor, HTTP, credentials, a non-default port, and loopback.
  Verify with `./script/test.sh --filter CanvasIconPackDownloadTests`.
- When a vendor moves or replaces its file, the hash or URL fails and the UI
  says "Download failed — use Import Icon Pack… with the file from <page>".
  Update the pins by re-reading each vendor page.
- No vendor asset is in the repository. Users import vendor icons under each
  vendor's terms (AWS, Microsoft and Google publish their icons for use in
  architecture diagrams).

### Export

- Files go to `<workspace>/exports/` (created when needed); the folder and the
  file must resolve inside the workspace, so a symlinked `exports` that points
  outside is refused. The UI reveals the file in Finder; the service (agents)
  does not.
- PNG and GIF render once with `ImageRenderer` on the main actor, copy the
  pixels into a `Sendable` RGBA buffer, and encode off the main actor with
  ImageIO. PDF renders through `ImageRenderer.render` into a PDF context.
- Caps: PNG ≤ 4,096 px per side (64 MB per RGBA frame); GIF ≤ 1,600 px per
  side and ≤ 120 frames, 1–10 s at 5–30 fps, delay rounded to 1/100 s, loop
  forever.
- GIF dots move by arc length along each link's Bézier with ease-in-out: a
  relationship carries one dot from source to target per loop; a message link
  also carries one back, half a loop later. Dot colour is the theme accent with
  a background-coloured ring.
- Native-view cards (terminal, web, docked app) export a summary face; notes
  export their current text excerpt.
- `ImageRenderer` does not mount a view's `.task`. Mermaid cards must prepare
  their raster images before the static export view is constructed; reusing
  the live card otherwise exports its loading state. Preparation parses and
  renders off the main actor, checks cancellation between diagrams, and limits
  all retained thumbnails together to four million pixels. Malformed diagrams
  export an explicit error face.
- Pixel scale must have no fixed minimum: two nodes 200,000 points apart need
  a scale below 0.1 to stay within the PNG/GIF caps. The regression checks both
  caps at that distance.
- macOS Foundation can return different `/private` spellings for an existing
  folder and a missing child. Resolve the nearest existing ancestor, then
  append missing path components before the containment comparison. A live
  export from `/tmp/rafu-pr3-ui-review` previously failed with “Exports must
  stay inside the workspace folder.” The writer regression covers a workspace
  symlink, a new export leaf, and refusal of an exports symlink outside the
  workspace. This path check is not a filesystem sandbox against concurrent
  replacement of directories by another local process.

## Why it matters

Archive import and network download are the risky parts: they take untrusted
bytes into Application Support. Frames depend on array-order z-order and on a
drag path owned by another workstream, so the follow and restack rules must stay
consistent with `CanvasCardShell`.

## Verification

On a Mac:

```bash
./script/test.sh --filter "Canvas diagram|Canvas icon|Canvas frames"
./script/build_and_run.sh --verify
```

Manual checks: import each vendor ZIP and a folder; one-click download with
Cancel and with networking off (expect the failure message); a zip with a `..`
entry is refused; Convert to Frame (⌃⌘G) then drag, arrow-key move, Bring to
Front and undo; export PNG 1×/2×/3×, PDF and GIF, and open the GIF in Preview;
SVG vendor icons render in the library and on cards (`NSImage(contentsOf:)`).

## Related

- Code: `Sources/RafuApp/Canvas/Diagram/`, `CanvasCardViews.swift`
  (`startMove`, `raiseIfNeeded`), `CanvasToolPalette.register`.
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
  (Addendum X9). Reference: [`canvas-interaction.md`](canvas-interaction.md),
  [`canvas-whiteboard-and-ensemble-file.md`](canvas-whiteboard-and-ensemble-file.md).
