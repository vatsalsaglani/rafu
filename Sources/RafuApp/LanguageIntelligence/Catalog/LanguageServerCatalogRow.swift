import SwiftUI

/// One row in the Language Servers catalog: a curated entry or a custom
/// user entry, showing its languages, install state, and the action
/// cluster appropriate to that state. Pure display plus button actions —
/// no I/O, no logic beyond simple state-to-text mapping.
struct LanguageServerCatalogRow: View {
    let row: LanguageServersCatalogModel.CatalogRowState
    let onInstall: () -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    let onCancel: () -> Void
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.descriptor.displayName)
                    .font(.body.weight(.medium))
                Text(row.descriptor.languageIDs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(stateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let source = row.descriptor.source {
                    Text("\(source.license) · \(sizeText(source.estimatedBytes))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            actionCluster
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.descriptor.displayName))
        .accessibilityValue(Text(stateText))
    }

    @ViewBuilder
    private var actionCluster: some View {
        if row.progressActive {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel", role: .cancel) { onCancel() }
            }
        } else {
            HStack(spacing: 8) {
                switch row.installState {
                case .notInstalled:
                    Button("Install…") { onInstall() }
                case .installed:
                    Button("Update") { onUpdate() }
                    Button("Uninstall", role: .destructive) { onUninstall() }
                case .availableViaToolchain:
                    Text("Available").foregroundStyle(.secondary)
                case .unavailableToolchain, .prerequisiteMissing:
                    Text("Not Available").foregroundStyle(.secondary)
                }
                if let onRemove {
                    Button("Remove", role: .destructive) { onRemove() }
                }
            }
        }
    }

    private var stateText: String {
        switch row.installState {
        case .notInstalled: return "Not installed"
        case .installed(let version): return "Installed · \(version)"
        case .availableViaToolchain: return "Available via installed toolchain"
        case .unavailableToolchain: return "Toolchain not found on this Mac"
        case .prerequisiteMissing: return "Prerequisite not available"
        }
    }

    private func sizeText(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown size" }
        return Int64(bytes).formatted(.byteCount(style: .file))
    }
}
