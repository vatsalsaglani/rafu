import SwiftUI
import Testing

@testable import RafuApp

@Suite("Workbench sidebar resize rules")
struct WorkbenchSidebarResizeTests {
    @Test("Bounds match the former HSplitView frame triplet")
    func bounds() {
        #expect(WorkbenchSidebarResize.minimumWidth == 220)
        #expect(WorkbenchSidebarResize.idealWidth == 300)
        #expect(WorkbenchSidebarResize.maximumWidth == 560)
    }

    @Test("Clamp keeps a proposed width inside the min/max bounds")
    func clampBounds() {
        #expect(WorkbenchSidebarResize.clamp(100) == WorkbenchSidebarResize.minimumWidth)
        #expect(WorkbenchSidebarResize.clamp(900) == WorkbenchSidebarResize.maximumWidth)
        #expect(WorkbenchSidebarResize.clamp(340) == 340)
    }

    @Test("Clamp falls back to the ideal width for a non-finite proposal")
    func clampNonFinite() {
        #expect(WorkbenchSidebarResize.clamp(.nan) == WorkbenchSidebarResize.idealWidth)
        #expect(WorkbenchSidebarResize.clamp(.infinity) == WorkbenchSidebarResize.idealWidth)
    }

    @Test("A release stays open at the minimum width, right up to the collapse slack")
    func doesNotCollapseAtMinimum() {
        #expect(
            !WorkbenchSidebarResize.shouldCollapse(
                proposedWidth: WorkbenchSidebarResize.minimumWidth))
        #expect(
            !WorkbenchSidebarResize.shouldCollapse(
                proposedWidth: WorkbenchSidebarResize.minimumWidth
                    - WorkbenchSidebarResize.collapseSlack
            )
        )
    }

    @Test("A release below the collapse slack collapses the sidebar")
    func collapsesPastSlack() {
        #expect(
            WorkbenchSidebarResize.shouldCollapse(
                proposedWidth: WorkbenchSidebarResize.minimumWidth
                    - WorkbenchSidebarResize.collapseSlack - 1
            )
        )
        #expect(WorkbenchSidebarResize.shouldCollapse(proposedWidth: 0))
        #expect(WorkbenchSidebarResize.shouldCollapse(proposedWidth: -50))
    }

    @Test("Reopen only fires once the outward drag passes the threshold")
    func reopenThreshold() {
        #expect(!WorkbenchSidebarResize.shouldReopen(dragTranslation: 0))
        #expect(
            !WorkbenchSidebarResize.shouldReopen(
                dragTranslation: WorkbenchSidebarResize.reopenThreshold)
        )
        #expect(
            WorkbenchSidebarResize.shouldReopen(
                dragTranslation: WorkbenchSidebarResize.reopenThreshold + 1)
        )
    }

    @Test("A drag inward while collapsed never reopens")
    func negativeTranslationNeverReopens() {
        #expect(!WorkbenchSidebarResize.shouldReopen(dragTranslation: -40))
    }

    @Test("On the trailing edge a drag toward the leading side widens the sidebar")
    func trailingEdgeDragTowardLeadingWidens() {
        // Pointer moves 40 pt left: the sidebar on the right grows by 40.
        #expect(WorkbenchSidebarResize.outwardTranslation(-40, edge: .trailing) == 40)
        #expect(WorkbenchSidebarResize.outwardTranslation(40, edge: .trailing) == -40)
        // A leftward drag from a collapsed trailing sidebar reopens it.
        #expect(
            WorkbenchSidebarResize.shouldReopen(
                dragTranslation: WorkbenchSidebarResize.outwardTranslation(-33, edge: .trailing)))
        #expect(
            !WorkbenchSidebarResize.shouldReopen(
                dragTranslation: WorkbenchSidebarResize.outwardTranslation(33, edge: .trailing)))
    }

    @Test("The leading edge keeps its old sign")
    func leadingEdgeBehaviourIsUnchanged() {
        #expect(WorkbenchSidebarResize.outwardTranslation(40, edge: .leading) == 40)
        #expect(WorkbenchSidebarResize.outwardTranslation(-40, edge: .leading) == -40)
    }

    @Test("The deck lane mirrors its collapsed-rail gap on the trailing edge")
    func deckLaneMirrorsOnTheTrailingEdge() {
        let insets = WorkbenchDeckLane.insets
        let strip = WorkspaceActivityRail.deckSideInset
        let gap: CGFloat = RafuMetrics.deckGapCollapsedRail - strip

        let leading = WorkbenchDeckLane.padding(
            isSidebarCollapsed: true, railDeckSideInset: strip, edge: .leading)
        #expect(leading.leading == gap)
        #expect(leading.trailing == insets.trailing)

        let trailing = WorkbenchDeckLane.padding(
            isSidebarCollapsed: true, railDeckSideInset: strip, edge: .trailing)
        #expect(trailing.trailing == gap)
        #expect(trailing.leading == insets.leading)

        let open = WorkbenchDeckLane.padding(
            isSidebarCollapsed: false, railDeckSideInset: strip, edge: .trailing)
        #expect(open == insets)

        // The hit area has the same size on both edges.
        for collapsed in [false, true] {
            #expect(
                WorkbenchDeckLane.handleHitArea(
                    isSidebarCollapsed: collapsed, railDeckSideInset: strip, edge: .leading)
                    == WorkbenchDeckLane.handleHitArea(
                        isSidebarCollapsed: collapsed, railDeckSideInset: strip,
                        edge: .trailing))
        }
    }
}
