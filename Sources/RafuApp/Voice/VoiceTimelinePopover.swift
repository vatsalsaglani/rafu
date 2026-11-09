import RafuCore
import SwiftUI

/// The voice session timeline (VPLAN section 11), drawn as capsules in the
/// order things happened: what you said, what Rafu said, and each delegation
/// with its steps. A running delegation shows a turning ring with its step
/// count and "Working N s"; a finished one shows "Thought for N s", a count
/// and a Completed or Failed pill, and opens to its steps. The rows stay
/// after the session closes, so the user can read the last session; the next
/// open clears them. Rows show ids, tool names, counts and times; the You
/// capsule shows at most 120 characters of the user's own words. Colours come
/// from the active theme, custom themes included.
struct VoiceTimelinePopover: View {
    let session: VoiceSession
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @State private var clock = VoiceTimelineClock(knownMS: 0, at: .now)
    @State private var tick = 0

    /// The elapsed text of a running row updates four times a second.
    static let elapsedInterval: Duration = .milliseconds(250)

    static func title(_ lane: VoiceTimelineEvent.Lane) -> String {
        switch lane {
        case .you: "You"
        case .voice: "Rafu"
        case .delegation: "Delegations"
        case .tool: "Tools"
        case .board: "Board effects"
        }
    }

    var body: some View {
        let events = session.timeline.events
        let isOpen = session.blobState.isOpen
        let items = VoiceTimelineGrouping.items(events: events, sessionOpen: isOpen)
        let nowMS = currentNowMS()
        let latest = VoiceTimelineGrouping.latestKnownMS(events)
        let running = items.contains { if case .group(let g) = $0 { g.isRunning } else { false } }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voice Timeline").font(.headline)
                Spacer()
                Text(!isOpen && !events.isEmpty ? "Last session ended" : session.blobState.word)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .padding(12)
            Divider()
            if events.isEmpty {
                Text(isOpen ? "Nothing yet in this session." : "No voice session is open.")
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items.suffix(200)) { item in
                            VoiceTimelineItemView(item: item, nowMS: nowMS)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 360, height: 400, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice timeline")
        .onChange(of: latest, initial: true) { _, known in
            clock.note(knownMS: known, at: .now)
        }
        .task(id: running && motionAllowed) { await tickWhileRunning(running && motionAllowed) }
    }

    /// Session milliseconds now. Reading `tick` makes the 4 Hz write redraw
    /// the running times.
    private func currentNowMS() -> Int {
        _ = tick
        return clock.nowMS(at: .now)
    }

    /// Redraws the elapsed text of a running row at 4 Hz. No task runs when
    /// nothing is running or the window cannot show motion; the loop dies
    /// with the popover.
    private func tickWhileRunning(_ active: Bool) async {
        guard active else { return }
        var still = Transaction()
        still.disablesAnimations = true
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.elapsedInterval, tolerance: .milliseconds(50))
            } catch {
                return
            }
            withTransaction(still) { tick &+= 1 }
        }
    }
}

// MARK: Items

private struct VoiceTimelineItemView: View {
    let item: VoiceTimelineItem
    let nowMS: Int

    var body: some View {
        switch item {
        case .you(let row): VoiceYouCapsule(row: row)
        case .rafu(let row): VoiceRafuCapsule(row: row)
        case .group(let group): VoiceGroupCapsule(group: group, nowMS: nowMS)
        case .standalone(let row): VoiceStepCapsule(row: row, nowMS: nowMS)
        }
    }
}

/// The capsule surface: one fill and one hairline from the theme, a solid
/// colour, so Reduce Transparency changes nothing here.
private struct VoiceCapsuleSurface: ViewModifier {
    var emphasised = false
    @Environment(\.rafuTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(emphasised ? theme.palette.cardBackground : theme.palette.chipBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.palette.borderSubtle, lineWidth: 1)
            )
    }
}

extension View {
    fileprivate func voiceCapsule(emphasised: Bool = false) -> some View {
        modifier(VoiceCapsuleSurface(emphasised: emphasised))
    }
}

/// What the user said: a quiet capsule with the words.
private struct VoiceYouCapsule: View {
    let row: VoiceTimelineEvent
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            Text(row.detail.isEmpty ? "You" : row.detail)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .voiceCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceTimelineFormat.spoken(row))
    }
}

/// What Rafu said, or a Rafu notice: a small orb and the duration.
private struct VoiceRafuCapsule: View {
    let row: VoiceTimelineEvent
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            VoiceTimelineOrbGlyph()
            Text(row.title).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            Text(VoiceTimelineFormat.duration(row))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
        }
        .voiceCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceTimelineFormat.spoken(row))
    }
}

/// A 14 pt still orb in the theme's accent: Rafu's mark on its own rows.
private struct VoiceTimelineOrbGlyph: View {
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [theme.palette.accent.opacity(0.55), theme.palette.accent],
                    center: .topLeading, startRadius: 0, endRadius: 12)
            )
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

// MARK: Delegation group

/// One delegation: header capsule, and the steps below it when open.
private struct VoiceGroupCapsule: View {
    let group: VoiceTimelineGroup
    let nowMS: Int
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen: Bool

    init(group: VoiceTimelineGroup, nowMS: Int) {
        self.group = group
        self.nowMS = nowMS
        // A running delegation shows its steps as they arrive.
        _isOpen = State(initialValue: group.isRunning)
    }

    private var ringPhase: VoiceRunningRing.Phase {
        switch group.outcome {
        case .none: .running(steps: group.stepCount)
        case .ok: .done
        case .failed: .failed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(VoiceTimelineFormat.spoken(group: group, nowMS: nowMS))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides the steps." : "Shows the steps.")
            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if group.children.isEmpty {
                        Text("No steps yet.")
                            .font(.caption)
                            .foregroundStyle(theme.palette.textMuted)
                            .padding(.leading, 12)
                    }
                    ForEach(group.children) { row in
                        VoiceStepCapsule(row: row, nowMS: nowMS)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VoiceRunningRing(phase: ringPhase)
            if group.isRunning { VoicePixelLoader() }
            Text(VoiceTimelineFormat.groupTitle(group, nowMS: nowMS))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
            Text(VoiceTimelineFormat.stepCount(group.stepCount))
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let outcome = group.outcome { VoiceOutcomePill(outcome: outcome) }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .accessibilityHidden(true)
        }
        .voiceCapsule(emphasised: true)
        .contentShape(Rectangle())
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : RafuMotion.selection) { isOpen.toggle() }
    }
}

// MARK: Step

/// One tool or board row. Closed: ring, title, duration, pill. Open: the
/// detail and the timing line.
private struct VoiceStepCapsule: View {
    let row: VoiceTimelineEvent
    let nowMS: Int
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    private var ringPhase: VoiceRunningRing.Phase {
        guard row.endMS != nil else { return .running(steps: nil) }
        return row.outcome == .failed ? .failed : .done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VoiceRunningRing(phase: ringPhase)
                Text(row.title).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                Text(VoiceTimelineFormat.stepDuration(row, nowMS: nowMS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
                if row.endMS != nil { VoiceOutcomePill(outcome: row.outcome ?? .ok) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.palette.textMuted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(3)
                    }
                    Text("\(row.id) · \(VoiceTimelineFormat.timing(row))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.palette.textMuted)
                }
                .padding(.leading, 28)
            }
        }
        .voiceCapsule()
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceTimelineFormat.spoken(row))
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : RafuMotion.selection) { isOpen.toggle() }
    }
}

/// The "Completed" or "Failed" pill. The word and the symbol carry the
/// meaning; the colour is secondary.
private struct VoiceOutcomePill: View {
    let outcome: VoiceTimelineEvent.Outcome
    @Environment(\.rafuTheme) private var theme

    private var color: Color {
        outcome == .failed ? theme.palette.error : theme.palette.success
    }

    var body: some View {
        Text(VoiceTimelineFormat.outcomeLabel(outcome))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

// MARK: Text

/// Times as text: the start offset and the duration, or "running".
nonisolated enum VoiceTimelineFormat {
    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.1f s", Double(milliseconds) / 1_000)
    }

    static func timing(_ row: VoiceTimelineEvent) -> String {
        let start = "+" + seconds(row.startMS)
        guard let end = row.endMS else { return "\(start) · running" }
        return "\(start) · \(seconds(max(0, end - row.startMS)))"
    }

    /// The length of a finished row, or "running".
    static func duration(_ row: VoiceTimelineEvent) -> String {
        guard let end = row.endMS else { return "running" }
        return seconds(max(0, end - row.startMS))
    }

    /// A step's time: its length once done, the live count while it runs.
    static func stepDuration(_ row: VoiceTimelineEvent, nowMS: Int) -> String {
        seconds(max(0, (row.endMS ?? nowMS) - row.startMS))
    }

    /// The pill word.
    static func outcomeLabel(_ outcome: VoiceTimelineEvent.Outcome) -> String {
        switch outcome {
        case .ok: "Completed"
        case .failed: "Failed"
        }
    }

    /// The word VoiceOver adds after a row's times.
    static func outcomeWord(_ outcome: VoiceTimelineEvent.Outcome) -> String {
        switch outcome {
        case .ok: "completed"
        case .failed: "failed"
        }
    }

    static func stepCount(_ count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }

    /// "Thought for 4.2 s" when finished, "Working 4.2 s" while running.
    static func groupTitle(_ group: VoiceTimelineGroup, nowMS: Int) -> String {
        let time = seconds(group.durationMS(nowMS: nowMS))
        return group.isRunning ? "Working \(time)" : "Thought for \(time)"
    }

    static func spoken(_ row: VoiceTimelineEvent) -> String {
        var parts = ["\(row.id), \(row.title)"]
        if !row.detail.isEmpty { parts.append(row.detail) }
        parts.append("at \(seconds(row.startMS))")
        if let end = row.endMS {
            parts.append("took \(seconds(max(0, end - row.startMS)))")
        } else {
            parts.append("running")
        }
        if let outcome = row.outcome { parts.append(outcomeWord(outcome)) }
        return parts.joined(separator: ", ")
    }

    /// A delegation, for VoiceOver. A running one leaves the time out, so the
    /// label does not change four times a second.
    static func spoken(group: VoiceTimelineGroup, nowMS: Int) -> String {
        var parts = ["\(group.header.id), delegation"]
        if let outcome = group.outcome {
            parts.append("thought for \(seconds(group.durationMS(nowMS: nowMS)))")
            parts.append(stepCount(group.stepCount))
            parts.append(outcomeWord(outcome))
        } else {
            parts.append("working")
            parts.append(stepCount(group.stepCount))
        }
        return parts.joined(separator: ", ")
    }
}
