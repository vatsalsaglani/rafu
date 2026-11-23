import RafuCore
import SwiftUI

/// The content when nothing is selected and nothing records: a centred
/// column with the title, one "Start Recording" button, and a card with
/// the three facts of the next recording.
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                MeetingsStartRecordingButton(feature: feature, commands: commands)
                facts
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, RafuMetrics.space5)
            .padding(.top, 72)
            .padding(.bottom, RafuMetrics.space5)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task {
            microphone = await microphoneReader.read()
            engineLine = await loadEngineLine()
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            MeetingsStartFactRow(
                symbol: "speaker.wave.2",
                text: "Records the sound of this Mac and your microphone.")
            MeetingsStartFactRow(
                symbol: "mic", text: "Microphone: \(microphone?.name ?? "None found")"
            ) {
                Button("Change…") {
                    SettingsPaneRouter.shared.request(.meetings)
                    openSettings()
                }
                .buttonStyle(.link)
                .help("Choose the microphone in Settings ▸ Meetings")
            }
            if microphone?.isHeadset == true {
                MeetingsStartFactRow(
                    symbol: MeetingsLiveWarning.headsetMicrophone.symbol,
                    text: MeetingsLiveWarning.headsetMicrophone.message, isWarning: true)
            }
            MeetingsStartFactRow(
                symbol: "lock.laptopcomputer", text: engineLine?.text ?? "Text: on this Mac."
            ) {
                if engineLine?.offersDownload == true, feature.modelDownloadSheet != nil {
                    Button("Download…", action: onDownload)
                        .buttonStyle(.link)
                        .help("Download the speech model")
                }
            }
        }
        .padding(RafuMetrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.palette.cardBackground,
            in: RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
        )
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

/// One fact of the start card: a 20 pt icon column, the text, and an
/// optional link button.
private struct MeetingsStartFactRow<Accessory: View>: View {
    let symbol: String
    let text: String
    var isWarning = false
    @ViewBuilder let accessory: Accessory

    @Environment(\.rafuTheme) private var theme

    init(
        symbol: String, text: String, isWarning: Bool = false,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.symbol = symbol
        self.text = text
        self.isWarning = isWarning
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isWarning ? theme.palette.warning : theme.palette.textMuted)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            accessory
            Spacer(minLength: 0)
        }
    }
}

/// "Start Recording": not active when a recording cannot start, with the
/// reason as help text and hint. It never starts a second recording. The
/// icon takes the on-accent colour (no red on the accent fill).
private struct MeetingsStartRecordingButton: View {
    let feature: MeetingsFeature
    let commands: MeetingsWindowCommands

    var body: some View {
        let session = feature.session
        let reason = MeetingsWindowPresentation.recordDisabledReason(
            availability: feature.availability, recorderState: session.recorderState,
            isDriverInstalled: session.isDriverInstalled)
        Button {
            commands.record()
        } label: {
            Label("Start Recording", systemImage: "record.circle")
        }
        .buttonStyle(RafuProminentButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(reason != nil || !session.canStartRecording)
        .help(reason ?? "Start a new recording")
        .accessibilityLabel("Start recording")
        .accessibilityHint(reason ?? "Starts a new recording")
    }
}
