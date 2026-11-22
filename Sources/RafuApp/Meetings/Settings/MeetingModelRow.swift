import RafuCore
import SwiftUI

/// One model of Settings ▸ Meetings ▸ Models and of the download sheet:
/// name, state, licence with a link, attribution, and one button. State is
/// never colour alone: each state has a symbol and a sentence.
struct MeetingModelRow: View {
    let model: MeetingModelID
    let settings: MeetingsSettingsModel
    /// False while a recording or a processing job runs (Remove is not active).
    var canRemove = true

    private var entry: MeetingModelCatalogEntry { MeetingModelCatalog.entry(for: model) }

    private var row: MeetingModelRowState {
        MeetingsSettingsPresentation.modelRowState(
            installState: settings.installState(for: model), entry: entry)
    }

    private var symbol: String {
        if row.isFailure { return "exclamationmark.triangle" }
        switch settings.installState(for: model) {
        case .installed: return "checkmark.circle"
        case .downloading: return "arrow.down.circle"
        case .verifying: return "checkmark.shield"
        case .notInstalled, .failed: return "icloud.and.arrow.down"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayName).font(.headline)
                Spacer(minLength: 8)
                if let button = row.button { actionButton(button) }
            }
            Label(row.text, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let progress = row.progress {
                ProgressView(value: progress)
                    .accessibilityLabel("\(entry.displayName) download")
                    .accessibilityValue(row.text)
            }
            licenceLine
            Text(entry.attribution).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var licenceLine: some View {
        HStack(spacing: 4) {
            Text("Licence:").font(.caption).foregroundStyle(.secondary)
            if let url = URL(string: entry.licenseURL) {
                Link(entry.licenseName, destination: url)
                    .font(.caption)
                    .help("Open the licence of \(entry.displayName)")
            } else {
                Text(entry.licenseName).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ button: MeetingModelRowButton) -> some View {
        switch button {
        case .download:
            Button(button.title) { settings.download(model) }
                .help("Download \(entry.displayName) (\(entry.totalSizeText))")
                .accessibilityLabel("Download \(entry.displayName), \(entry.totalSizeText)")
        case .cancel:
            Button(button.title) { settings.cancelDownload(model) }
                .help("Stop the download of \(entry.displayName)")
                .accessibilityLabel("Cancel the download of \(entry.displayName)")
        case .remove:
            Button(button.title) { settings.pendingRemoval = model }
                .disabled(!canRemove)
                .help(
                    canRemove
                        ? "Remove \(entry.displayName) from this Mac"
                        : "Rafu cannot remove a model while a recording or processing runs."
                )
                .accessibilityLabel("Remove \(entry.displayName)")
        }
    }
}
