import Testing

@testable import RafuApp

@Suite("Status bar branch formatter")
struct StatusBarBranchFormatterTests {
    private func snapshot(
        currentBranch: String? = "main",
        upstream: String? = "origin/main",
        aheadCount: Int = 0,
        behindCount: Int = 0,
        isDetached: Bool = false,
        isUnborn: Bool = false,
        branches: [GitBranch] = []
    ) -> GitBranchSnapshot {
        GitBranchSnapshot(
            currentBranch: currentBranch,
            upstream: upstream,
            aheadCount: aheadCount,
            behindCount: behindCount,
            isDetached: isDetached,
            isUnborn: isUnborn,
            branches: branches
        )
    }

    @Test("Up to date branch has no ahead/behind text and is not detached")
    func upToDateBranch() {
        let presentation = StatusBarBranchFormatter.present(snapshot(currentBranch: "main"))
        #expect(presentation.label == "main")
        #expect(presentation.isDetached == false)
        #expect(presentation.aheadText == nil)
        #expect(presentation.behindText == nil)
    }

    @Test("Ahead and behind counts render as non-nil text")
    func aheadAndBehindCounts() {
        let presentation = StatusBarBranchFormatter.present(
            snapshot(currentBranch: "feature/x", aheadCount: 3, behindCount: 2))
        #expect(presentation.label == "feature/x")
        #expect(presentation.aheadText == "3")
        #expect(presentation.behindText == "2")
    }

    @Test("Zero ahead/behind counts stay nil, not \"0\"")
    func zeroCountsStayNil() {
        let presentation = StatusBarBranchFormatter.present(
            snapshot(currentBranch: "main", aheadCount: 0, behindCount: 0))
        #expect(presentation.aheadText == nil)
        #expect(presentation.behindText == nil)
    }

    @Test("Detached HEAD has no current branch name and falls back to a HEAD label")
    func detachedHead() {
        let presentation = StatusBarBranchFormatter.present(
            snapshot(currentBranch: nil, isDetached: true))
        #expect(presentation.label == "HEAD")
        #expect(presentation.isDetached == true)
    }
}
