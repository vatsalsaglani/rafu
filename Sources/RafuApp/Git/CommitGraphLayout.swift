import Foundation

/// One rendered row of the commit graph: the commit's assigned lane, the
/// edges entering/leaving that row, a stable lane color index, and which of
/// its parents fall outside the currently loaded commit window.
nonisolated struct GraphRow: Equatable, Sendable {
    /// A lane-to-lane connector segment the graph canvas draws between the
    /// row above (`incomingEdges`) or below (`outgoingEdges`) and this row.
    nonisolated struct Edge: Equatable, Sendable {
        let fromLane: Int
        let toLane: Int
    }

    let commitID: String
    /// This commit's lane, clamped to `CommitGraphLayout.visibleLaneCap`. A
    /// lane at or beyond the cap draws in the last visible lane instead;
    /// `overflowLaneCount` records how many concurrent lanes that folded.
    let laneIndex: Int
    /// Edges arriving at this row (a child commit elsewhere converging on
    /// this commit).
    let incomingEdges: [Edge]
    /// Edges leaving this row toward this commit's parents.
    let outgoingEdges: [Edge]
    /// Stable, UNCLAMPED color index for the commit's true lane — callers
    /// index a palette with `colorIndex % palette.count`.
    let colorIndex: Int
    /// Parent commit IDs of this commit that are not present anywhere in the
    /// loaded window. Their edge draws as an open stub rather than
    /// connecting to a row; loading more history (pagination) may resolve
    /// them in a later call.
    let openStubParentIDs: [String]
    /// Count of additional concurrent lanes beyond the visible cap at this
    /// row, folded into one overflow indicator. Zero when concurrency never
    /// exceeded the cap.
    let overflowLaneCount: Int
    /// Lanes (clamped, ascending, without duplicates) that run straight
    /// through this row from top to bottom: their commit is further down.
    /// Without these the rails between a branch and its merge are broken.
    let passingLanes: [Int]
    /// The commit has more than one parent. The canvas draws it as a ring.
    let isMerge: Bool
    /// The commit's own lane continues from the row above (a child commit
    /// in the same lane points at this commit).
    let hasIncomingRail: Bool
    /// The commit's own lane continues to the row below (its first parent
    /// is loaded). A first parent outside the window is a stub instead.
    let hasOutgoingRail: Bool

    /// Lanes drawn at the bottom edge of this row: the pass-through lanes,
    /// the targets of the outgoing edges, and the own lane when it
    /// continues. An inline row inserted under this row (the expanded
    /// commit detail) draws these lanes as straight rails, so the graph
    /// stays continuous through it. Open stubs are excluded.
    var lanesBelow: [Int] {
        var lanes = Set(passingLanes)
        for edge in outgoingEdges where edge.fromLane != edge.toLane {
            lanes.insert(edge.toLane)
        }
        if hasOutgoingRail { lanes.insert(laneIndex) }
        return lanes.sorted()
    }
}

/// Pure lane-assignment layout for the bounded commit graph (GX3). Input is
/// the already-paginated, newest-to-oldest `[GitCommitSummary]` a
/// `GitHistoryPage` carries (parents already present via `%P`); output is
/// one `GraphRow` per input commit, in the same order. Never spawns a
/// process, never crashes on any parent-count shape (root commits, simple
/// chains, two-parent merges, octopus merges), and never grows lanes
/// unbounded — see `visibleLaneCap`.
nonisolated enum CommitGraphLayout {
    /// Visible lane cap. Lanes at or beyond this index collapse into the
    /// last visible lane; a very wide graph degrades to an overflow count
    /// instead of an unbounded canvas.
    static let visibleLaneCap = 8

    static func layout(_ commits: [GitCommitSummary]) -> [GraphRow] {
        guard !commits.isEmpty else { return [] }
        let idsInWindow = Set(commits.map(\.id))

        // Each active lane tracks the commit ID it is waiting to connect to
        // next (its still-unvisited parent), or `nil` for a free, reusable
        // lane slot.
        var laneExpectations: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func firstFreeLaneIndex() -> Int {
            if let index = laneExpectations.firstIndex(where: { $0 == nil }) {
                return index
            }
            laneExpectations.append(nil)
            return laneExpectations.count - 1
        }

        func clampLane(_ lane: Int) -> Int { min(lane, visibleLaneCap - 1) }

        for commit in commits {
            // Every lane currently expecting this commit converges here.
            let arrivingLanes = laneExpectations.indices.filter {
                laneExpectations[$0] == commit.id
            }
            // Lanes waiting for a commit further down pass straight through.
            let passingLanes = laneExpectations.indices.filter {
                laneExpectations[$0] != nil && laneExpectations[$0] != commit.id
            }
            let laneIndex = arrivingLanes.first ?? firstFreeLaneIndex()
            for lane in arrivingLanes { laneExpectations[lane] = nil }

            let incomingEdges = arrivingLanes.filter { $0 != laneIndex }.map {
                GraphRow.Edge(fromLane: clampLane($0), toLane: clampLane(laneIndex))
            }

            var outgoingEdges: [GraphRow.Edge] = []
            var openStubs: [String] = []
            for (parentOffset, parentID) in commit.parentIDs.enumerated() {
                guard idsInWindow.contains(parentID) else {
                    openStubs.append(parentID)
                    continue
                }
                // A later parent that another lane already waits for joins
                // that lane instead of opening a duplicate one.
                let targetLane: Int
                if parentOffset == 0 {
                    targetLane = laneIndex
                } else if let existing = laneExpectations.firstIndex(of: parentID) {
                    targetLane = existing
                } else {
                    targetLane = firstFreeLaneIndex()
                }
                laneExpectations[targetLane] = parentID
                if targetLane != laneIndex {
                    outgoingEdges.append(
                        GraphRow.Edge(fromLane: clampLane(laneIndex), toLane: clampLane(targetLane))
                    )
                }
            }
            // A first parent outside the loaded window still draws a
            // straight same-lane continuation stub rather than closing the
            // lane — "Load More" resumes exactly here.
            if let firstParent = commit.parentIDs.first, !idsInWindow.contains(firstParent) {
                outgoingEdges.append(
                    GraphRow.Edge(fromLane: clampLane(laneIndex), toLane: clampLane(laneIndex))
                )
            }

            let activeLaneCount = laneExpectations.filter { $0 != nil }.count
            let overflow = max(0, activeLaneCount - visibleLaneCap)
            let firstParentLoaded = commit.parentIDs.first.map(idsInWindow.contains) ?? false
            let clampedLane = clampLane(laneIndex)
            let clampedPassing = Array(
                Set(passingLanes.map(clampLane)).subtracting([clampedLane])
            ).sorted()

            rows.append(
                GraphRow(
                    commitID: commit.id,
                    laneIndex: clampedLane,
                    incomingEdges: incomingEdges,
                    outgoingEdges: outgoingEdges,
                    colorIndex: laneIndex,
                    openStubParentIDs: openStubs,
                    overflowLaneCount: overflow,
                    passingLanes: clampedPassing,
                    isMerge: commit.parentIDs.count > 1,
                    hasIncomingRail: !arrivingLanes.isEmpty,
                    hasOutgoingRail: firstParentLoaded
                )
            )
        }
        return rows
    }

    /// The narrowest lane count the rendered rows actually need: one past
    /// the highest lane index any row or edge references, clamped to
    /// `visibleLaneCap` since `layout` already clamps every lane it emits.
    /// Lets the canvas column shrink to a single lane for linear history
    /// instead of always reserving the full cap's width.
    static func laneCount(_ rows: [GraphRow]) -> Int {
        var maxLane = 0
        for row in rows {
            maxLane = max(maxLane, row.laneIndex)
            for edge in row.incomingEdges { maxLane = max(maxLane, edge.fromLane, edge.toLane) }
            for edge in row.outgoingEdges { maxLane = max(maxLane, edge.fromLane, edge.toLane) }
        }
        return max(1, maxLane + 1)
    }
}
