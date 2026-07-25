import Foundation

/// One process category in the Resources popover's composition view: every
/// Rafu-spawned process of a single kind, folded into a section header with
/// a count and a summed resident size.
nonisolated struct MemoryProcessGroup: Identifiable, Sendable {
    let kind: ProcessResourceRegistry.ProcessKind
    let rows: [ProcessResourceRegistry.ProcessResourceSample]
    /// Sum over rows that reported a size. `nil` only when NO row in the
    /// group reported one (every pid in it has already exited) — a group
    /// where some pids are gone still totals the survivors rather than
    /// showing nothing.
    let totalBytes: UInt64?

    var id: String { kind.rawValue }
    var count: Int { rows.count }
}

/// Exact counts of what a workspace window is currently holding.
///
/// These are COUNTS, deliberately not byte estimates. macOS gives no
/// per-subsystem breakdown of the process's resident size, and the only way
/// to size Rafu's live buffers from here would be to copy every mounted
/// document's text through `EditorDocument.textSnapshotProvider` — which
/// would allocate a full duplicate of every open file just to measure
/// memory. Counts are exact and free; the byte story is the timeline's job.
nonisolated struct WorkspaceContentMetrics: Sendable, Equatable {
    var mountedDocuments = 0
    var hibernatedDocuments = 0
    var dirtyDocuments = 0
    var terminalSessions = 0
    var fileIndexEntries: Int?
    var isFileIndexTruncated = false
    var hasOpenDiff = false

    var totalDocuments: Int { mountedDocuments + hibernatedDocuments }
}

/// A single rendered line of the content section.
nonisolated struct ContentMetricRow: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let value: String
    let symbol: String
    /// Extra context shown as the row's help/accessibility suffix; empty
    /// when the label and value say everything.
    let note: String
}

nonisolated enum MemoryComposition {
    /// Fixed section order so the list never reshuffles between the 2s
    /// refreshes — Rafu's own processes first, then the noisiest categories.
    static let kindOrder: [ProcessResourceRegistry.ProcessKind] = [
        .terminalShell, .agent, .languageServer, .git, .other,
    ]

    static func title(for kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: return "Terminals"
        case .agent: return "Ensemble Agents"
        case .git: return "Git"
        case .languageServer: return "Language Servers"
        case .other: return "Other"
        }
    }

    static func symbol(for kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: return "terminal"
        case .agent: return "person.crop.rectangle.stack"
        case .git: return "arrow.triangle.branch"
        case .languageServer: return "cpu"
        case .other: return "gearshape"
        }
    }

    /// Folds sampled process rows into ordered, non-empty groups. Rows are
    /// sorted by descending resident size inside a group so the expensive
    /// process is the one you read first; ties keep name order for a stable
    /// list across refreshes.
    static func groups(from rows: [ProcessResourceRegistry.ProcessResourceSample])
        -> [MemoryProcessGroup]
    {
        kindOrder.compactMap { kind in
            let matching = rows.filter { $0.kind == kind }
                .sorted { lhs, rhs in
                    let left = lhs.residentBytes ?? 0
                    let right = rhs.residentBytes ?? 0
                    if left != right { return left > right }
                    return lhs.name < rhs.name
                }
            guard !matching.isEmpty else { return nil }
            let sized = matching.compactMap(\.residentBytes)
            return MemoryProcessGroup(
                kind: kind,
                rows: matching,
                totalBytes: sized.isEmpty ? nil : sized.reduce(0, +)
            )
        }
    }

    /// The content section's rows. A zero-valued category is omitted rather
    /// than shown as "0" — an empty section reads as "nothing here", which
    /// is the point.
    static func contentRows(for metrics: WorkspaceContentMetrics) -> [ContentMetricRow] {
        var rows: [ContentMetricRow] = []
        if metrics.totalDocuments > 0 {
            rows.append(
                ContentMetricRow(
                    id: "documents",
                    label: "Open tabs",
                    value: "\(metrics.totalDocuments)",
                    symbol: "doc.on.doc",
                    note: "\(metrics.mountedDocuments) loaded, "
                        + "\(metrics.hibernatedDocuments) hibernated"
                ))
        }
        if metrics.dirtyDocuments > 0 {
            rows.append(
                ContentMetricRow(
                    id: "dirty",
                    label: "Unsaved",
                    value: "\(metrics.dirtyDocuments)",
                    symbol: "pencil.circle",
                    note: "never hibernated"
                ))
        }
        if metrics.terminalSessions > 0 {
            rows.append(
                ContentMetricRow(
                    id: "terminals",
                    label: "Terminal sessions",
                    value: "\(metrics.terminalSessions)",
                    symbol: "terminal",
                    note: ""
                ))
        }
        if let entries = metrics.fileIndexEntries {
            rows.append(
                ContentMetricRow(
                    id: "fileIndex",
                    label: "File index",
                    value: "\(entries)",
                    symbol: "list.bullet.indent",
                    note: metrics.isFileIndexTruncated ? "truncated" : ""
                ))
        }
        if metrics.hasOpenDiff {
            rows.append(
                ContentMetricRow(
                    id: "diff",
                    label: "Open diff",
                    value: "1",
                    symbol: "plusminus",
                    note: ""
                ))
        }
        return rows
    }
}
