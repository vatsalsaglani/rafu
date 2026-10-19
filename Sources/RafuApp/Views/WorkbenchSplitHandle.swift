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
}

/// The explicit boundary between the left sidebar and the workbench deck
/// (window redesign phase 3). It renders a 1 pt seam inside a wider hit
/// area, resizes `session.sidebarWidth` live while dragging, and collapses
/// or reopens the sidebar at `WorkbenchSidebarResize`'s thresholds. It stays
/// present at the collapsed edge (right after the Activity Rail) so a drag
/// outward can reopen the sidebar without a separate affordance.
struct WorkbenchSplitHandle: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var didPushCursor = false
    /// The sidebar width at the start of the current drag. `nil` between
    /// drags and while a collapsed drag has not yet crossed the reopen
    /// threshold.
    @State private var dragStartWidth: Double?

    /// The hit area's full width; the drawn seam is 1 pt, centred inside it.
    static let hitAreaWidth: CGFloat = 10
    private static let grabBarSize = CGSize(width: 3, height: 28)

    var body: some View {
        ZStack {
            Color.clear
            seam
        }
        .frame(width: Self.hitAreaWidth)
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
        } else {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Drag

    /// `minimumDistance: 1` so a pointer-driven resize starts immediately;
    /// no animation anywhere in this gesture — it tracks the pointer.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginDraggingIfNeeded()
                if session.isSidebarCollapsed {
                    reopenIfPastThreshold(translation: value.translation.width)
                    return
                }
                let base = dragStartWidth ?? session.sidebarWidth
                session.sidebarWidth = WorkbenchSidebarResize.clamp(base + value.translation.width)
            }
            .onEnded { value in
                endDragging()
                guard !session.isSidebarCollapsed, let base = dragStartWidth else {
                    dragStartWidth = nil
                    return
                }
                dragStartWidth = nil
                let proposed = base + value.translation.width
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
