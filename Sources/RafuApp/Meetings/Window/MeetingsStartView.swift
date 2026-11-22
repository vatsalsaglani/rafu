import RafuCore
import SwiftUI

/// The content when nothing is selected and nothing records: a large
/// Record button and the facts of the next recording.
struct MeetingsStartView: View {
    let feature: MeetingsFeature
    let commands: MeetingsWindowCommands
    let onDownload: () -> Void
    let microphoneReader: any MeetingsMicrophoneReading

    @State private var microphone: MeetingsMicrophoneSummary?
    @State private var engineLine: MeetingsEngineLine?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RafuMetrics.space4) {
                Text("New recording")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                MeetingsRecordButton(feature: feature, commands: commands, prominent: true)
                VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    factLine(
                        "speaker.wave.2",
                        "Records all sound that this Mac plays, and your microphone.")
                    microphoneLine
                    if microphone?.isHeadset == true {
                        factLine(
                            MeetingsLiveWarning.headsetMicrophone.symbol,
                            MeetingsLiveWarning.headsetMicrophone.message, warning: true)
                    }
                    factLine("lock.laptopcomputer", "Rafu writes the transcript on this Mac.")
                    if let engineLine {
                        HStack(spacing: RafuMetrics.space1) {
                            factLine("text.bubble", engineLine.text)
                            if engineLine.offersDownload, feature.modelDownloadSheet != nil {
                                Button("Download…", action: onDownload)
                                    .buttonStyle(.link)
                                    .help("Download the speech model")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(RafuMetrics.space5 + RafuMetrics.space2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            microphone = await microphoneReader.read()
            engineLine = await loadEngineLine()
        }
    }

    private var microphoneLine: some View {
        HStack(spacing: RafuMetrics.space1) {
            factLine("mic", "Microphone: \(microphone?.name ?? "None found")")
            Button("Change") {
                SettingsPaneRouter.shared.request(.meetings)
                openSettings()
            }
            .buttonStyle(.link)
            .help("Choose the microphone in Settings ▸ Meetings")
        }
    }

    private func factLine(_ symbol: String, _ text: String, warning: Bool = false) -> some View {
        Label {
            Text(text)
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(warning ? theme.palette.warning : theme.palette.textMuted)
        }
    }

    private func loadEngineLine() async -> MeetingsEngineLine {
        var availability: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in feature.textEngines {
            availability[id] = await engine.availability()
        }
        let preference = UserDefaultsMeetingPreferences().speechPreferences().textEngine
        return MeetingsWindowPresentation.engineLine(
            preference: preference, availability: availability)
    }
}
