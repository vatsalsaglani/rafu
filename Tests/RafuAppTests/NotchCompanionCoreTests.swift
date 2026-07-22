import Foundation
import Testing

@testable import RafuApp

/// terminal-notch-hud.md NC-A: the pure companion core —
/// `CompanionHoverPolicy`, editor-row/git-summary/attention-feed
/// derivation, and `NotchCompanionGeometry`'s wing/strip/panel rect math.
/// Everything here is headless: no `NSScreen`, no window, no timers.
///
/// Same probed metrics fixture as `NotchHUDCoreTests.swift`: a 1710×1107
/// built-in screen, 33pt top safe-area inset, auxiliary top areas
/// (0,1074,763,33) / (948,1074,762,33) → notch rect (763,1074,185,33).

private let realNotchMetrics = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
    visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1074),
    safeAreaTopInset: 33,
    auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 763, height: 33),
    auxiliaryTopRight: CGRect(x: 948, y: 1074, width: 762, height: 33)
)

private let nonNotchMetrics = NotchScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
    safeAreaTopInset: 0,
    auxiliaryTopLeft: nil,
    auxiliaryTopRight: nil
)

// MARK: - CompanionHoverPolicy truth table

@Test("onHoverEnter: resting opens to peeking; peeking/pinned are unchanged")
func hoverEnterTable() {
    #expect(CompanionHoverPolicy.onHoverEnter(.resting) == .peeking)
    #expect(CompanionHoverPolicy.onHoverEnter(.peeking) == .peeking)
    #expect(CompanionHoverPolicy.onHoverEnter(.pinned) == .pinned)
}

@Test("onHoverExitAfterGrace: peeking closes to resting; pinned overrides the grace timer")
func hoverExitAfterGraceTable() {
    #expect(CompanionHoverPolicy.onHoverExitAfterGrace(.peeking) == .resting)
    #expect(CompanionHoverPolicy.onHoverExitAfterGrace(.pinned) == .pinned)
    #expect(CompanionHoverPolicy.onHoverExitAfterGrace(.resting) == .resting)
}

@Test("onClick: resting/peeking pin open; a second click on pinned toggles back to peeking")
func hoverClickTable() {
    #expect(CompanionHoverPolicy.onClick(.resting) == .pinned)
    #expect(CompanionHoverPolicy.onClick(.peeking) == .pinned)
    #expect(CompanionHoverPolicy.onClick(.pinned) == .peeking)
}

@Test("onEscape: always resting, regardless of starting state")
func hoverEscapeTable() {
    #expect(CompanionHoverPolicy.onEscape(.resting) == .resting)
    #expect(CompanionHoverPolicy.onEscape(.peeking) == .resting)
    #expect(CompanionHoverPolicy.onEscape(.pinned) == .resting)
}

@Test("dwell and grace durations are the documented 300ms/400ms")
func hoverDurations() {
    #expect(CompanionHoverPolicy.dwellSeconds == 0.3)
    #expect(CompanionHoverPolicy.graceSeconds == 0.4)
}

// MARK: - companionArbitration

@Test("companionArbitration: peeking/pinned route to the feed; resting shows the v1 drop-down")
func companionArbitrationTable() {
    #expect(
        CompanionHoverPolicy.companionArbitration(hoverState: .peeking)
            == (routeToFeed: true, showDropDown: false))
    #expect(
        CompanionHoverPolicy.companionArbitration(hoverState: .pinned)
            == (routeToFeed: true, showDropDown: false))
    #expect(
        CompanionHoverPolicy.companionArbitration(hoverState: .resting)
            == (routeToFeed: false, showDropDown: true))
}

// MARK: - editorRows

@Test("editorRows: chip counts come from statuses; .idle contributes to no chip")
func editorRowsChipCounts() {
    let input = CompanionEditorInput(
        id: UUID(),
        name: "rafu",
        windowNumber: 1,
        git: nil,
        statuses: [.running, .running, .bell, .exited(code: 0), .exited(code: nil), .idle]
    )
    let rows = CompanionEditorRow.editorRows(from: [input])
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.id == input.id)
    #expect(row.name == "rafu")
    #expect(row.windowNumber == 1)
    #expect(row.gitSummary == nil)
    #expect(row.runningCount == 2)
    #expect(row.attentionCount == 1)
    #expect(row.exitedCount == 2)
}

@Test("editorRows: preserves input order and maps a nil git input to a nil gitSummary")
func editorRowsOrderAndNoRepo() {
    let first = CompanionEditorInput(
        id: UUID(), name: "first", windowNumber: 1, git: nil, statuses: [])
    let second = CompanionEditorInput(
        id: UUID(), name: "second", windowNumber: 2,
        git: CompanionGitInput(
            branch: "main", ahead: 0, behind: 0, dirtyCount: 0, isDetached: false, isUnborn: false
        ), statuses: [])
    let rows = CompanionEditorRow.editorRows(from: [first, second])
    #expect(rows.map(\.name) == ["first", "second"])
    #expect(rows[0].gitSummary == nil)
    #expect(rows[1].gitSummary == "⎇ main")
}

// MARK: - editorRows carries the raw branch

@Test("editorRows: carries the raw git branch verbatim, independent of the formatted gitSummary")
func editorRowsCarriesRawBranch() {
    let withGit = CompanionEditorInput(
        id: UUID(), name: "rafu", windowNumber: 1,
        git: CompanionGitInput(
            branch: "feature/notch-search", ahead: 0, behind: 0, dirtyCount: 3,
            isDetached: false, isUnborn: false
        ), statuses: [])
    let withoutGit = CompanionEditorInput(
        id: UUID(), name: "no-repo", windowNumber: 2, git: nil, statuses: [])

    let rows = CompanionEditorRow.editorRows(from: [withGit, withoutGit])
    #expect(rows[0].branch == "feature/notch-search")
    #expect(rows[0].gitSummary == "⎇ feature/notch-search · 3±")
    #expect(rows[1].branch == nil)
}

// MARK: - filteredEditorRows

private func row(name: String, branch: String?) -> CompanionEditorRow {
    CompanionEditorRow(
        id: UUID(), name: name, windowNumber: 1, gitSummary: nil, runningCount: 0,
        attentionCount: 0, exitedCount: 0, branch: branch)
}

@Test("filteredEditorRows: an empty (or whitespace-only) query returns every row, unchanged order")
func filteredEditorRowsEmptyQueryReturnsAll() {
    let rows = [row(name: "rafu", branch: "main"), row(name: "notes", branch: "dev")]
    #expect(
        CompanionEditorRow.filteredEditorRows(rows, query: "").map(\.name) == ["rafu", "notes"])
    #expect(
        CompanionEditorRow.filteredEditorRows(rows, query: "   ").map(\.name)
            == ["rafu", "notes"])
}

@Test("filteredEditorRows: matches a substring of the workspace name")
func filteredEditorRowsMatchesName() {
    let rows = [row(name: "rafu", branch: "main"), row(name: "notes", branch: "dev")]
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "raf").map(\.name) == ["rafu"])
}

@Test("filteredEditorRows: matches a substring of the raw git branch")
func filteredEditorRowsMatchesBranch() {
    let rows = [
        row(name: "rafu", branch: "feature/notch-search"), row(name: "notes", branch: "main"),
    ]
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "notch").map(\.name) == ["rafu"])
}

@Test("filteredEditorRows: a query matching either name OR branch keeps both rows")
func filteredEditorRowsMatchesNameOrBranch() {
    let rows = [
        row(name: "main-workspace", branch: "dev"), row(name: "notes", branch: "main"),
        row(name: "other", branch: "other-branch"),
    ]
    #expect(
        CompanionEditorRow.filteredEditorRows(rows, query: "main").map(\.name).sorted()
            == ["main-workspace", "notes"])
}

@Test("filteredEditorRows: case-insensitive")
func filteredEditorRowsCaseInsensitive() {
    let rows = [row(name: "Rafu", branch: "Main")]
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "rafu").map(\.name) == ["Rafu"])
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "MAIN").map(\.name) == ["Rafu"])
}

@Test("filteredEditorRows: diacritic-insensitive")
func filteredEditorRowsDiacriticInsensitive() {
    let rows = [row(name: "café-notes", branch: "main")]
    #expect(
        CompanionEditorRow.filteredEditorRows(rows, query: "cafe").map(\.name) == ["café-notes"])
}

@Test("filteredEditorRows: no match against name or branch returns an empty result")
func filteredEditorRowsNoMatchReturnsEmpty() {
    let rows = [row(name: "rafu", branch: "main")]
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "zzz").isEmpty)
}

@Test("filteredEditorRows: a row with no branch (no repo open) is matched by name only")
func filteredEditorRowsNilBranchMatchesByNameOnly() {
    let rows = [row(name: "rafu", branch: nil)]
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "rafu").map(\.name) == ["rafu"])
    #expect(CompanionEditorRow.filteredEditorRows(rows, query: "main").isEmpty)
}

// MARK: - gitSummary

@Test("gitSummary: a clean repo on main renders as exactly '⎇ main'")
func gitSummaryCleanMain() {
    let git = CompanionGitInput(
        branch: "main", ahead: 0, behind: 0, dirtyCount: 0, isDetached: false, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(git) == "⎇ main")
}

@Test("gitSummary: dirty + ahead + behind all render together")
func gitSummaryDirtyAheadBehind() {
    let git = CompanionGitInput(
        branch: "feature", ahead: 2, behind: 1, dirtyCount: 3, isDetached: false, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(git) == "⎇ feature · 3± · ↑2 ↓1")
}

@Test("gitSummary: detached HEAD renders as exactly '⎇ detached', ignoring other fields")
func gitSummaryDetached() {
    let git = CompanionGitInput(
        branch: "a1b2c3d", ahead: 5, behind: 5, dirtyCount: 5, isDetached: true, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(git) == "⎇ detached")
}

@Test("gitSummary: unborn branch renders as '⎇ <branch> (unborn)', ignoring dirty/ahead/behind")
func gitSummaryUnborn() {
    let git = CompanionGitInput(
        branch: "main", ahead: 1, behind: 1, dirtyCount: 4, isDetached: false, isUnborn: true)
    #expect(CompanionEditorRow.gitSummary(git) == "⎇ main (unborn)")
}

@Test("gitSummary: zero dirty count omits the '±' clause entirely")
func gitSummaryZeroDirtyOmitsClause() {
    let git = CompanionGitInput(
        branch: "main", ahead: 1, behind: 0, dirtyCount: 0, isDetached: false, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(git) == "⎇ main · ↑1")
}

@Test("gitSummary: ahead-only, behind-only, and both-zero each omit correctly")
func gitSummaryAheadBehindOmissions() {
    let aheadOnly = CompanionGitInput(
        branch: "main", ahead: 4, behind: 0, dirtyCount: 0, isDetached: false, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(aheadOnly) == "⎇ main · ↑4")

    let behindOnly = CompanionGitInput(
        branch: "main", ahead: 0, behind: 3, dirtyCount: 0, isDetached: false, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(behindOnly) == "⎇ main · ↓3")

    let bothZero = CompanionGitInput(
        branch: "main", ahead: 0, behind: 0, dirtyCount: 2, isDetached: false, isUnborn: false)
    #expect(CompanionEditorRow.gitSummary(bothZero) == "⎇ main · 2±")
}

// MARK: - attentionFeed

@Test("attentionFeed: newest-first ordering")
func attentionFeedNewestFirst() {
    let now = Date()
    let older = CompanionFeedItem(
        id: UUID(), sessionID: UUID(), title: "a", editorName: "e1", snippet: "s",
        timestamp: now.addingTimeInterval(-60), color: nil)
    let newer = CompanionFeedItem(
        id: UUID(), sessionID: UUID(), title: "b", editorName: "e2", snippet: "s",
        timestamp: now, color: nil)
    let feed = CompanionFeedItem.attentionFeed(from: [older, newer])
    #expect(feed.map(\.title) == ["b", "a"])
}

@Test("attentionFeed: dedups by sessionID, keeping the newest entry for that session")
func attentionFeedDedupBySession() {
    let now = Date()
    let session = UUID()
    let stale = CompanionFeedItem(
        id: UUID(), sessionID: session, title: "stale", editorName: "e1", snippet: "s1",
        timestamp: now.addingTimeInterval(-30), color: nil)
    let fresh = CompanionFeedItem(
        id: UUID(), sessionID: session, title: "fresh", editorName: "e1", snippet: "s2",
        timestamp: now, color: nil)
    let other = CompanionFeedItem(
        id: UUID(), sessionID: UUID(), title: "other", editorName: "e2", snippet: "s3",
        timestamp: now.addingTimeInterval(-15), color: nil)

    let feed = CompanionFeedItem.attentionFeed(from: [stale, fresh, other])
    #expect(feed.count == 2)
    #expect(feed.map(\.title) == ["fresh", "other"])
}

@Test("attentionFeed: equal timestamps preserve original input order (stable sort)")
func attentionFeedStableForEqualTimestamps() {
    let now = Date()
    let first = CompanionFeedItem(
        id: UUID(), sessionID: UUID(), title: "first", editorName: "e1", snippet: "s",
        timestamp: now, color: nil)
    let second = CompanionFeedItem(
        id: UUID(), sessionID: UUID(), title: "second", editorName: "e2", snippet: "s",
        timestamp: now, color: nil)
    let third = CompanionFeedItem(
        id: UUID(), sessionID: UUID(), title: "third", editorName: "e3", snippet: "s",
        timestamp: now, color: nil)

    let feed = CompanionFeedItem.attentionFeed(from: [first, second, third])
    #expect(feed.map(\.title) == ["first", "second", "third"])
}

// MARK: - NotchCompanionGeometry

@Test("restingStripFrame: notch + two 90pt wings, centered on the notch, pinned to screen top")
func restingStripFrameRealMetrics() {
    let frame = NotchCompanionGeometry.restingStripFrame(for: realNotchMetrics)
    // notchMidX 855.5, width 185 + 180 = 365 → x 673, y at screen top (1074),
    // height equal to the notch band (33).
    #expect(frame == CGRect(x: 673, y: 1074, width: 365, height: 33))
    #expect(frame?.maxY == realNotchMetrics.frame.maxY)
}

@Test("restingStripFrame: nil when the screen has no notch")
func restingStripFrameNilWithoutNotch() {
    #expect(NotchCompanionGeometry.restingStripFrame(for: nonNotchMetrics) == nil)
}

@Test("leftWingRect/rightWingRect: flush against the notch's edges, 90pt wide")
func wingRects() {
    let left = NotchCompanionGeometry.leftWingRect(for: realNotchMetrics)
    let right = NotchCompanionGeometry.rightWingRect(for: realNotchMetrics)
    #expect(left == CGRect(x: 673, y: 1074, width: 90, height: 33))
    #expect(right == CGRect(x: 948, y: 1074, width: 90, height: 33))

    #expect(NotchCompanionGeometry.leftWingRect(for: nonNotchMetrics) == nil)
    #expect(NotchCompanionGeometry.rightWingRect(for: nonNotchMetrics) == nil)
}

@Test("clickThroughRegions: non-empty over a notch and excludes both wings")
func clickThroughRegionsExcludeWings() {
    let regions = NotchCompanionGeometry.clickThroughRegions(for: realNotchMetrics)
    #expect(!regions.isEmpty)
    let left = NotchCompanionGeometry.leftWingRect(for: realNotchMetrics)
    let right = NotchCompanionGeometry.rightWingRect(for: realNotchMetrics)
    // The click-through region is exactly the notch, and it does not equal
    // either wing rect.
    #expect(regions == [CGRect(x: 763, y: 1074, width: 185, height: 33)])
    #expect(!regions.contains(left ?? .zero))
    #expect(!regions.contains(right ?? .zero))
}

@Test("clickThroughRegions: empty when there is no notch")
func clickThroughRegionsEmptyWithoutNotch() {
    #expect(NotchCompanionGeometry.clickThroughRegions(for: nonNotchMetrics) == [])
}

@Test("peekPanelFrame: grows downward only, pinned at the strip's top edge")
func peekPanelFrameGrowsDownward() {
    let short = NotchCompanionGeometry.peekPanelFrame(for: realNotchMetrics, contentHeight: 200)
    let tall = NotchCompanionGeometry.peekPanelFrame(for: realNotchMetrics, contentHeight: 500)
    #expect(short.maxY == realNotchMetrics.frame.maxY)
    #expect(tall.maxY == realNotchMetrics.frame.maxY)
    #expect(short.minX == tall.minX)
    #expect(short.width == tall.width)
    #expect(tall.minY < short.minY)
    #expect(realNotchMetrics.frame.contains(short))
    #expect(realNotchMetrics.frame.contains(tall))
}

@Test("peekPanelFrame: clamps within the screen frame for oversized content")
func peekPanelFrameClamps() {
    let frame = NotchCompanionGeometry.peekPanelFrame(
        for: realNotchMetrics, contentHeight: 5000)
    #expect(realNotchMetrics.frame.contains(frame))
}

@Test("peekPanelFrame: oversized content caps at maxPeekHeight, not screen height")
func peekPanelFrameCapsAtMaxPeekHeight() {
    let cap = NotchCompanionGeometry.maxPeekHeight(for: realNotchMetrics)
    #expect(cap == (realNotchMetrics.frame.height * 0.6).rounded())
    let frame = NotchCompanionGeometry.peekPanelFrame(
        for: realNotchMetrics, contentHeight: 5000)
    #expect(frame.height == cap)
    // Still pinned to the strip's top edge — the cap trims the BOTTOM.
    #expect(frame.maxY == realNotchMetrics.frame.maxY)
}

@Test("peekPanelFrame: content below the cap keeps sizing to content")
func peekPanelFrameBelowCapUnchanged() {
    let frame = NotchCompanionGeometry.peekPanelFrame(
        for: realNotchMetrics, contentHeight: 300)
    #expect(frame.height == 300)
}

@Test("peekPanelFrame: without a notch, anchors top-center just below the menu bar")
func peekPanelFrameNonNotchFallback() {
    let frame = NotchCompanionGeometry.peekPanelFrame(for: nonNotchMetrics, contentHeight: 300)
    #expect(frame.midX == nonNotchMetrics.frame.midX)
    #expect(frame.maxY == nonNotchMetrics.visibleFrame.maxY)
    #expect(nonNotchMetrics.frame.contains(frame))
}
