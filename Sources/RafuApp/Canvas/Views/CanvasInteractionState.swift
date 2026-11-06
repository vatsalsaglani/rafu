import AppKit
import Observation
import SwiftUI

/// Transient pointer state for one board window: snap guides, the marquee and
/// the Add popover anchor. None of it is saved or undoable.
@Observable
@MainActor
final class CanvasInteractionState {
    private(set) var guides: [CanvasSnapGuide] = []
    var marquee: CGRect?
    /// View-space point of a double-click on the empty board; shows the Add popover.
    var addPopoverAnchor: CGPoint?
    /// Board-space point where a card made from that popover is centred.
    var addPopoverBoardPoint: CGPoint?
    /// The pointer is over the zoom capsule (or the overview above it), so
    /// the overview shows (UX Round A, B3).
    var overviewHover = false
    /// True for `RafuMotion.overviewPanHold` after the last pan step, so the
    /// overview stays a moment after a pan ends.
    private(set) var overviewPanHold = false
    @ObservationIgnored private var overviewHoldTask: Task<Void, Never>?
    @ObservationIgnored private var guideKeys: Set<String> = []

    /// Shows the overview now and keeps it for `RafuMotion.overviewPanHold`
    /// after the last call. One sleeping task at a time; each call restarts it.
    func holdOverviewAfterPan() {
        if !overviewPanHold { overviewPanHold = true }
        overviewHoldTask?.cancel()
        overviewHoldTask = Task { [weak self] in
            do {
                try await Task.sleep(for: RafuMotion.overviewPanHold)
            } catch {
                return
            }
            self?.overviewPanHold = false
        }
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Shows the current guides. A haptic plays once for each newly entered guide.
    func show(guides next: [CanvasSnapGuide]) {
        if CanvasSnapGuide.hasNewEntry(previous: guideKeys, current: next) {
            RafuHaptics.alignment(channel: "snap")
        }
        guideKeys = Set(next.map(\.key))
        if next.isEmpty {
            clearGuides()
        } else if guides != next {
            // Observation notifies on every write; a held snap repeats the
            // same guides on many drag frames.
            guides = next
        }
    }

    /// Moving away hides a guide at once; releasing the card fades it out.
    func clearGuides(fade: Bool = false) {
        guideKeys = []
        guard !guides.isEmpty else { return }
        if fade, !reduceMotion {
            withAnimation(RafuMotion.guideFadeOut) { guides = [] }
        } else {
            guides = []
        }
    }
}

/// Reduce Motion aware animation helpers for board changes made outside views.
enum CanvasMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func animateThrowing(
        _ animation: Animation, reduced: Animation? = RafuMotion.reducedFade,
        _ body: () throws -> Void
    ) throws {
        try withAnimation(
            RafuMotion.resolve(animation, reduceMotion: reduceMotion, reduced: reduced), body)
    }

    /// Runs `body` with `animation`, or with `reduced` (default none) under Reduce Motion.
    static func animate(
        _ animation: Animation, reduced: Animation? = nil, _ body: () -> Void
    ) {
        withAnimation(
            RafuMotion.resolve(animation, reduceMotion: reduceMotion, reduced: reduced), body)
    }
}
