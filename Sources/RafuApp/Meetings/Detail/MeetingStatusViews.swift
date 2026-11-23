import RafuCore
import SwiftUI

// The content of a meeting that is not ready: the live body while it
// records, the processing card after Stop, and the failed card when
// processing stopped. The Meetings window and the meeting tab both show
// these, so a tab never sends the user to the window.

/// The page header of a status view: the meeting title, 20 pt semibold.
private struct MeetingStatusTitle: View {
    let title: String

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(theme.palette.textPrimary)
            .lineLimit(2)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A status card: card fill, a subtle border and the dense card radius.
private struct MeetingStatusCardSurface: ViewModifier {
    @Environment(\.rafuTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(RafuMetrics.space4)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                theme.palette.cardBackground,
                in: RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
            )
    }
}

// MARK: - Live

/// The content for the meeting that records: the state and timer with
/// Pause and Stop, the Me and Them meters, the microphone, each warning,
/// and the live lines. This is the only view that reads the live turns;
/// they stay in the session model.
struct MeetingLiveBody: View {
    let session: MeetingsSessionModel
    let commands: MeetingsWindowCommands
    /// The stored title, when the list has the meeting.
    let title: String?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            MeetingStatusTitle(title: displayTitle)
            header
            HStack(spacing: RafuMetrics.space4) {
                MeetingLiveLevelMeter(levels: session.levels, track: .me)
                MeetingLiveLevelMeter(levels: session.levels, track: .them)
            }
            Label {
                Text("Microphone: \(session.microphoneName ?? "None found")")
            } icon: {
                Image(systemName: "mic")
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.palette.textSecondary)
            let warnings = MeetingsWindowPresentation.warningRows(session.warnings)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    ForEach(warnings) { row in
                        MeetingLiveWarningRow(row: row)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
            Divider()
            Text(
                MeetingsWindowPresentation.liveTextLine(
                    engine: session.liveTextEngine, note: session.liveTextNote)
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.palette.textMuted)
            MeetingLiveTurnList(turns: session.liveTurns)
                .frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
            Text("Preview. Rafu writes the final text after you stop.")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
        }
        .padding(RafuMetrics.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: RafuMetrics.space3) {
            if let header = MeetingsWindowPresentation.liveHeader(session.recorderState) {
                MeetingLiveStateBadge(header: header)
            }
            Text(MeetingsFormat.clock(session.liveElapsed))
                .font(.system(size: 20, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityLabel(
                    "Recorded time \(MeetingsFormat.spokenDuration(session.liveElapsed))")
            Spacer(minLength: RafuMetrics.space2)
            controls
        }
    }

    private var displayTitle: String {
        if !session.liveTitle.isEmpty { return session.liveTitle }
        if let title, !title.isEmpty { return title }
        return "New recording"
    }

    @ViewBuilder
    private var controls: some View {
        switch session.recorderState {
        case .recording:
            controlButton("Pause", "pause.fill", help: "Pause the recording", commands.pause)
            stopButton
        case .paused:
            controlButton("Resume", "play.fill", help: "Resume the recording", commands.resume)
            stopButton
        case .idle, .starting, .stopping, .problem:
            EmptyView()
        }
    }

    private var stopButton: some View {
        controlButton(
            "Stop", "stop.fill", help: "Stop the recording. Rafu then writes the final text.",
            commands.stop)
    }

    private func controlButton(
        _ title: String, _ symbol: String, help: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        .help(help)
    }
}

/// "● Recording", "❚❚ Paused", "Starting…", "Stopping…". The dot pulses
/// only while it records, and never with Reduce Motion.
private struct MeetingLiveStateBadge: View {
    let header: MeetingsLiveHeader

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Label {
            Text(header.word)
        } icon: {
            Image(systemName: header.symbol)
                .foregroundStyle(
                    header.isRecording ? theme.palette.error : theme.palette.textSecondary
                )
                .symbolEffect(
                    .pulse, options: .repeating, isActive: header.isRecording && !reduceMotion)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.palette.textPrimary)
    }
}

/// One level meter. Only this view reads the levels, so the rest of the
/// view does not redraw ten times a second.
private struct MeetingLiveLevelMeter: View {
    let levels: MeetingsLevelsModel
    let track: MeetingTrack

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let level = min(max(track == .me ? levels.me : levels.them, 0), 1)
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: MeetingsWindowPresentation.speakerSymbol(track))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            Text(MeetingsWindowPresentation.speakerWord(track))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
            Capsule()
                .fill(theme.palette.chipBackground)
                .frame(width: 140, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(theme.palette.accent)
                        .frame(width: 140 * level, height: 6)
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: level)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MeetingsWindowPresentation.speakerWord(track)) level")
        .accessibilityValue(
            MeetingsWindowPresentation.meterAccessibilityValue(track: track, level: level))
    }
}

/// One warning: its symbol and message, always visible.
private struct MeetingLiveWarningRow: View {
    let row: MeetingsWarningRow

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Label {
            Text(row.message)
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: row.symbol)
                .foregroundStyle(theme.palette.warning)
        }
        .font(.system(size: 13))
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.palette.cardBackground,
            in: RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(row.message)")
    }
}

/// The live lines. It follows the newest line unless the user scrolled up.
private struct MeetingLiveTurnList: View {
    let turns: [MeetingLiveTurn]

    @State private var followsNewest = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RafuMetrics.space3) {
                    ForEach(turns) { turn in
                        MeetingLiveTurnRow(turn: turn)
                            .id(turn.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, RafuMetrics.space1)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                followsNewest = atBottom
            }
            .onChange(of: turns.last) { _, last in
                guard followsNewest, let last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// One live line in the transcript row style: the speaker and the time on
/// one line, the text below.
private struct MeetingLiveTurnRow: View {
    let turn: MeetingLiveTurn

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                Text(MeetingsWindowPresentation.speakerWord(turn.track))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(MeetingsFormat.clock(turn.start))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
            }
            Text(turn.text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(
                    turn.isVolatile ? theme.palette.textSecondary : theme.palette.textPrimary
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Processing

/// The content after Stop: the title, then a card with the step, a bar, the
/// three steps with checks, and Cancel.
struct MeetingProcessingCard: View {
    let title: String
    let progress: MeetingsProcessingProgress
    let onCancel: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            MeetingStatusTitle(title: title)
            VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                Text(progress.label)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.palette.textPrimary)
                    .accessibilityHidden(true)
                bar
                VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    ForEach(progress.stages) { stage in
                        MeetingProcessingStageRow(stage: stage)
                    }
                }
                if progress.showsModelNote {
                    Text(MeetingsStatePresentation.modelNote)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Cancel", action: onCancel)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Stop processing. The audio is kept.")
            }
            .modifier(MeetingStatusCardSurface())
        }
        .padding(RafuMetrics.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = progress.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(theme.palette.accent)
                .accessibilityLabel(progress.stepTitle)
                .accessibilityValue(MeetingsFormat.spokenPercent(fraction))
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(theme.palette.accent)
                .accessibilityLabel(progress.label)
        }
    }
}

/// One step of the processing card: a check when done, a ring for the step
/// that runs, an empty circle for a step to come. Never colour alone.
private struct MeetingProcessingStageRow: View {
    let stage: MeetingsProcessingStage

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Label {
            Text(stage.title)
                .foregroundStyle(
                    stage.progress == .waiting
                        ? theme.palette.textMuted : theme.palette.textPrimary)
        } icon: {
            Image(systemName: stage.symbol)
                .foregroundStyle(iconColor)
                .frame(width: 16)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.title), \(spokenProgress)")
    }

    private var iconColor: Color {
        switch stage.progress {
        case .done: theme.palette.success
        case .current: theme.palette.accent
        case .waiting: theme.palette.textMuted
        }
    }

    private var spokenProgress: String {
        switch stage.progress {
        case .done: "done"
        case .current: "in progress"
        case .waiting: "waiting"
        }
    }
}

// MARK: - Failed

/// The content when processing stopped: the title, then a card with the
/// reason, "The audio is kept.", "Try Again" and "Delete…".
struct MeetingFailedCard: View {
    let title: String
    let reason: MeetingsFailureReason
    let canDelete: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            MeetingStatusTitle(title: title)
            VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.palette.warning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                        Text(MeetingsStatePresentation.failedTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text(reason.sentence + " " + MeetingsStatePresentation.audioKept)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: RafuMetrics.space2) {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(RafuProminentButtonStyle())
                        .help("Write the text from the kept audio again")
                    Button("Delete…", action: onDelete)
                        .buttonStyle(RafuSecondaryButtonStyle())
                        .disabled(!canDelete)
                        .help("Delete this meeting")
                }
            }
            .modifier(MeetingStatusCardSurface())
        }
        .padding(RafuMetrics.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
