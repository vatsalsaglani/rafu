import RafuCore
import SwiftUI

/// The first-use sheet "Download speech models". The Meetings window shows
/// it; this is its content. Neither button changes the stored engine choice,
/// and a running download goes on after the sheet closes (the pane shows its
/// progress).
struct MeetingsModelDownloadSheet: View {
    let feature: MeetingsFeature
    @Environment(\.dismiss) private var dismiss
    @State private var model: MeetingsSettingsModel

    init(feature: MeetingsFeature) {
        self.feature = feature
        _model = State(
            initialValue: MeetingsSettingsModel(
                installer: feature.modelInstaller, textEngines: feature.textEngines,
                speakerEngines: feature.speakerEngines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download speech models").font(.title3.weight(.semibold))
            Text(
                "Rafu uses Apple speech until a model is installed. Models stay on this Mac. Rafu downloads one only when you press Download."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            MeetingModelRow(model: .nemotronEnglish1120, settings: model)
            Divider()
            MeetingModelRow(model: .nemotron3Fast32, settings: model)
            HStack {
                Spacer()
                Button("Use Apple speech for now") { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .help("Close this sheet. Rafu uses Apple speech until a model is installed.")
                Button("Done") { dismiss() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("Close this sheet. A running download goes on.")
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.run() }
    }
}
