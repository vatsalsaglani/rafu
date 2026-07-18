import SwiftUI

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

/// Rafu's honest process memory: its own resident size plus one row per
/// Rafu-spawned process tracked in `ProcessResourceRegistry` (terminal
/// shells today; language servers in lane 2), plus a "Language Servers"
/// section surfacing each server's status and a manual restart action
/// (ADR 0005: the RSS-ceiling watchdog "kills and notifies, offers
/// restart" — this is that surface). Samples only while this popover is
/// visible — the `.task` loop sleeps and is cancelled when the view
/// disappears, so there is no standing timer.
struct ResourcesView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var appSample: ProcessMemorySample?
    @State private var rows: [ProcessResourceRegistry.ProcessResourceSample] = []
    let coordinator: LanguageIntelligenceCoordinator

    private var serverStatuses: [LanguageServerStatus] {
        coordinator.servers.statuses.values.sorted { $0.languageID < $1.languageID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Resources", systemImage: "memorychip")
                .font(.headline)
                .padding(12)
            Divider().overlay(theme.palette.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    appRow
                    if rows.isEmpty {
                        Text("No other Rafu-spawned processes.")
                            .font(.caption)
                            .foregroundStyle(theme.palette.textMuted)
                    } else {
                        ForEach(rows, id: \.id) { row in
                            processRow(row)
                        }
                    }

                    Divider().overlay(theme.palette.borderSubtle).padding(.vertical, 4)
                    Text("Language Servers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.palette.textMuted)
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
                .padding(12)
            }
        }
        .frame(width: 320, height: 280)
        .task {
            let sampler = ProcessMemorySampler()
            while !Task.isCancelled {
                appSample = sampler.sample()
                rows = await ProcessResourceRegistry.shared.sample()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private var appRow: some View {
        let label = ResourceMemoryFormat.label(appSample?.residentBytes)
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

    private func processRow(_ row: ProcessResourceRegistry.ProcessResourceSample) -> some View {
        let label = ResourceMemoryFormat.label(row.residentBytes)
        let kind = kindLabel(row.kind)
        return resourceRow {
            HStack {
                Label(row.name, systemImage: symbol(for: row.kind))
                Spacer()
                RafuChip(text: label, monospacedDigit: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(kind), \(label)")
    }

    private func resourceRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(theme.palette.cardBackground)
            )
    }

    private func kindLabel(_ kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: return "Terminal"
        case .git: return "Git"
        case .languageServer: return "Language Server"
        case .other: return "Other"
        }
    }

    private func symbol(for kind: ProcessResourceRegistry.ProcessKind) -> String {
        switch kind {
        case .terminalShell: return "terminal"
        case .git: return "arrow.triangle.branch"
        case .languageServer: return "cpu"
        case .other: return "gearshape"
        }
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
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.palette.accent)
                    .accessibilityLabel("Restart \(status.serverName)")
                }
            }
        }
        .accessibilityElement(children: showsRestart ? .contain : .combine)
        .accessibilityLabel("\(status.serverName), \(stateLabel)")
    }
}
