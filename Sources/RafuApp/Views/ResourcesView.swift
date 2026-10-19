import AppKit
import SwiftUI

/// The single memory reading for the whole process (its footprint, as
/// Activity Monitor shows it). The status bar and the Resources popover both
/// read it, so they always show the same number. Reading is on demand (the popover's visible-only loop, or the
/// status bar's opt-in loop); there is no timer of its own.
@Observable
@MainActor
final class ResidentMemoryMonitor {
    static let shared = ResidentMemoryMonitor()

    private(set) var sample: ProcessMemorySample?

    init() {}

    func refresh() {
        sample = ProcessMemorySampler().sample()
    }
}

/// The one-line summary at the top of the Resources popover, built from the
/// same data as the rows below it.
nonisolated enum ResourceSummary {
    static func line(
        appBytes: UInt64?,
        groups: [MemoryProcessGroup],
        languageServerCount: Int
    ) -> String {
        let terminalGroups = groups.filter {
            $0.kind == .terminalShell || $0.kind == .agentTerminal
        }
        let terminalCount = terminalGroups.reduce(0) { $0 + $1.count }
        let terminalBytes = terminalGroups.compactMap(\.totalBytes).reduce(0, +)

        var terminals = "\(terminalCount) \(terminalCount == 1 ? "terminal" : "terminals")"
        if terminalCount > 0, terminalBytes > 0 {
            terminals += " \(ResourceMemoryFormat.label(terminalBytes))"
        }
        let servers =
            "\(languageServerCount) \(languageServerCount == 1 ? "language server" : "language servers")"
        return "Rafu \(ResourceMemoryFormat.label(appBytes)) · \(terminals) · \(servers)"
    }
}

/// Height rule for the Resources popover: as tall as its content, but never
/// taller than the window minus 40 pt, scrolling beyond that.
nonisolated enum ResourcesPopoverLayout {
    static let windowMargin: CGFloat = 40
    static let minimumScrollHeight: CGFloat = 160
    static let fallbackWindowHeight: CGFloat = 600

    static func scrollHeight(
        headerHeight: CGFloat,
        contentHeight: CGFloat,
        windowHeight: CGFloat?
    ) -> CGFloat {
        let available =
            (windowHeight ?? fallbackWindowHeight) - windowMargin - headerHeight
        return min(contentHeight, max(minimumScrollHeight, available))
    }
}

/// Locale-independent MB/GB byte formatting for the Resources popover. Uses
/// `String(format:)` (POSIX `%f` semantics) rather than `NumberFormatter` so
/// the rendered string is identical regardless of the user's decimal
/// separator, keeping tests deterministic across locales.
nonisolated enum ResourceMemoryFormat {
    private static let mebibyte: Double = 1024 * 1024
    private static let gibibyte: Double = 1024 * 1024 * 1024

    static func label(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let value = Double(bytes)
        if value >= gibibyte {
            return String(format: "%.1f GB", value / gibibyte)
        }
        return String(format: "%.1f MB", value / mebibyte)
    }
}

/// Pure state → icon/label/restart-eligibility mapping for one language
/// server's `LanguageServerStatus.Phase`, mirroring `ResourceMemoryFormat`.
/// State is always conveyed by an SF Symbol (shape-distinct per phase) plus
/// a text label — never by color alone.
nonisolated enum LanguageServerStatusPresentation {
    static func stateLabel(_ phase: LanguageServerStatus.Phase) -> String {
        switch phase {
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .idle: return "Idle"
        case .warmingUp: return "Indexing"
        case .backingOff: return "Restarting…"
        case .dead: return "Stopped"
        case .ceilingKilled: return "Stopped — memory limit"
        }
    }

    /// Whether a "Restart" action should be offered for `phase`. Only
    /// terminal, non-recovering states qualify: `.dead` (backoff
    /// exhausted, manual restart only) and `.ceilingKilled` (the RSS
    /// watchdog killed it, ADR 0005's "kill + notify, offer restart").
    /// `.backingOff` already auto-retries on its own schedule, and every
    /// live phase has nothing to restart.
    static func showsRestart(_ phase: LanguageServerStatus.Phase) -> Bool {
        switch phase {
        case .dead, .ceilingKilled: return true
        case .starting, .ready, .idle, .warmingUp, .backingOff: return false
        }
    }

    /// Shape-distinct (not color-dependent) SF Symbols per phase.
    static func symbol(_ phase: LanguageServerStatus.Phase) -> String {
        switch phase {
        case .starting: return "circle.dotted"
        case .ready: return "checkmark.circle"
        case .idle: return "pause.circle"
        case .warmingUp: return "hourglass"
        case .backingOff: return "arrow.clockwise"
        case .dead: return "exclamationmark.triangle"
        case .ceilingKilled: return "exclamationmark.triangle"
        }
    }
}

/// The Resources popover's two views of the same process.
private enum ResourcesTab: String, CaseIterable, Identifiable {
    case composition
    case timeline

    var id: String { rawValue }
    var title: String {
        switch self {
        case .composition: return "Composition"
        case .timeline: return "Timeline"
        }
    }
}

/// Rafu's honest process memory, in two views.
///
/// **Composition** — what exists right now: Rafu's own memory footprint, then
/// one section per category of Rafu-spawned process (terminals, Ensemble
/// agents, language servers, git) with per-category totals, then exact
/// counts of what this window is holding, then language-server status with a
/// manual restart action (ADR 0005: the RSS-ceiling watchdog "kills and
/// notifies, offers restart" — this is that surface).
///
/// **Timeline** — how it got here: recent activity with the change in
/// process-wide resident memory measured shortly after each action. These
/// are interval correlations, NOT per-action costs; macOS exposes no
/// per-subsystem breakdown of a task's own resident size, and the UI says so
/// rather than implying a partition it cannot compute.
///
/// Samples only while this popover is visible — the `.task` loop sleeps and
/// is cancelled when the view disappears, so there is no standing timer.
struct ResourcesView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var rows: [ProcessResourceRegistry.ProcessResourceSample] = []
    @State private var tab: ResourcesTab = .composition
    @State private var showsExplanation = false
    @State private var headerHeight: CGFloat = 96
    @State private var contentHeight: CGFloat = 320
    let coordinator: LanguageIntelligenceCoordinator
    /// Optional so the popover still renders in contexts that have no
    /// workspace session to count (and so previews/tests stay cheap); the
    /// content section is simply omitted when absent.
    var session: WorkspaceSession?

    private var timeline = MemoryTimeline.shared
    /// The one memory sample shared with the status bar, so the
    /// number in the bar and in this popover can never disagree.
    private var memory = ResidentMemoryMonitor.shared

    init(coordinator: LanguageIntelligenceCoordinator, session: WorkspaceSession? = nil) {
        self.coordinator = coordinator
        self.session = session
    }

    private var serverStatuses: [LanguageServerStatus] {
        coordinator.servers.statuses.values.sorted { $0.languageID < $1.languageID }
    }

    private var groups: [MemoryProcessGroup] {
        MemoryComposition.groups(from: rows)
    }

    /// "Rafu 145.1 MB · 2 terminals 1.1 MB · 0 language servers".
    private var summaryLine: String {
        ResourceSummary.line(
            appBytes: memory.sample?.displayBytes,
            groups: groups,
            languageServerCount: serverStatuses.count
        )
    }

    private static let compositionExplanation =
        "Rafu's number is its memory footprint, as Activity Monitor shows it. "
        + "Every Rafu window shares one process, so this number and the process "
        + "sections below cover all open windows, not just this one. They are "
        + "separate processes Rafu spawned, not slices of that number."

    private static let timelineExplanation =
        "Change in the whole app's resident memory measured shortly after each "
        + "action, across all open windows. It covers everything happening in "
        + "that interval, so treat it as a correlation, not the action's cost."

    private var contentRows: [ContentMetricRow] {
        guard let session else { return [] }
        return MemoryComposition.contentRows(for: WorkspaceContentAdapter.metrics(for: session))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    headerHeight = $0
                }
            Divider().overlay(theme.palette.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .composition: compositionContent
                    case .timeline: timelineContent
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
            .frame(
                height: ResourcesPopoverLayout.scrollHeight(
                    headerHeight: headerHeight + 1,
                    contentHeight: contentHeight,
                    windowHeight: NSApp.keyWindow?.contentLayoutRect.height
                )
            )
        }
        .frame(width: 340)
        .task {
            while !Task.isCancelled {
                memory.refresh()
                rows = await ProcessResourceRegistry.shared.sample()
                timeline.recordPeriodicReading()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Resources", systemImage: "memorychip")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    showsExplanation.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(RafuIconButtonStyle(isActive: showsExplanation, size: 24))
                .help("About these numbers")
                .accessibilityLabel("About these numbers")
                .accessibilityValue(showsExplanation ? "Shown" : "Hidden")
            }
            Text(summaryLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Summary: \(summaryLine)")
            if showsExplanation {
                Text(tab == .composition ? Self.compositionExplanation : Self.timelineExplanation)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RafuSegmentedPicker(
                items: ResourcesTab.allCases,
                selection: $tab,
                fillsWidth: true
            ) { $0.title }
            .accessibilityLabel("View")
        }
        .padding(12)
    }

    // MARK: - Composition

    @ViewBuilder
    private var compositionContent: some View {
        appRow

        if groups.isEmpty {
            Text("No other Rafu-spawned processes.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        } else {
            ForEach(groups) { group in
                // Scope is spelled out per section, not once at the top: a
                // scrolled-past caption cannot stop "Terminals · 5" from
                // reading as this window's five terminals when three of them
                // belong to another window.
                sectionHeader(
                    "\(MemoryComposition.title(for: group.kind)) — All Windows",
                    trailing: "\(group.count) · \(ResourceMemoryFormat.label(group.totalBytes))"
                )
                ForEach(group.rows, id: \.id) { row in
                    processRow(row, kind: group.kind)
                }
            }
        }

        if !contentRows.isEmpty {
            sectionHeader("This Window Only", trailing: nil)
            ForEach(contentRows) { row in
                contentRow(row)
            }
        }

        sectionHeader("Language Servers — All Windows", trailing: nil)
        if serverStatuses.isEmpty {
            Text("No language servers running.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        } else {
            ForEach(serverStatuses, id: \.languageID) { status in
                languageServerRow(status)
            }
        }
    }

    private var appRow: some View {
        let label = ResourceMemoryFormat.label(memory.sample?.displayBytes)
        return resourceRow {
            HStack {
                Label("Rafu (this app)", systemImage: "app.badge")
                Spacer()
                RafuChip(text: label, monospacedDigit: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rafu, this app, \(label)")
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.palette.textMuted)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func processRow(
        _ row: ProcessResourceRegistry.ProcessResourceSample,
        kind: ProcessResourceRegistry.ProcessKind
    ) -> some View {
        let label = ResourceMemoryFormat.label(row.residentBytes)
        let kindTitle = MemoryComposition.title(for: kind)
        return resourceRow {
            HStack {
                Label(row.name, systemImage: MemoryComposition.symbol(for: kind))
                    .lineLimit(1)
                Spacer()
                RafuChip(text: label, monospacedDigit: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(kindTitle), \(label)")
    }

    private func contentRow(_ row: ContentMetricRow) -> some View {
        resourceRow {
            HStack {
                Label(row.label, systemImage: row.symbol)
                    .lineLimit(1)
                Spacer()
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                }
                RafuChip(text: row.value, monospacedDigit: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            row.note.isEmpty
                ? "\(row.label), \(row.value)"
                : "\(row.label), \(row.value), \(row.note)")
    }

    private func languageServerRow(_ status: LanguageServerStatus) -> some View {
        let stateLabel = LanguageServerStatusPresentation.stateLabel(status.phase)
        let showsRestart = LanguageServerStatusPresentation.showsRestart(status.phase)
        return resourceRow {
            HStack {
                Label(
                    status.serverName,
                    systemImage: LanguageServerStatusPresentation.symbol(status.phase))
                Spacer()
                RafuChip(text: stateLabel)
                if showsRestart {
                    Button("Restart") {
                        coordinator.restartServer(languageID: status.languageID)
                    }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .accessibilityLabel("Restart \(status.serverName)")
                }
            }
        }
        .accessibilityElement(children: showsRestart ? .contain : .combine)
        .accessibilityLabel("\(status.serverName), \(stateLabel)")
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineContent: some View {
        MemorySparkline(readings: timeline.readings)
            .frame(height: 44)
            .accessibilityLabel("Resident memory trend")
            .accessibilityValue(
                "\(timeline.readings.count) readings, latest "
                    + ResourceMemoryFormat.label(timeline.readings.last))

        if timeline.recentEvents.isEmpty {
            Text("No activity recorded yet.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(timeline.recentEvents) { entry in
                timelineRow(entry)
            }
        }
    }

    private func timelineRow(_ entry: MemoryTimelineEntry) -> some View {
        let delta = MemoryTimelinePolicy.deltaLabel(entry.deltaBytes)
        let direction = MemoryTimelinePolicy.deltaSymbol(entry.deltaBytes)
        let total = ResourceMemoryFormat.label(entry.residentBytes)
        let subtitle = MemoryTimelinePolicy.subtitle(
            for: entry, currentWindow: session?.memoryTimelineSource ?? "")
        return resourceRow {
            HStack(spacing: 6) {
                Image(systemName: entry.kind.symbol)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.kind.title).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(theme.palette.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    // Direction is carried by the arrow glyph as well as the
                    // sign, so the row never depends on color alone.
                    Label(delta, systemImage: direction)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(deltaColor(entry.deltaBytes))
                    Text(total)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.kind.title)\(subtitle.isEmpty ? "" : ", \(subtitle)"), "
                + "\(delta), total \(total)")
    }

    private func deltaColor(_ bytes: Int64) -> Color {
        if bytes > 0 { return theme.palette.warning }
        if bytes < 0 { return theme.palette.success }
        return theme.palette.textMuted
    }

    // MARK: - Shared row chrome

    private func resourceRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(theme.palette.cardBackground)
            )
    }
}

/// The resident-memory trend line. Deliberately unlabeled on the axes: this
/// is a shape, not a chart — the numbers live in the rows below it. Falls
/// back to a flat mid-line for a single reading, matching
/// `MemoryTimelinePolicy.normalized`.
private struct MemorySparkline: View {
    @Environment(\.rafuTheme) private var theme
    let readings: [UInt64]

    var body: some View {
        let points = MemoryTimelinePolicy.normalized(readings)
        return GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(theme.palette.cardBackground)
                if points.count >= 2 {
                    path(points, in: proxy.size)
                        .stroke(
                            theme.palette.textSecondary,
                            style: .init(lineWidth: 1.5, lineJoin: .round)
                        )
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                } else {
                    Text("Collecting readings…")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
        }
        .accessibilityElement()
    }

    private func path(_ points: [Double], in size: CGSize) -> Path {
        let width = max(size.width - 16, 1)
        let height = max(size.height - 12, 1)
        let step = width / Double(points.count - 1)
        return Path { path in
            for (index, value) in points.enumerated() {
                // Normalized 0 is the LOW reading, which must draw at the
                // BOTTOM — SwiftUI's y grows downward, hence the inversion.
                let point = CGPoint(x: Double(index) * step, y: (1 - value) * height)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }
}

/// The one place a live `WorkspaceSession` is read for composition counts,
/// mirroring `NotchScreenAdapter`'s role for notch geometry: everything
/// downstream of `WorkspaceContentMetrics` is pure and headless-testable.
@MainActor
enum WorkspaceContentAdapter {
    static func metrics(for session: WorkspaceSession) -> WorkspaceContentMetrics {
        var metrics = WorkspaceContentMetrics()
        for document in session.openDocuments {
            if document.loadState == .hibernated {
                metrics.hibernatedDocuments += 1
            } else {
                metrics.mountedDocuments += 1
            }
            if document.isDirty { metrics.dirtyDocuments += 1 }
        }
        metrics.terminalSessions = session.terminal.sessions.count
        if case .ready(let count, let isTruncated) = session.fileIndexState {
            metrics.fileIndexEntries = count
            metrics.isFileIndexTruncated = isTruncated
        }
        metrics.hasOpenDiff = session.gitOpenDiff != nil
        return metrics
    }
}
