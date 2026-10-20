import CoreGraphics
import Testing

@testable import RafuApp

/// History graph round 5: the subject always keeps its floor, the ref pills
/// step down (full, short, icon only, "+n") instead of being squeezed, the
/// author shows only with room for it, and the lane column is only as wide
/// as the lanes the loaded rows use.
@Suite("Git commit graph row plan")
struct GitCommitGraphRowPlanTests {
    /// Full, short, icon only, counter.
    private let pills: [CGFloat] = [200, 130, 50, 22]

    @Test("A wide row shows the whole subject, the author, and full pills")
    func wideRowShowsEverything() {
        let plan = GitCommitRowPlan.make(
            width: 1000, subject: 300, author: 50, pills: pills, time: 40)
        #expect(plan.subjectWidth == 300)
        #expect(plan.authorWidth == 50)
        #expect(plan.pillLevel == 0)
        #expect(plan.pillWidth == 200)
        #expect(plan.timeWidth == 40)
    }

    @Test("A narrow row keeps the subject's floor and steps the pills down")
    func narrowRowDegradesPills() {
        // Text column 184 pt: the floor is 90 pt, so 88 pt is left for the
        // pills; only the icon-only strip (50) fits.
        let plan = GitCommitRowPlan.make(
            width: 230, subject: 300, author: 50, pills: pills, time: 40)
        #expect(plan.pillLevel == 2)
        #expect(plan.pillWidth == 50)
        #expect(plan.subjectWidth == 128)
        #expect(plan.authorWidth == nil)
    }

    @Test("Short pills are chosen when they fit next to the subject's floor")
    func shortPillsWhenTheyFit() {
        let plan = GitCommitRowPlan.make(
            width: 320, subject: 300, author: 50, pills: pills, time: 40)
        // Text column 274 pt, floor max(90, 109.6) = 109.6; 158.4 pt for pills.
        #expect(plan.pillLevel == 1)
        #expect(plan.subjectWidth == 274 - 130 - GitCommitRowPlan.spacing)
    }

    @Test("Below the icon strip, one counter; below the counter, no pills")
    func counterThenNothing() {
        let counter = GitCommitRowPlan.make(
            width: 170, subject: 300, author: 50, pills: pills, time: 40)
        #expect(counter.pillLevel == 3)
        #expect(counter.subjectWidth == 96)

        let none = GitCommitRowPlan.make(
            width: 160, subject: 300, author: 50, pills: pills, time: 40)
        #expect(none.pillLevel == nil)
        #expect(none.pillWidth == 0)
        #expect(none.subjectWidth == 114)
    }

    @Test("The subject never drops below its floor while any pill shows")
    func subjectFloorHoldsAtEveryWidth() {
        for width in stride(from: CGFloat(100), through: 700, by: 1) {
            let plan = GitCommitRowPlan.make(
                width: width, subject: 400, author: 80, pills: pills, time: 40)
            let text = width - 40 - GitCommitRowPlan.spacing
            let floor = min(400, max(GitCommitRowPlan.minimumSubjectWidth, text * 0.4))
            if let level = plan.pillLevel {
                #expect(plan.subjectWidth >= floor - 0.001, "width \(width)")
                #expect(plan.pillWidth == pills[level])
            }
            let used =
                plan.subjectWidth
                + (plan.pillLevel == nil ? 0 : plan.pillWidth + GitCommitRowPlan.spacing)
                + (plan.authorWidth.map { $0 + GitCommitRowPlan.spacing } ?? 0)
            #expect(used <= text + 0.001, "width \(width)")
        }
    }

    @Test("A short subject leaves room to the pills and the author")
    func shortSubject() {
        let plan = GitCommitRowPlan.make(
            width: 300, subject: 40, author: 30, pills: [], time: 40)
        #expect(plan.subjectWidth == 40)
        #expect(plan.pillLevel == nil)
        #expect(plan.authorWidth == 30)
    }

    @Test("The author shows truncated with 60 pt, whole when it fits, else hidden")
    func authorNeedsRoom() {
        // Text column 254; subject 178 leaves 254 - 178 - 6 = 70 pt.
        let truncated = GitCommitRowPlan.make(
            width: 300, subject: 178, author: 120, pills: [], time: 40)
        #expect(truncated.authorWidth == 70)

        // 50 pt left: a 120 pt author would be a fragment, so it is hidden.
        let hidden = GitCommitRowPlan.make(
            width: 300, subject: 198, author: 120, pills: [], time: 40)
        #expect(hidden.authorWidth == nil)

        // 50 pt left and the whole 45 pt name fits.
        let whole = GitCommitRowPlan.make(
            width: 300, subject: 198, author: 45, pills: [], time: 40)
        #expect(whole.authorWidth == 45)
    }

    @Test("Densities are tried full, short, icon only, then counter")
    func densityOrder() {
        #expect(GitRefPillDensity.allCases == [.full, .short, .iconOnly, .counter])
        #expect(GitRefPillDensity.full.maximumPillWidth == 120)
        #expect(GitRefPillDensity.short.maximumPillWidth == 70)
        #expect(GitRefPillDensity.iconOnly.maximumPillWidth == nil)
    }

    @Test("The lane column ends just past the widest used lane's ring")
    func laneCanvasWidth() {
        #expect(GitCommitGraphMetrics.laneX(0) == 8)
        #expect(GitCommitGraphMetrics.laneX(2) == 32)
        #expect(GitCommitGraphMetrics.laneCanvasWidth(laneCount: 0) == 15)
        #expect(GitCommitGraphMetrics.laneCanvasWidth(laneCount: 1) == 15)
        #expect(GitCommitGraphMetrics.laneCanvasWidth(laneCount: 3) == 39)
        // Never the 8-lane cap's width for a 3-lane graph.
        #expect(
            GitCommitGraphMetrics.laneCanvasWidth(laneCount: 3)
                < GitCommitGraphMetrics.laneCanvasWidth(
                    laneCount: CommitGraphLayout.visibleLaneCap))
        #expect(GitCommitGraphMetrics.rowInsets.leading == 6)
    }
}
