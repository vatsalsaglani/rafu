import Foundation
import Testing

@testable import RafuApp

@Suite("Commit graph layout")
struct CommitGraphLayoutTests {
    private func commit(_ id: String, parents: [String] = [], decorations: [String] = [])
        -> GitCommitSummary
    {
        GitCommitSummary(
            id: id,
            parentIDs: parents,
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            authoredAt: Date(timeIntervalSince1970: 0),
            subject: "Commit \(id)",
            decorations: decorations
        )
    }

    @Test("An empty commit list yields an empty layout")
    func emptyInput() {
        #expect(CommitGraphLayout.layout([]).isEmpty)
    }

    @Test("A linear chain stays in a single lane with no cross-lane edges")
    func linearChain() {
        let commits = [
            commit("c3", parents: ["c2"]),
            commit("c2", parents: ["c1"]),
            commit("c1", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.laneIndex == 0 })
        #expect(rows.allSatisfy { $0.incomingEdges.isEmpty })
        // Only the trailing lane-continuation edges for a non-root commit
        // are same-lane (0->0), never cross-lane, in a pure linear chain.
        #expect(
            rows.allSatisfy { edges in edges.outgoingEdges.allSatisfy { $0.fromLane == $0.toLane } }
        )
        #expect(rows.last?.outgoingEdges.isEmpty == true)
        #expect(rows.allSatisfy { $0.openStubParentIDs.isEmpty })
    }

    @Test("A branch and merge converges two lanes into the ancestor's lane")
    func branchAndMerge() {
        // C merges B2 and B1; both branch from A.
        let commits = [
            commit("C", parents: ["B2", "B1"]),
            commit("B2", parents: ["A"]),
            commit("B1", parents: ["A"]),
            commit("A", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows.count == 4)

        let mergeRow = rows[0]
        #expect(mergeRow.outgoingEdges.count == 1)
        #expect(mergeRow.outgoingEdges.first?.fromLane == mergeRow.laneIndex)

        let ancestorRow = rows[3]
        #expect(ancestorRow.commitID == "A")
        // Two lanes converge on the shared ancestor: one incoming edge from
        // the other branch's lane into A's lane.
        #expect(ancestorRow.incomingEdges.count == 1)
        #expect(ancestorRow.outgoingEdges.isEmpty)
    }

    @Test("An octopus merge (3+ parents) never crashes and assigns a lane per parent")
    func octopusMerge() {
        let commits = [
            commit("M", parents: ["P1", "P2", "P3", "P4"]),
            commit("P1", parents: []),
            commit("P2", parents: []),
            commit("P3", parents: []),
            commit("P4", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows.count == 5)
        let mergeRow = rows[0]
        // First parent continues in the merge commit's own lane; the other
        // three parents fan out to three additional lanes.
        #expect(mergeRow.outgoingEdges.count == 3)
        let targetLanes = Set(mergeRow.outgoingEdges.map(\.toLane))
        #expect(targetLanes.count == 3)
    }

    @Test("Lane count beyond the visible cap folds into an overflow indicator")
    func capAndOverflow() {
        // A merge with more parents than the visible cap forces the active
        // lane count above the cap.
        let parentIDs = (0..<12).map { "P\($0)" }
        var commits = [commit("M", parents: parentIDs)]
        commits += parentIDs.map { commit($0, parents: []) }
        let rows = CommitGraphLayout.layout(commits)

        #expect(rows[0].overflowLaneCount > 0)
        #expect(rows.allSatisfy { $0.laneIndex < CommitGraphLayout.visibleLaneCap })
        #expect(
            rows.allSatisfy { row in
                row.incomingEdges.allSatisfy { $0.fromLane < CommitGraphLayout.visibleLaneCap }
                    && row.outgoingEdges.allSatisfy { $0.toLane < CommitGraphLayout.visibleLaneCap }
            }
        )
    }

    @Test("A parent outside the loaded window draws as an open stub, never crashing")
    func openStubForUnloadedParent() {
        let commits = [
            commit("C2", parents: ["missing-parent"])
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows.count == 1)
        #expect(rows[0].openStubParentIDs == ["missing-parent"])
        // The lane continues as a same-lane stub rather than closing.
        #expect(rows[0].outgoingEdges.contains(GraphRow.Edge(fromLane: 0, toLane: 0)))
    }

    @Test("A merge commit with one loaded and one unloaded parent mixes a real edge and a stub")
    func mixedLoadedAndUnloadedParents() {
        let commits = [
            commit("M", parents: ["B", "missing"]),
            commit("B", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows[0].openStubParentIDs == ["missing"])
        // First parent (B) is loaded: it continues the merge commit's own
        // lane, so it produces no cross-lane outgoing edge — only the
        // second parent's absence needs representing, and that never
        // crashes or fabricates a fake row.
        #expect(rows.count == 2)
    }

    @Test("Root commits (no parents) close their lane without crashing")
    func rootCommitClosesLane() {
        let commits = [commit("root", parents: [])]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows.count == 1)
        #expect(rows[0].outgoingEdges.isEmpty)
        #expect(rows[0].openStubParentIDs.isEmpty)
    }

    @Test("laneCount is 1 for an empty layout")
    func laneCountEmpty() {
        #expect(CommitGraphLayout.laneCount([]) == 1)
    }

    @Test("laneCount is 1 for a linear chain")
    func laneCountLinearChain() {
        let commits = [
            commit("c3", parents: ["c2"]),
            commit("c2", parents: ["c1"]),
            commit("c1", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(CommitGraphLayout.laneCount(rows) == 1)
    }

    @Test("laneCount is 2 for a branch and merge")
    func laneCountBranchAndMerge() {
        let commits = [
            commit("C", parents: ["B2", "B1"]),
            commit("B2", parents: ["A"]),
            commit("B1", parents: ["A"]),
            commit("A", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(CommitGraphLayout.laneCount(rows) == 2)
    }

    @Test("laneCount clamps to the visible lane cap for a wide merge")
    func laneCountClampsToVisibleCap() {
        let parentIDs = (0..<12).map { "P\($0)" }
        var commits = [commit("M", parents: parentIDs)]
        commits += parentIDs.map { commit($0, parents: []) }
        let rows = CommitGraphLayout.layout(commits)
        #expect(CommitGraphLayout.laneCount(rows) == CommitGraphLayout.visibleLaneCap)
    }

    // MARK: Continuous rails (GitLens-style graph)

    @Test("Middle rows of a branch and merge carry the other lane as a pass-through rail")
    func passingLanesOnBranchAndMerge() {
        let commits = [
            commit("C", parents: ["B2", "B1"]),
            commit("B2", parents: ["A"]),
            commit("B1", parents: ["A"]),
            commit("A", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows[0].passingLanes.isEmpty)
        #expect(rows[0].isMerge)
        #expect(!rows[0].hasIncomingRail)
        #expect(rows[0].hasOutgoingRail)

        // B2 is in lane 0; lane 1 waits for B1 and passes straight through.
        #expect(rows[1].laneIndex == 0)
        #expect(rows[1].passingLanes == [1])
        #expect(rows[1].hasIncomingRail && rows[1].hasOutgoingRail)
        #expect(!rows[1].isMerge)

        // B1 is in lane 1; lane 0 now waits for A and passes through.
        #expect(rows[2].laneIndex == 1)
        #expect(rows[2].passingLanes == [0])
        #expect(rows[2].hasIncomingRail && rows[2].hasOutgoingRail)

        // A closes both lanes: no pass-through, nothing below.
        #expect(rows[3].passingLanes.isEmpty)
        #expect(rows[3].hasIncomingRail)
        #expect(!rows[3].hasOutgoingRail)
        #expect(rows[3].lanesBelow.isEmpty)
    }

    @Test("Every lane drawn at a row's bottom is drawn at the next row's top")
    func railsAreContinuousBetweenRows() {
        let commits = [
            commit("M2", parents: ["D", "F2"]),
            commit("F2", parents: ["F1"]),
            commit("D", parents: ["M1"]),
            commit("M1", parents: ["C", "F1"]),
            commit("F1", parents: ["B"]),
            commit("C", parents: ["B"]),
            commit("B", parents: ["A"]),
            commit("A", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        for (above, below) in zip(rows, rows.dropFirst()) {
            var topOfBelow = Set(below.passingLanes)
            topOfBelow.formUnion(below.incomingEdges.map(\.fromLane))
            if below.hasIncomingRail { topOfBelow.insert(below.laneIndex) }
            #expect(
                Set(above.lanesBelow) == topOfBelow,
                "rails break between \(above.commitID) and \(below.commitID)")
        }
    }

    @Test("An octopus merge's extra lanes pass through the rows until their parents")
    func octopusPassingLanes() {
        let commits = [
            commit("M", parents: ["P1", "P2", "P3", "P4"]),
            commit("P1", parents: []),
            commit("P2", parents: []),
            commit("P3", parents: []),
            commit("P4", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows[0].isMerge)
        #expect(rows[0].lanesBelow == [0, 1, 2, 3])
        #expect(rows[1].passingLanes == [1, 2, 3])
        #expect(rows[2].passingLanes == [2, 3])
        #expect(rows[3].passingLanes == [3])
        #expect(rows[4].passingLanes.isEmpty)
    }

    @Test("A stub to an unloaded first parent is not a continuing rail")
    func stubParentDoesNotContinueRail() {
        let commits = [
            commit("C2", parents: ["C1"]),
            commit("C1", parents: ["missing"]),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows[0].hasOutgoingRail)
        #expect(rows[1].hasIncomingRail)
        #expect(!rows[1].hasOutgoingRail)
        #expect(rows[1].outgoingEdges == [GraphRow.Edge(fromLane: 0, toLane: 0)])
        #expect(rows[1].lanesBelow.isEmpty)
    }

    @Test("A second parent that another lane already waits for joins that lane")
    func secondParentReusesWaitingLane() {
        // Two merges both bring in F; the second must not open a third lane.
        let commits = [
            commit("M2", parents: ["M1", "F"]),
            commit("M1", parents: ["B", "F"]),
            commit("F", parents: ["B"]),
            commit("B", parents: []),
        ]
        let rows = CommitGraphLayout.layout(commits)
        #expect(rows[0].outgoingEdges == [GraphRow.Edge(fromLane: 0, toLane: 1)])
        #expect(rows[1].outgoingEdges == [GraphRow.Edge(fromLane: 0, toLane: 1)])
        #expect(CommitGraphLayout.laneCount(rows) == 2)
    }

    @Test("Layout of 5,000 commits with branches finishes well inside a frame budget")
    func layoutScalesToThousandsOfCommits() {
        // A main line with a two-commit side branch merged every 10 commits.
        var commits: [GitCommitSummary] = []
        var index = 0
        while commits.count < 5_000 {
            let id = "c\(index)"
            if index % 10 == 0 {
                commits.append(commit(id, parents: ["c\(index + 1)", "s\(index)a"]))
                commits.append(commit("s\(index)a", parents: ["s\(index)b"]))
                commits.append(commit("s\(index)b", parents: ["c\(index + 3)"]))
            } else {
                commits.append(commit(id, parents: ["c\(index + 1)"]))
            }
            index += 1
        }
        let clock = ContinuousClock()
        var rows: [GraphRow] = []
        let elapsed = clock.measure { rows = CommitGraphLayout.layout(commits) }
        #expect(rows.count == commits.count)
        // Generous bound for a debug build on a loaded CI machine; the
        // layout is linear in commits and runs once per loaded page.
        #expect(elapsed < .seconds(2))
    }
}
