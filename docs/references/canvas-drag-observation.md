# Canvas drag observation and live geometry

## Applies to

Ensemble (Canvas) card moves and resizes: `CanvasCardShell` header and resize
gestures, `CanvasBoardState.showLiveRects` / `commitLiveRects`,
`CanvasLiveGeometry`, the board's `CanvasCardPlacement` modifier, the edge
layers (`CanvasEdgeScene.displays`), snap guides, card shadows, and the
mounting of resize zones and connection ports.

## Last verified

- Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1 (26A434), arm64.
- Verified by build and by the pure tests below. The frame-time and memory
  effect was diagnosed by a profiler pass before the change; it was **not**
  re-measured after the change (see "Still to measure").

## Rule

1. **No document write per drag frame.** A move or resize shows its rects
   through `board.showLiveRects(_:)`, which writes only
   `board.liveGeometry.rects`. Release commits once with
   `commitLiveRects(_:)` and then `endGesture()`: one undo step (ADR 0025
   semantics are unchanged), one dirty mark, one `requestSave`.
2. **`changeStamp` is a broad dependency.** `cards`, `connections`, `viewport`,
   `title`, `canUndo` and `canRedo` all read `changeStamp`, and every card body
   reads `board.viewport.scale`. Any `markDirty()` therefore re-runs the board
   body and every `CanvasCardShell` body. Do not put per-frame state behind
   `changeStamp`.
3. **Per-frame readers are small.** Only these read `liveGeometry.rects`:
   `CanvasCardPlacement` (a `ViewModifier` that applies frame, scale and
   offset for each card), `CanvasEdgeScene.displays` (read after its
   no-connections guard, so a board without edges ignores drag frames), and
   the resizing card itself (`shownRect`, read only while `resizeStart` is
   set). A modifier body re-runs without re-running its `content`, so the
   card's own body does not run per frame.
4. **Child views with closure properties re-run whenever the parent re-runs.**
   `CanvasCardShell` takes several closures, so SwiftUI cannot prove it
   unchanged. Keeping the board body (`WorkspaceCanvasView`) stable during a
   drag is what keeps the cards stable. For the same reason the snap guides
   are their own view (`CanvasSnapGuideLayer`): guides change on many drag
   frames and must not re-run the board body.
5. **Observation notifies on every write, equal or not.** Guard writes to
   observed or `@State` values that a drag repeats: `CanvasLiveGeometry.set`,
   `CanvasInteractionState.show(guides:)`, and `snappedX`/`snappedY`.
6. **Frames refit live.** `showLiveRects` runs `normalizeFrames` against the
   stored document and keeps only the rects that differ, so a frame still
   grows while a member is dragged, exactly as the commit will.
7. **No live rect outlives its gesture.** `endGesture()` clears live rects, an
   invalid rect keeps the card's last live rect, and a card that disappears
   mid-gesture commits what it showed (`disappeared()`).
8. **One blur pass while lifted.** The lifted card keeps one blurred shadow;
   the contact hairline becomes a clear, unblurred no-op so the lift still
   animates. The resting card keeps two quiet shadows.
9. **Mount hit targets only where they are used.** `CanvasResizeZones` (eight
   zones) mount only on the hovered, selected or resizing card; the four port
   dots mount only on the hovered card, while one of its ports is hovered
   (`isPortHovered`: a port reaches past the card's edge, outside the card's
   own hover area) or while one is dragged (`isDraggingPort`), so unmounting
   never pulls a dot from under the pointer or cancels a port drag.

## Why it matters

Before this change each drag frame called `setRects`, which bumped
`changeStamp`. Every card body re-ran, the save loop
(`WorkspaceCanvasStore.writeUntilClean`, which repeats while `isDirty`) kept
writing the board during the drag, and the double shadow on the lifted card
drove RenderBox/Metal work; a transient footprint of about +100 MB was seen
during a drag.

## Evidence and verification

```bash
swift test --filter CanvasLiveGeometryTests
swift test --filter CanvasFrameBoardTests
swift test --filter CanvasBoardStateTests
```

`CanvasLiveGeometryTests` proves: 30 drag frames change no `changeStamp`, no
`isDirty`, no save request and no undo entry; release is exactly one stamp
bump, one save request and one undo step; a frame refits live; equal rects are
not live; an invalid rect keeps the last live rect; `endGesture` clears.

## Still to measure

Record an Instruments SwiftUI + Allocations trace of a card drag on a board of
about 20 cards in a Release build: card body counts per frame should be near
zero for unmoved cards, no `CanvasPersistenceStore.save` during the drag, and
no transient footprint spike.

## Related

- `Sources/RafuApp/Canvas/Integration/CanvasLiveGeometry.swift`
- `Sources/RafuApp/Canvas/Integration/CanvasBoardState.swift`
- `Sources/RafuApp/Canvas/Views/CanvasCardViews.swift`
- `Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift`
- `Sources/RafuApp/Canvas/Views/CanvasEdgeLayer.swift`
- [`canvas-interaction.md`](canvas-interaction.md),
  [`canvas-diagrams.md`](canvas-diagrams.md) (frame bounds),
  ADR 0025 (undo semantics).
