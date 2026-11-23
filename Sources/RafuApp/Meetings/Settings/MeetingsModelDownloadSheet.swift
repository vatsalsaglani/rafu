import RafuCore
import SwiftUI

/// The first-use sheet "Choose a speech model". The Meetings window shows
/// it; this is its content. WhisperKit comes first, as the recommended
/// model. "Done" does not change the stored engine choice, and a running
/// download goes on after the sheet closes (the pane shows its progress).
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
            Text("Choose a speech model").font(.title3.weight(.semibold))
            Text(
                "Rafu writes the text on this Mac. Apple speech is used until a model is installed."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                RafuChip(text: "Recommended")
                MeetingModelRow(model: .whisperLargeV3, settings: model)
            }
            Divider()
            MeetingModelRow(model: .nemotronEnglish1120, settings: model)
            Divider()
            MeetingModelRow(model: .nemotron3Fast32, settings: model)
            HStack {
                Spacer()
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
