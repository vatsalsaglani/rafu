import RafuCore
import SwiftUI

/// The Meetings tab of the open notch panel and of the menu bar card: the
/// state shape and word, the time, the level meters, the warnings, and the
/// buttons Record / Pause / Resume / Stop / Open Meetings. No title, no
/// name, no transcript text. The companion surfaces draw on their own dark
/// panel, so the colours come from `NotchInk`, as in the other sections.
struct MeetingsCompanionSectionView: View {
    let feature: MeetingsFeature
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let session = feature.session
        let content = MeetingsStatusPolicy.section(
            MeetingsStatusActions.input(
                session: session, canOpenWindow: MeetingsWindowOpener.shared.canOpen,
                floatingBarEnabled: false))
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            if !feature.availability.isAvailable {
                emptyState(
                    message: feature.availability.unavailableReason ?? "", showsRecord: false)
            } else if content.isEmpty {
                emptyState(message: "Record a call from here.", showsRecord: true)
            } else {
                header(content)
                if content.showsMeters {
                    MeetingsCompanionLevelMeters(levels: session.levels, ink: ink)
                }
                ForEach(content.notes, id: \.self) { note in
                    line(symbol: "info.circle", text: note)
                }
                ForEach(content.warnings) { warning in
                    line(symbol: warning.symbol, text: warning.message)
                }
                Spacer(minLength: 0)
                controls(content.buttons)
            }
        }
        .padding(.horizontal, RafuMetrics.space4)
        .padding(.vertical, RafuMetrics.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ content: MeetingsCompanionSectionContent) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: content.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(content.phase == .recording ? Color.red : ink.secondary)
                .accessibilityHidden(true)
            Text(content.word)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink.primary)
            Spacer()
            if let time = content.timeText {
                Text(time)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func line(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11))
        .foregroundStyle(ink.secondary)
    }

    private func controls(_ buttons: [MeetingsStatusButton]) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            ForEach(buttons) { button in
                actionButton(button.title, symbol: button.symbolName, isEnabled: button.isEnabled) {
                    MeetingsStatusActions.perform(button.action, session: feature.session)
                }
            }
            Spacer(minLength: 0)
            openButton
        }
    }

    private var openButton: some View {
        actionButton(
            "Open Meetings", symbol: "rectangle.stack",
            isEnabled: MeetingsWindowOpener.shared.canOpen
        ) {
            MeetingsStatusActions.perform(.openMeetings, session: feature.session)
        }
    }

    private func emptyState(message: String, showsRecord: Bool) -> some View {
        VStack(spacing: RafuMetrics.space2) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(ink.muted)
                .accessibilityHidden(true)
            Text("No recording")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink.primary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(ink.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: RafuMetrics.space2) {
                if showsRecord {
                    actionButton(
                        "Record", symbol: "record.circle",
                        isEnabled: feature.session.canStartRecording
                    ) {
                        MeetingsStatusActions.perform(.startRecording, session: feature.session)
                    }
                }
                openButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionButton(
        _ title: String, symbol: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ink.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(ink.primary.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The two level meters. Only this view reads `levels`, so the ten updates
/// a second redraw only the meters. Each bar has its word ("Me", "Them").
/// No animation, so Reduce Motion needs no extra rule.
struct MeetingsCompanionLevelMeters: View {
    let levels: MeetingsLevelsModel
    let ink: NotchInk

    var body: some View {
        VStack(spacing: RafuMetrics.space1) {
            meter("Me", value: levels.me)
            meter("Them", value: levels.them)
        }
    }

    private func meter(_ word: String, value: Double) -> some View {
        let fraction = min(max(value.isFinite ? value : 0, 0), 1)
        return HStack(spacing: RafuMetrics.space2) {
            Text(word)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ink.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.primary.opacity(0.15))
                    Capsule().fill(ink.primary.opacity(0.8))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(word) level")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
