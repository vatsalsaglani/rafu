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
}
