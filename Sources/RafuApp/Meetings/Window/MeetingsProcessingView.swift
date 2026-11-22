import RafuCore
import SwiftUI

/// The content for a stopped meeting that is not ready: the step with its
/// progress and Cancel, or "Processing stopped" with Try again and Delete…
struct MeetingsProcessingView: View {
    let meeting: MeetingID
    let summary: MeetingSummaryRecord?
    let step: MeetingsProcessingStep?
    let commands: MeetingsWindowCommands
    let onDelete: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            switch MeetingsWindowPresentation.processingDisplay(state: summary?.state, step: step) {
            case .running(let label, let fraction, let showsModelNote):
                VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    Label {
                        Text(label)
                    } icon: {
                        Image(systemName: MeetingsRowStatus.processing.symbol)
                    }
                    .foregroundStyle(theme.palette.textPrimary)
                    if let fraction {
                        ProgressView(value: fraction)
                            .accessibilityLabel(label)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .accessibilityLabel(label)
                    }
                    if showsModelNote {
                        Text("The first use of a model takes about a minute.")
                            .font(.callout)
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                Button("Cancel") { commands.cancelProcessing(meeting) }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .help("Stop processing. The audio is kept.")
            case .stopped(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: MeetingsRowStatus.failed.symbol)
                        .foregroundStyle(theme.palette.warning)
                }
                .foregroundStyle(theme.palette.textPrimary)
                HStack(spacing: RafuMetrics.space2) {
                    Button("Try again") { commands.retryProcessing(meeting) }
                        .buttonStyle(RafuProminentButtonStyle())
                        .help("Write the text from the kept audio again")
                    Button("Delete…", action: onDelete)
                        .buttonStyle(RafuSecondaryButtonStyle())
                        .disabled(summary == nil || !commands.canDelete(meeting))
                        .help("Delete this meeting")
                }
            }
        }
        .padding(RafuMetrics.space5 + RafuMetrics.space2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        guard let summary, !summary.title.isEmpty else { return "Untitled meeting" }
        return summary.title
    }
}
