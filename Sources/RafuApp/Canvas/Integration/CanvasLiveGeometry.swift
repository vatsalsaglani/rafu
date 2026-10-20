import Foundation
import Observation

/// Card rects that a move or a resize shows while the pointer is down. They
/// live outside the board document: a drag frame changes no `changeStamp`,
/// marks nothing dirty, schedules no save and adds no undo step. Only the
/// views that read `rects` update for each frame: each card's placement
/// modifier, the two edge layers (edges attached to a moving card follow it),
/// and the card that is resizing. The gesture commits once, on release
/// (`CanvasBoardState.showLiveRects` and `commitLiveRects`).
@Observable
@MainActor
final class CanvasLiveGeometry {
    /// Only the cards whose shown rect differs from the stored one.
    private(set) var rects: [CanvasCardID: CanvasRect] = [:]

    func rect(for id: CanvasCardID) -> CanvasRect? { rects[id] }

    /// Observation notifies on every write, so equal values are not written.
    func set(_ next: [CanvasCardID: CanvasRect]) {
        if next != rects { rects = next }
    }

    func clear() {
        if !rects.isEmpty { rects = [:] }
    }
}
