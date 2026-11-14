import Foundation

/// Where one wheel or trackpad scroll event over the board goes.
nonisolated enum CanvasScrollRoute: Equatable, Sendable {
    /// The board pans.
    case board
    /// The board zooms (⌘ or ⌃ held).
    case zoom
    /// The event goes on to the view under the pointer (a card's own scroll
    /// view, a content-active terminal or web card).
    case content
}

/// The scroll position of one scroll view under the pointer, in its
/// document's units. `offset` is measured from the top-leading corner, so
/// `offset.y == 0` is the top of the document.
nonisolated struct CanvasScrollExtent: Equatable, Sendable {
    /// A scroll view counts as "at its end" within this distance.
    static let endTolerance = 0.5

    var offset: CGPoint
    var contentSize: CGSize
    var visibleSize: CGSize

    /// Whether the view can still move its content for this delta.
    ///
    /// The deltas use AppKit's `scrollingDeltaX/Y` convention, which already
    /// includes the user's natural-scrolling setting: a positive `deltaY`
    /// moves toward the top of the document, a negative one toward the
    /// bottom; a positive `deltaX` moves toward the leading edge. Only the
    /// dominant axis counts (vertical on a tie). Zero deltas ask whether the
    /// view overflows on any axis.
    func canScroll(deltaX: Double, deltaY: Double) -> Bool {
        let tolerance = Self.endTolerance
        let maxX = Double(contentSize.width - visibleSize.width)
        let maxY = Double(contentSize.height - visibleSize.height)
        if deltaX == 0, deltaY == 0 {
            return maxX > tolerance || maxY > tolerance
        }
        if abs(deltaY) >= abs(deltaX) {
            return deltaY > 0
                ? Double(offset.y) > tolerance : Double(offset.y) < maxY - tolerance
        }
        return deltaX > 0
            ? Double(offset.x) > tolerance : Double(offset.x) < maxX - tolerance
    }
}

/// Routes wheel and trackpad scroll events over the board. Pure: the AppKit
/// monitor (`CanvasScrollBridge`) maps each `NSEvent` to an `Input` and acts
/// on the returned route.
///
/// Rules, in order, decided once per gesture:
/// 1. Space held or the Hand tool → the board pans.
/// 2. Pointer on the body of the content-active card → content (any
///    modifier; terminal and web cards rely on this).
/// 3. ⌘ or ⌃ held → the board zooms.
/// 4. A scroll view under the pointer can scroll on the dominant axis in the
///    delta's direction → content. Unless the board panned less than
///    `panStreak` ago: then the board keeps the new gesture, so a card that
///    slides under the pointer does not catch a run of pans.
/// 5. Else the board pans.
///
/// A trackpad gesture is decided at `.began` and keeps its route through
/// `.changed`, `.ended` and momentum; a scroll view that reaches its end
/// mid-gesture does not hand the rest of the gesture to the board. A legacy
/// wheel (no phases) keeps the last route while ticks are less than
/// `legacyLatch` apart. While the board owns a gesture, ⌘/⌃ and Space are
/// read per event, so pressing ⌘ mid-pan zooms as before.
nonisolated struct CanvasScrollRouter: Sendable {
    enum Phase: Sendable {
        /// Trackpad gesture start (`phase == .began`).
        case began
        /// Trackpad gesture update (`.changed` or `.stationary`).
        case changed
        /// Fingers lifted (`phase == .ended`).
        case ended
        /// Inertia after the fingers lifted (`phase == []`, `momentumPhase != []`).
        case momentum
        /// A wheel without phases (both `phase` and `momentumPhase` empty).
        case legacy
        /// Fingers rest on the trackpad without moving.
        case mayBegin
        /// The system cancelled the gesture.
        case cancelled
    }

    struct Input: Sendable {
        var phase: Phase
        var timestamp: TimeInterval
        var deltaX: Double
        var deltaY: Double
        var zoomModifier: Bool
        var panOverridesCards: Bool
        var overActiveCardBody: Bool
        /// Scroll views under the pointer, innermost first. Empty when there
        /// is none. Read only when `needsDecision` is true.
        var extents: [CanvasScrollExtent]
    }

    static let legacyLatch: TimeInterval = 0.25
    static let panStreak: TimeInterval = 0.3

    private var latched: CanvasScrollRoute?
    private var lastLegacy: TimeInterval?
    private var lastBoardPan: TimeInterval?

    init() {}

    /// Whether `route` will make a fresh decision for this event and so
    /// reads `overActiveCardBody` and `extents`. The adapter hit-tests only
    /// then.
    func needsDecision(_ phase: Phase, at timestamp: TimeInterval) -> Bool {
        switch phase {
        case .began: true
        case .mayBegin, .cancelled: false
        case .changed, .ended, .momentum: latched == nil
        case .legacy:
            latched == nil || lastLegacy.map { timestamp - $0 >= Self.legacyLatch } ?? true
        }
    }

    mutating func route(_ input: Input) -> CanvasScrollRoute {
        let decides = needsDecision(input.phase, at: input.timestamp)
        let route: CanvasScrollRoute
        switch input.phase {
        case .mayBegin:
            latched = nil
            return .content
        case .cancelled:
            route = latched.map { resolveLatched($0, input) } ?? .content
            latched = nil
        case .legacy:
            lastLegacy = input.timestamp
            fallthrough
        case .began, .changed, .ended, .momentum:
            if decides || latched == nil {
                route = decide(input)
                latched = route
            } else {
                route = resolveLatched(latched ?? .board, input)
            }
        }
        if route == .board { lastBoardPan = input.timestamp }
        return route
    }

    /// A content gesture stays content. A board gesture re-reads Space and
    /// ⌘/⌃ per event, as the board's monitor always did.
    private func resolveLatched(_ route: CanvasScrollRoute, _ input: Input) -> CanvasScrollRoute {
        switch route {
        case .content: .content
        case .board, .zoom:
            !input.panOverridesCards && input.zoomModifier ? .zoom : .board
        }
    }

    private func decide(_ input: Input) -> CanvasScrollRoute {
        if input.panOverridesCards { return .board }
        if input.overActiveCardBody { return .content }
        if input.zoomModifier { return .zoom }
        let inStreak = lastBoardPan.map { input.timestamp - $0 < Self.panStreak } ?? false
        if !inStreak,
            input.extents.contains(where: {
                $0.canScroll(deltaX: input.deltaX, deltaY: input.deltaY)
            })
        {
            return .content
        }
        return .board
    }
}
