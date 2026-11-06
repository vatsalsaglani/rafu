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
    /// One per open Ensemble in this window, in title order.
    var ensembles: [EnsembleContentMetric] = []

    var totalDocuments: Int { mountedDocuments + hibernatedDocuments }
}

/// Round B (R2): what one open Ensemble holds — counts, plus the bytes the
/// image pool has reserved. Counts only; never card text.
nonisolated struct EnsembleContentMetric: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    var cards = 0
    var imageCards = 0
    var terminalCards = 0
    var webCards = 0
    /// Web cards whose `WKWebView` exists now.
    var liveWebSurfaces = 0
    var reservedImageBytes: UInt64 = 0
    /// The image pool belongs to the window, not to one Ensemble; its bytes
    /// sit on the first row and say "shared" when other Ensembles use it too.
    var imagePoolIsShared = false

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(
        id: String, title: String, contents: [CanvasCardContent], liveWebSurfaces: Int,
        reservedImageBytes: UInt64, imagePoolIsShared: Bool
    ) {
        self.init(id: id, title: title)
        cards = contents.count
        for content in contents {
            switch content {
            case .image: imageCards += 1
            case .terminal: terminalCards += 1
            case .web: webCards += 1
            default: break
            }
        }
        self.liveWebSurfaces = liveWebSurfaces
        self.reservedImageBytes = reservedImageBytes
        self.imagePoolIsShared = imagePoolIsShared
    }

    /// "4 cards".
    var value: String { cards == 1 ? "1 card" : "\(cards) cards" }

    /// "2 images · 1 terminal · 1 web live · ≈ 4.2 MB images (shared)", with
    /// every zero part left out.
    var note: String {
        var parts: [String] = []
        if imageCards > 0 { parts.append(imageCards == 1 ? "1 image" : "\(imageCards) images") }
        if terminalCards > 0 {
            parts.append(terminalCards == 1 ? "1 terminal" : "\(terminalCards) terminals")
        }
        if liveWebSurfaces > 0 {
            parts.append("\(liveWebSurfaces) web live")
        } else if webCards > 0 {
            parts.append("\(webCards) web")
        }
        if reservedImageBytes > 0 {
            parts.append(
                "≈ \(ResourceMemoryFormat.label(reservedImageBytes)) images"
                    + (imagePoolIsShared ? " (shared)" : ""))
        }
        return parts.joined(separator: " · ")
    }
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

/// The ONE place a `ProcessKind` becomes user-visible text or an icon.
///
/// AT-01 and the Resources composition work independently grew a mapping for
/// this — a singular per-row label in the view and a plural section title in
/// `MemoryComposition` — which meant a new kind had to be handled in two
/// files or it would render half-labelled. Both now live here, beside
/// `MemoryComposition.kindOrder`, so adding a `ProcessKind` fails to compile
/// in exactly one file (the switches are exhaustive) and is caught by
/// `processKindsAreFullyPresented` if it is left out of the order.
nonisolated enum ProcessResourcePresentation {
    /// Singular, for a row describing ONE process ("Terminal", "Git").
    static func kindLabel(_ kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: "Terminal"
        case .agent: "Ensemble Agent"
        case .agentTerminal: "Agent Terminal"
        case .git: "Git"
        case .languageServer: "Language Server"
        case .other: "Other"
        }
    }

    /// Plural, for a section heading over all processes of a kind.
    static func sectionTitle(_ kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: "Terminals"
        case .agent: "Ensemble Agents"
        case .agentTerminal: "Agent Terminals"
        case .git: "Git"
        case .languageServer: "Language Servers"
        case .other: "Other"
        }
    }

    static func symbol(_ kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: "terminal"
        case .agent: "person.crop.rectangle.stack"
        case .agentTerminal: "terminal.badge"
        case .git: "arrow.triangle.branch"
        case .languageServer: "cpu"
        case .other: "gearshape"
        }
    }
}

nonisolated enum MemoryComposition {
    /// Fixed section order so the list never reshuffles between the 2s
    /// refreshes — Rafu's own processes first, then the noisiest categories.
    /// Every `ProcessKind` MUST appear here: `groups(from:)` iterates this
    /// list, so a missing kind silently drops those processes from the
    /// composition view rather than failing loudly.
    static let kindOrder: [ProcessResourceRegistry.ProcessKind] = [
        .terminalShell, .agentTerminal, .agent, .languageServer, .git, .other,
    ]

    static func title(for kind: ProcessResourceRegistry.ProcessKind) -> String {
        ProcessResourcePresentation.sectionTitle(kind)
    }

    static func symbol(for kind: ProcessResourceRegistry.ProcessKind) -> String {
        ProcessResourcePresentation.symbol(kind)
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
        // Every open Ensemble, even an empty one: it is an open tab.
        for ensemble in metrics.ensembles {
            rows.append(
                ContentMetricRow(
                    id: "ensemble-\(ensemble.id)",
                    label: ensemble.title,
                    value: ensemble.value,
                    symbol: "circle.hexagongrid",
                    note: ensemble.note
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
