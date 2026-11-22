import RafuCore
import SwiftUI

/// The content for the meeting that records: the state and timer, the Me
/// and Them meters, the microphone, each warning, the live text, and the
/// Pause/Resume and Stop buttons. This is the only view of the window that
/// reads the live turns; they stay in the session model.
struct MeetingsLiveView: View {
    let session: MeetingsSessionModel
    let commands: MeetingsWindowCommands
    /// The stored title, when the list has the meeting.
    let title: String?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            header
            HStack(spacing: RafuMetrics.space4) {
                MeetingsLevelMeter(levels: session.levels, track: .me)
                MeetingsLevelMeter(levels: session.levels, track: .them)
            }
            Label {
                Text("Microphone: \(session.microphoneName ?? "—")")
            } icon: {
                Image(systemName: "mic")
            }
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            let warnings = MeetingsWindowPresentation.warningRows(session.warnings)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                    ForEach(warnings) { row in
                        MeetingsWarningRowView(row: row)
                    }
                }
            }
            Divider()
            Text(
                MeetingsWindowPresentation.liveTextLine(
                    engine: session.liveTextEngine, note: session.liveTextNote)
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(theme.palette.textSecondary)
            MeetingsLiveTurnList(turns: session.liveTurns)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Text("This is a preview. Rafu writes the final text after Stop.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        }
        .padding(RafuMetrics.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: RafuMetrics.space3) {
            if let header = MeetingsWindowPresentation.liveHeader(session.recorderState) {
                MeetingsLiveStateBadge(header: header)
            }
            Text(MeetingsWindowPresentation.timerText(session.liveElapsed))
                .font(.title3.monospacedDigit())
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityLabel(
                    "Recorded time \(MeetingsWindowPresentation.timerText(session.liveElapsed))")
            Text(displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
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
            iconButton(
                "pause.fill", label: "Pause", help: "Pause the recording", action: commands.pause)
            stopButton
        case .paused:
            iconButton(
                "play.fill", label: "Resume", help: "Resume the recording", action: commands.resume)
            stopButton
        case .idle, .starting, .stopping, .problem:
            EmptyView()
        }
    }

    private var stopButton: some View {
        iconButton(
            "stop.fill", label: "Stop",
            help: "Stop the recording. Rafu then writes the final text.", action: commands.stop)
    }

    private func iconButton(
        _ symbol: String, label: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(RafuIconButtonStyle(size: 30, iconSize: 14))
        .accessibilityLabel(label)
        .help(help)
    }
}

/// "● Rec", "❚❚ Paused", "Starting…", "Stopping…". The dot pulses only while
/// it records, and never with Reduce Motion.
private struct MeetingsLiveStateBadge: View {
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
        .font(.headline)
        .foregroundStyle(theme.palette.textPrimary)
    }
}

/// One level meter. Only this view reads the levels, so the rest of the
/// window does not redraw ten times a second.
private struct MeetingsLevelMeter: View {
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
                .font(.callout.weight(.medium))
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
private struct MeetingsWarningRowView: View {
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
        .font(.callout)
        .padding(.horizontal, RafuMetrics.space2)
        .padding(.vertical, RafuMetrics.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.palette.cardBackground,
            in: RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(row.message)")
    }
}

/// The live turns. It follows the newest line unless the user scrolled up.
private struct MeetingsLiveTurnList: View {
    let turns: [MeetingLiveTurn]

    @State private var followsNewest = true
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    ForEach(turns) { turn in
                        MeetingsLiveTurnRow(turn: turn)
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

private struct MeetingsLiveTurnRow: View {
    let turn: MeetingLiveTurn

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Label {
                Text(MeetingsWindowPresentation.speakerWord(turn.track))
            } icon: {
                Image(systemName: MeetingsWindowPresentation.speakerSymbol(turn.track))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(width: 64, alignment: .leading)
            Text(MeetingClockText.text(turn.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
            Text(turn.text)
                .foregroundStyle(
                    turn.isVolatile ? theme.palette.textSecondary : theme.palette.textPrimary
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
