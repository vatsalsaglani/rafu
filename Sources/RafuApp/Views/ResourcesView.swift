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

/// Rafu's honest process memory: its own resident size plus one row per
/// Rafu-spawned process tracked in `ProcessResourceRegistry` (terminal
/// shells today; language servers in lane 2). Samples only while this
/// popover is visible — the `.task` loop sleeps and is cancelled when the
/// view disappears, so there is no standing timer.
struct ResourcesView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var appSample: ProcessMemorySample?
    @State private var rows: [ProcessResourceRegistry.ProcessResourceSample] = []

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
        return HStack {
            Label("Rafu (this app)", systemImage: "app.badge")
            Spacer()
            Text(label)
                .foregroundStyle(theme.palette.textMuted)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rafu, this app, \(label)")
    }

    private func processRow(_ row: ProcessResourceRegistry.ProcessResourceSample) -> some View {
        let label = ResourceMemoryFormat.label(row.residentBytes)
        let kind = kindLabel(row.kind)
        return HStack {
            Label(row.name, systemImage: symbol(for: row.kind))
            Spacer()
            Text(label)
                .foregroundStyle(theme.palette.textMuted)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(kind), \(label)")
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
}
