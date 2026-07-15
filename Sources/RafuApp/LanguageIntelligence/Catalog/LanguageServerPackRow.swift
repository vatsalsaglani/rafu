import SwiftUI

/// One row for a `ServerPack`: its member servers and a single Install
/// action that installs the shared runtime once plus every member, via
/// `LanguageServersCatalogModel.beginInstallPack(id:)`'s consent flow.
struct LanguageServerPackRow: View {
    let pack: LanguageServersCatalogModel.PackRowState
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.pack.displayName)
                    .font(.body.weight(.medium))
                Text(pack.pack.serverIDs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pack.progressActive {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel", role: .cancel) { onCancel() }
                }
            } else {
                Button("Install Pack…") { onInstall() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(pack.pack.displayName))
        .accessibilityValue(Text(summaryText))
    }

    private var summaryText: String {
        let installedCount = pack.pack.serverIDs.filter {
            if case .installed = pack.memberStates[$0] { return true }
            return false
        }.count
        return "\(installedCount) of \(pack.pack.serverIDs.count) installed"
    }
}
