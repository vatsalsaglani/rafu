import AppKit
import SwiftUI

/// Pure rules shared by `WorkbenchSplitHandle` and its headless tests, like
/// `TerminalGroupSplitPresentation` beside `TerminalGroupSplitView`. Unlike
/// the Terminal Group inner split, this boundary is a plain SwiftUI surface,
/// not an AppKit `NSSplitView` bridge: an outer `HSplitView` reports no
/// divider callbacks and cannot collapse by drag (see
/// `nssplitview-divider-position-quantization.md`), and a second
/// `NSSplitView` representable here would add another hosting view that
/// re-derives the window's titlebar safe area on its own schedule (see
/// `flat-window-chrome-titlebar-merge.md` rule 2).
nonisolated enum WorkbenchSidebarResize {
    /// Matches the pane's former `HSplitView` frame triplet (grown from the
    /// Files-only 200/260/420 to fit Search and Source Control).
    static let minimumWidth: Double = 220
    static let idealWidth: Double = 300
    static let maximumWidth: Double = 560

    /// A release below `minimumWidth - collapseSlack` collapses the sidebar
    /// instead of snapping back to `minimumWidth`.
    static let collapseSlack: Double = 40

    /// Dragging outward from the collapsed edge past this many points
    /// reopens the sidebar at its stored width.
    static let reopenThreshold: Double = 32

    static func clamp(_ width: Double) -> Double {
        guard width.isFinite else { return idealWidth }
        return min(max(width, minimumWidth), maximumWidth)
    }

    static func shouldCollapse(proposedWidth: Double) -> Bool {
        proposedWidth < minimumWidth - collapseSlack
    }

    static func shouldReopen(dragTranslation: Double) -> Bool {
        dragTranslation > reopenThreshold
    }

    /// A pointer drag's horizontal translation, as growth of the sidebar.
    /// On the leading edge the sidebar grows when the pointer moves right.
    /// On the trailing edge it grows when the pointer moves left, so the sign
    /// flips. Every width, collapse and reopen rule reads this value, never
    /// the raw translation.
    static func outwardTranslation(_ translation: Double, edge: WorkbenchSidebarEdge) -> Double {
        edge == .leading ? translation : -translation
    }
}

/// The gutter around the workbench deck card, and where the split handle
/// sits on the seam beside it. The handle takes no layout width (window gap
/// tightening 2): it is an overlay across the seam, so the gutter alone sets
/// the gap.
/// - Open sidebar: the leading padding is `RafuMetrics.deckInsetLeading`
///   (8; was 6 + the handle's 10 = 16).
/// - Collapsed sidebar: the rail's empty deck-side strip plus the leading
///   padding make `RafuMetrics.deckGapCollapsedRail` (5; was 3 + 10 = 13),
///   so the padding is that gap less the strip, never below zero.
nonisolated enum WorkbenchDeckLane {
    /// `edge` is the side the rail is on. The collapsed-rail rule applies to
    /// the deck's rail-side padding: leading on the leading edge, trailing on
    /// the trailing edge. In Zen mode there is no rail, so callers pass
    /// `isSidebarCollapsed: false` and get the plain insets.
    static func padding(
        isSidebarCollapsed: Bool,
        railDeckSideInset: CGFloat,
        insets: EdgeInsets = WorkbenchDeckLane.insets,
        collapsedGap: CGFloat = RafuMetrics.deckGapCollapsedRail,
        edge: WorkbenchSidebarEdge = .leading
    ) -> EdgeInsets {
        var padding = insets
        if isSidebarCollapsed {
            let gap = max(0, collapsedGap - railDeckSideInset)
            if edge == .leading {
                padding.leading = gap
            } else {
                padding.trailing = gap
            }
        }
        return padding
    }

    static let insets = EdgeInsets(
        top: RafuMetrics.deckInsetTop,
        leading: RafuMetrics.deckInsetLeading,
        bottom: RafuMetrics.deckInsetBottom,
        trailing: RafuMetrics.deckInsetTrailing
    )

    /// How far the handle's invisible hit area reaches into the deck card,
    /// past the visible gap, so the seam stays easy to grab now that the
    /// gap is narrow.
    static let handleDeckOverlap: CGFloat = 3

    /// The handle's hit area across the seam. `x` is measured from the
    /// leading pane's trailing edge (the sidebar's, or the rail's while the
    /// sidebar is collapsed); a negative `x` starts inside that pane.
    struct HandleHitArea: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    /// Open: from the sidebar edge across the gap and `handleDeckOverlap`
    /// into the card (it never covers the sidebar's own scroller).
    /// Collapsed: from the rail icons' trailing edge (the rail's empty
    /// deck-side strip) across the gap and into the card — never over an
    /// icon.
    ///
    /// On the trailing edge the numbers are the mirror image: `x` is measured
    /// from the pane's leading edge toward the deck, which lies to the left.
    static func handleHitArea(
        isSidebarCollapsed: Bool,
        railDeckSideInset: CGFloat,
        insets: EdgeInsets = WorkbenchDeckLane.insets,
        collapsedGap: CGFloat = RafuMetrics.deckGapCollapsedRail,
        edge: WorkbenchSidebarEdge = .leading
    ) -> HandleHitArea {
        let lane = padding(
            isSidebarCollapsed: isSidebarCollapsed, railDeckSideInset: railDeckSideInset,
            insets: insets, collapsedGap: collapsedGap, edge: edge)
        let strip = isSidebarCollapsed ? railDeckSideInset : 0
        let railSideGap = edge == .leading ? lane.leading : lane.trailing
        return HandleHitArea(
            x: -strip, width: strip + railSideGap + handleDeckOverlap)
    }
}

/// The explicit boundary between the left sidebar and the workbench deck
/// (window redesign phase 3). It draws nothing at rest and a short grab bar
/// on hover or drag, inside a wider hit area; it resizes `session.sidebarWidth` live while dragging, and collapses
/// or reopens the sidebar at `WorkbenchSidebarResize`'s thresholds. It is an
/// overlay on the seam, not a layout child, so it adds no width to the gap
/// (`WorkbenchDeckLane.handleHitArea`). It stays present at the collapsed
/// edge (beside the Activity Rail) so a drag outward can reopen the sidebar
/// without a separate affordance.
struct WorkbenchSplitHandle: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    /// Which window edge holds the rail and sidebar. On the trailing edge the
    /// handle sits on the sidebar's leading seam and a drag toward the
    /// leading side widens the sidebar.
    let edge: WorkbenchSidebarEdge

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var didPushCursor = false
    /// The sidebar width at the start of the current drag. `nil` between
    /// drags and while a collapsed drag has not yet crossed the reopen
    /// threshold.
    @State private var dragStartWidth: Double?

    /// The hit area's width (`WorkbenchDeckLane.handleHitArea`); the hover
    /// grab bar is centred on the visible gap inside it.
    let hitAreaWidth: CGFloat
    private static let grabBarSize = CGSize(width: 3, height: 28)

    /// Explicit init: the private state would otherwise make the synthesized
    /// memberwise init private.
    init(
        session: WorkspaceSession, hitAreaWidth: CGFloat, edge: WorkbenchSidebarEdge = .leading
    ) {
        self.session = session
        self.hitAreaWidth = hitAreaWidth
        self.edge = edge
    }

    var body: some View {
        ZStack {
            Color.clear
            seam
        }
        .frame(width: hitAreaWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // A window-move surface here would fight the resize drag; this
        // handle is deliberately not one (see flat-window-chrome rule 3a's
        // drag-surface list — the rail, titlebar row, and sidebar header
        // stay the drag surfaces beside it).
        .onHover(perform: setHovering)
        .gesture(dragGesture)
        .help("Drag to resize")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sidebar width")
        .accessibilityValue(
            "\(Int(WorkbenchSidebarResize.clamp(session.sidebarWidth).rounded())) points"
        )
        .accessibilityAdjustableAction(handleAccessibilityAdjustment)
        .onDisappear { popCursorIfNeeded() }
    }

    @ViewBuilder
    private var seam: some View {
        if isHovering || isDragging {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(theme.palette.borderStrong)
                .frame(width: Self.grabBarSize.width, height: Self.grabBarSize.height)
                // Centred on the visible gap, not on the part of the hit
                // area that reaches into the card.
                .offset(x: edge.seamOffset(distance: -WorkbenchDeckLane.handleDeckOverlap / 2))
        } else {
            // Idle: nothing drawn. The deck card's own hairline is the one
            // line between the sidebar and the content; a second 1 pt seam
            // beside it read as a gutter.
            Color.clear
        }
    }

    // MARK: - Drag

    /// `minimumDistance: 1` so a pointer-driven resize starts immediately;
    /// no animation anywhere in this gesture — it tracks the pointer.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginDraggingIfNeeded()
                let outward = WorkbenchSidebarResize.outwardTranslation(
                    value.translation.width, edge: edge)
                if session.isSidebarCollapsed {
                    reopenIfPastThreshold(translation: outward)
                    return
                }
                let base = dragStartWidth ?? session.sidebarWidth
                session.sidebarWidth = WorkbenchSidebarResize.clamp(base + outward)
            }
            .onEnded { value in
                endDragging()
                guard !session.isSidebarCollapsed, let base = dragStartWidth else {
                    dragStartWidth = nil
                    return
                }
                dragStartWidth = nil
                let proposed =
                    base
                    + WorkbenchSidebarResize.outwardTranslation(
                        value.translation.width, edge: edge)
                // Collapse is decided only here, on release — a live
                // collapse mid-drag would hide the handle the pointer is
                // still tracking.
                if WorkbenchSidebarResize.shouldCollapse(proposedWidth: proposed) {
                    session.sidebarWidth = WorkbenchSidebarResize.clamp(base)
                    session.isSidebarCollapsed = true
                } else {
                    session.sidebarWidth = WorkbenchSidebarResize.clamp(proposed)
                }
            }
    }

    private func beginDraggingIfNeeded() {
        guard !isDragging else { return }
        isDragging = true
        pushCursorIfNeeded()
        if !session.isSidebarCollapsed {
            dragStartWidth = session.sidebarWidth
        }
    }

    /// Reopening happens live (`onChanged`), not on release: deciding it on
    /// release would leave the pointer dragging over a still-collapsed
    /// sidebar with no feedback until the mouse goes up, which reads as
    /// unresponsive. Reopening live is the only one of the two that cannot
    /// flicker, because it only ever transitions collapsed -> expanded once.
    private func reopenIfPastThreshold(translation: Double) {
        guard WorkbenchSidebarResize.shouldReopen(dragTranslation: translation) else { return }
        session.isSidebarCollapsed = false
        dragStartWidth = session.sidebarWidth
    }

    private func endDragging() {
        isDragging = false
        if !isHovering { popCursorIfNeeded() }
    }

    // MARK: - Hover and cursor

    private func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            pushCursorIfNeeded()
        } else if !isDragging {
            popCursorIfNeeded()
        }
    }

    private func pushCursorIfNeeded() {
        guard !didPushCursor else { return }
        NSCursor.resizeLeftRight.push()
        didPushCursor = true
    }

    private func popCursorIfNeeded() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }

    // MARK: - Accessibility

    /// VoiceOver keeps ⌘B for collapse/expand; this adjustable action only
    /// steps the expanded width by 20 pt, reopening first if collapsed so
    /// the action is never a silent no-op.
    private func handleAccessibilityAdjustment(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment:
            session.isSidebarCollapsed = false
            session.sidebarWidth = WorkbenchSidebarResize.clamp(session.sidebarWidth + 20)
        case .decrement:
            session.sidebarWidth = WorkbenchSidebarResize.clamp(session.sidebarWidth - 20)
        @unknown default:
            break
        }
    }
}
