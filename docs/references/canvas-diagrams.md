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
- Derived frame bounds, the `diagram_build` layout and edge label placement:
  Swift 6.2 Linux toolchain, 2026-10-18. The pure parts
  (`CanvasFrameLayout`, `CanvasEdgeGeometry`, `CanvasAgentDiagramLayout`, and
  the real `CanvasAgentTools.swift` parser) passed Swift Testing tests in two
  scratch packages (34 tests with `defaultIsolation(MainActor)` for the app
  parts, and 13 tests for RafuCore; the 7 layout tests ran in both). The board
  tests (`Canvas frame bounds on a board`) and the views were not run: they
  need the macOS SDK.
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

- **A frame's rect is derived from its members.** The stored rect (saved
  format unchanged) is recomputed at one choke point,
  `CanvasBoardState.normalizeFrames(_:previous:)`, which runs inside `edit`,
  `setRect` / `setRects` (every gesture step) and `raiseDuringGesture`, so the
  refit is part of the same undo step. Undo and redo restore whole documents
  and do not normalize. `init(document:)` normalizes without marking the board
  dirty, so a board saved before this rule fits on open and is saved fitted
  with the next edit.
- The pure rule is `CanvasFrameLayout.normalized(_:previous:)`, in order:
  1. Follow: a frame whose origin changed carries each member (transitively)
     whose rect did not change in the same edit, by the same offset. The size
     of the new frame rect does not matter, so an agent `node_update` with x,
     y, width and height still moves the members.
  2. Fit: each frame with at least one member on the board gets
     `enclosingRect` of its members (32 pt padding, 36 pt title band); inner
     frames fit first; a membership cycle uses the stored rect of the frame
     that closes it. A frame whose members are all gone keeps its rect.
  3. Stack: each frame goes just behind its earliest member (array order is
     z-order), so Bring to Front on a frame, or Send to Back on a member, is
     corrected in the same step.
- A group drag must call `setRects` once per step with every moved card.
  Calling `setRect` card by card would let the follow step see the frame
  moved while its members had not, and move them a second time.
- Frames have no resize handles, no Make Larger/Smaller accessibility
  actions and no resize menu items (`CanvasCardContent.hasDerivedSize`);
  `resizeSelection` ignores a frame. The title stays editable. Frame edges are
  not snap targets, because they follow the card being dragged.
- Members are never removed from `memberIDs` by a move: dragging a member out
  grows the frame. Members that are not on the board are ignored.
- The frame face has no follow or restack logic of its own any more (the
  earlier view-level safety net ran only while the face was mounted and could
  fight the board rule).
- A frame is at most 2,000 pt per side (the stored `CanvasRect` bound), so a
  frame around a very wide selection does not fully enclose it. The
  `diagram_build` layout shrinks its gaps to stay inside that bound.

### Diagram layout (`diagram_build`)

`CanvasAgentDiagramLayout` (RafuCore, pure and deterministic) places the
nodes; the app then adds the cards and links in one edit and the frame in a
second edit.

- Layers: one layer after the furthest predecessor; cycles break in node order.
- Main chain: the longest forward path is on one axis (slot 0). Ties prefer an
  end that no skip edge reaches, then spec order.
- Other nodes take integer slots beside the axis (below/above for `right`,
  right/left for `down`), ordered by the barycentre of their predecessors
  (forward sweep), then of their successors (backward sweep). Ties with the
  axis alternate below and above.
- A node reached by a skip edge (two or more layers) moves outward, up to three
  slots, when it is the outermost node of its layer and the straight line from
  the source would pass within half a node of a node in between.
- Gaps for `right`: after each layer, `max(96, w + 56)` capped at 320, where
  `w = 7.2 × characters + 16` for the longest label on an edge that crosses
  that gap. Rows: 64 pt, or 96 pt when a labelled edge runs between rows (same
  layer, or two or more rows apart in adjacent layers). For `down` the roles
  swap: layer gaps are 64 / 96 pt and the row gap uses the width rule.
- If the layout would exceed one frame (2,000 pt per side less padding and
  title band), gaps shrink proportionally down to 48 pt.
- `bounds(_:)` uses the app's frame padding and title band, so it equals
  `CanvasFrameLayout.enclosingRect` (a RafuApp test checks both).

### Edge routing and labels

- `CanvasEdgeGeometry.routes(for:rects:background:)`: frames are passed as
  `background`, so they can be edge ends but never obstacles. Before, every
  edge inside a frame "crossed" the frame and got a 24 pt bend.
- When the straight segment crosses a card, the bend (perpendicular, away from
  the nearest crossed card) grows through 24, 60, 108, 156 and 216 pt until the
  sampled curve crosses no card; otherwise the fewest crossings win. A long
  skip edge therefore arcs over the row of cards it skips.
- `labelPlacement(for:avoiding:limit:)` puts the pill at the arc-length middle
  of the curve. The curve runs border to border, so this is the middle of the
  visible part of the edge. The pill width is limited so that it keeps 6 pt
  from every non-frame card beside its row, at least 28 pt (an ellipsis) and at
  most 160 pt (480 pt while hovered). The full label stays in `.help` and the
  accessibility label.
- `CanvasEdgeLabelWidthLayout` sizes the text to `min(ideal, maximum)` so it
  truncates with an ellipsis and a short label keeps a tight pill. Do not use
  `.frame(maxWidth:)` plus `.fixedSize()` for this: whether a flexible frame
  passes a smaller width to the text under a nil proposal is not something the
  code should depend on. The PNG / PDF / GIF export uses the same placement.

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
drag path owned by another workstream. Before frame bounds were derived, a
frame kept the rect from its creation: after an agent moved or resized members
(or the frame), the frame no longer covered them, and its title drew under a
member. One rule at the board choke point replaces the creation-time rect and
the view-level follow, so no two mechanisms move the same cards.

## Verification

On a Mac:

```bash
./script/test.sh --filter "Canvas diagram|Canvas icon|Canvas frame|Canvas edge geometry|diagram|layout"
./script/build_and_run.sh --verify
```

Manual checks: import each vendor ZIP and a folder; one-click download with
Cancel and with networking off (expect the failure message); a zip with a `..`
entry is refused; Convert to Frame (⌃⌘G) then drag, arrow-key move, Bring to
Front and undo; drag a member out of a frame (the frame grows live) and undo
once; ask an agent for the serverless image diagram (`diagram_build` with a
frame) and check that the frame covers every node and that no label pill
covers a node; export PNG 1×/2×/3×, PDF and GIF, and open the GIF in Preview;
SVG vendor icons render in the library and on cards (`NSImage(contentsOf:)`).

## Related

- Code: `Sources/RafuApp/Canvas/Diagram/`, `CanvasCardViews.swift`
  (`startMove`, `updateMove`, `raiseIfNeeded`), `CanvasToolPalette.register`,
  `CanvasBoardState.normalizeFrames`, `CanvasEdgeGeometry.labelPlacement`,
  `Sources/RafuCore/CanvasBridge/CanvasAgentDiagramLayout.swift`.
- Tests: `Tests/RafuAppTests/Canvas/CanvasDiagramTests.swift` (`Canvas frames`,
  `Canvas frame bounds on a board`), `CanvasEdgeGeometryTests.swift`,
  `Tests/RafuCoreTests/CanvasAgentDiagramLayoutTests.swift`.
- Phase: [`../plans/phases/ensemble-canvas.md`](../plans/phases/ensemble-canvas.md)
  (Addendum X9). Reference: [`canvas-interaction.md`](canvas-interaction.md),
  [`canvas-whiteboard-and-ensemble-file.md`](canvas-whiteboard-and-ensemble-file.md).
