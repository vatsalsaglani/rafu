# Ensemble memory profile

- **Applies to:** the resident footprint of a window that shows an Ensemble
  board next to a terminal and an editor document (user report, 2026-11-06:
  about 320 MB with two image cards, one terminal, and one `.md` tab).
- **Last verified:** source review at dec163e, Swift 6.4.2, macOS 27.0.1,
  2026-11-06. No footprint number in this note is measured yet; the table at
  the end is for the user to fill.

## Rule or observed behaviour

### Static findings (source review, not measurements)

| Item | Value | Source |
|---|---|---|
| Image card decode, small card | 256 px longest side | `CanvasCardViews.swift:467` (`CanvasImageContent(... pixels: 256)`) |
| Image card decode, repository card | 1,024 px longest side (hard clamp 64...1,024) | `CanvasRepositoryCards.swift:190`, `CanvasPreviewLoader.thumbnailMaxPixels` |
| Image pool budget | 8 MiB reserved, 4 bytes per pixel plus 64 bytes per row; a lease past the budget throws `capacity` | `CanvasImagePool.swift` (`byteLimit`) |
| One 1,024 px lease | about 4.2 MB of the pool, so a second 1,024 px lease may be refused | same cost formula |
| Icon image cache | 300 images, 16 MiB cost, set in E-fix 1 (G5); `NSCache` also drops entries under memory pressure | `CanvasIconPackLibrary.swift` (`imageCountLimit`, `imageCostLimit`) |
| Decode source | Decoded from a file URL; no 16 MiB `Data` copy (E-fix 3, G4). The 16 MiB file cap stays | `CanvasPreviewLoader.swift` (`maxImageBytes`) |
| Terminal scrollback | SwiftTerm default, 500 lines per terminal | `memory-caps-and-pressure.md` |
| Editor undo | 200 levels per document | `CodeEditorView.swift` (`undoLevelCap`) |
| Ensemble undo cap (32 steps / 2 MiB) | Quoted from the advisor brief; not located in source at dec163e, so not verified here | n/a |

"The GPU does not reduce RAM." Metal textures and IOSurface backing stores are
charged to the same process `phys_footprint` on Apple silicon (unified
memory). Moving image rendering to the GPU was considered and rejected. Only
fewer or smaller pixels reduce the footprint.

### The document under a board (E-fix 2): no change

Question: does a document hidden under a selected board stay loaded because
the policy counts it as visible, and would hibernating it save memory?

Findings:

1. A board is its own tab in an editor group (`EditorTabResource.canvas`).
   When the board is the selected tab, the group's selected tab is not a file,
   so `WorkspaceSession.visibleDocumentIDs` already excludes every document in
   that group (`document(for:)` returns `nil` for a non-file tab). The
   "opacity 0 under the board" document in `EditorCanvasView` is therefore
   already a non-visible document. A different group that shows a file still
   counts as visible, correctly.
2. `DocumentHibernationPolicy` keeps visible, dirty, and the newest
   `keepLoadedLimit` (8) documents by access order loaded. A document the user
   just edited or read is among the newest, so it stays loaded by the grace,
   not by the visible rule. Marking it non-visible changes nothing unless more
   than 8 newer documents exist.
3. `EditorCanvasView` mounts every loaded document of the group
   (`loadedDocuments`), visible or not. Visible only sets `isVisible`, which
   hides the scroll view. A loaded hidden document therefore has the same
   TextKit storage, syntax tree, and highlighter as a visible one. Nothing
   extra is released by moving it from "graced" to "non-visible".
4. `selectEditorTab` calls `updateHibernationStates()` only for `.file`
   selections. Selecting a board, terminal, or auxiliary tab does not call it.
   The next file selection, close, move, or drop calls it, so a hidden document
   is re-evaluated then. With a normal tab count this releases nothing.
5. An auxiliary tab (Settings, diff, Agent History) keeps the group's selected
   tab on the file, so that document still counts as visible. It is the only
   case in which a hidden document counts as visible. It is the same
   newest-N situation, so excluding it would also save nothing.

Decision: no behaviour change. Hibernating a document under a board saves
nothing material unless the user has more than 8 other recent documents, and it
adds a disk reload plus a scroll/selection restore when the user returns. The
document under the board is the expected cost of "board selected, file still
open" and is already bounded by the working-set rule in
[`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md).
If the S4 measurement below shows the `.md` tab costing more than about 10 MB
and the user wants it released, the smallest change is: call
`updateHibernationStates(bypassNewestGrace: true)` for a group whose selection
is a board, with the invariants that visible and dirty documents never
hibernate and that the document returns through the existing
hibernated-to-refocus reload path. That was not implemented because no
evidence supports it.

`EnsembleHiddenDocumentTests` pins points 1 and 2.

### Where the memory most likely is (to confirm by measurement)

A normal window already holds the app, SwiftUI, SwiftTerm, and the shared
frameworks. Two 1,024 px cards are a few MB each as decoded bitmaps, plus
Core Animation backing stores for the board at Retina scale. The `.md` tab and
terminal are tens of MB at most. A 320 MB total therefore more likely comes
from baseline process cost and Core Animation or IOSurface layers than from
the editor document. The S0 to S6 table decides this; do not optimize before
reading it.

## Why it matters

The user wants lower Ensemble RAM without a large behaviour change. Hibernating
a graced document would have been a change with a visible cost (reload, scroll
restore) and no measured gain. Recording the finding prevents the same
investigation and the same tempting change from repeating.

## Reproduction and evidence

Run on Rafu Lightning only. Never use a bare `Rafu` process name; that is the
release editor. No GUI automation: the user performs the steps by hand.

Each step: let the app idle for about 20 seconds, then run

```sh
pid=$(pgrep -x "Rafu Lightning")
footprint "$pid" | head -40
vmmap --summary "$pid" | grep -E "CoreAnimation|CG raster|CG image|IOSurface|MALLOC_LARGE|MALLOC_SMALL|TOTAL"
heap -s "$pid" | sort -k2 -n -r | head -40
leaks "$pid" | head -20
```

Also read the Resources popover line "Open tabs: loaded/hibernated" at S4.

| Step | State | footprint total | CoreAnimation | CG raster / image | IOSurface | MALLOC_LARGE | MALLOC_SMALL | Open tabs loaded/hibernated | Notes |
|---|---|---|---|---|---|---|---|---|---|
| S0 | Idle, no tabs | | | | | | | | |
| S1 | Empty board open | | | | | | | | |
| S2 | S1 plus 2 image cards | | | | | | | | |
| S3 | S2 plus a running terminal | | | | | | | | |
| S4 | S3 plus a `.md` tab (board selected) | | | | | | | | |
| S5 | Icon Library opened, then closed | | | | | | | | |
| S6 | Board closed | | | | | | | | |

How to read it: S1 minus S0 is the board's own cost. S2 minus S1 is the two
cards (decode plus layers). S3 minus S2 is the terminal. S4 minus S3 is the
document under the board. S5 minus S4 should be near zero after the Icon
Library release (E-fix 1); a rise that stays means a leak. S6 minus S0 is the
residual after closing, which should be small.

## Verification

```sh
./script/test.sh --filter 'EnsembleHiddenDocumentTests|DocumentHibernation|EditorLayout'
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Models/WorkspaceSession.swift` (`visibleDocumentIDs`,
  `updateHibernationStates`, `selectEditorTab`)
- `Sources/RafuApp/Editor/DocumentHibernationPolicy.swift`
- `Sources/RafuApp/Views/EditorCanvasView.swift` (`loadedDocuments`,
  `selectedCanvas`)
- `Sources/RafuApp/Canvas/Adapters/CanvasImagePool.swift`,
  `CanvasPreviewLoader.swift`
- [`editor-working-set-and-hibernation.md`](editor-working-set-and-hibernation.md),
  [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md),
  [`memory-footprint-and-timer-tolerance.md`](memory-footprint-and-timer-tolerance.md)
- Phase: `docs/plans/phases/issues-2026-11-06-fanout.md` (G7)
