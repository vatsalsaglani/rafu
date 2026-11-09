import RafuCore
import SwiftUI

/// The voice session timeline (VPLAN section 11): five lanes from the
/// session's in-memory `VoiceTimeline`, live while the session is open. The
/// rows stay after the session closes, so the user can read the last
/// session; the next open clears them. Rows show ids, tool names, counts and times; the
/// You lane shows at most 120 characters of the user's own words.
struct VoiceTimelinePopover: View {
    let session: VoiceSession
    @Environment(\.rafuTheme) private var theme

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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Voice Timeline").font(.headline)
                Spacer()
                Text(
                    !session.blobState.isOpen && !events.isEmpty
                        ? "Last session ended" : session.blobState.word
                )
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            }
            .padding(12)
            Divider()
            if events.isEmpty {
                Text(
                    session.blobState.isOpen
                        ? "Nothing yet in this session." : "No voice session is open."
                )
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(VoiceTimelineEvent.Lane.allCases, id: \.self) { lane in
                            VoiceTimelineLane(
                                title: Self.title(lane), rows: events.filter { $0.lane == lane })
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 360, height: 400, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice timeline")
    }
}

/// One lane: a heading and its rows, newest last. An empty lane says so.
private struct VoiceTimelineLane: View {
    let title: String
    let rows: [VoiceTimelineEvent]
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(rows.count))")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
            } else {
                ForEach(rows.suffix(50)) { row in
                    VoiceTimelineRow(row: row)
                }
            }
        }
    }
}

private struct VoiceTimelineRow: View {
    let row: VoiceTimelineEvent
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.id)
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout).lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(VoiceTimelineFormat.timing(row))
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoiceTimelineFormat.spoken(row))
    }
}

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

    static func spoken(_ row: VoiceTimelineEvent) -> String {
        var parts = ["\(row.id), \(row.title)"]
        if !row.detail.isEmpty { parts.append(row.detail) }
        parts.append("at \(seconds(row.startMS))")
        if let end = row.endMS {
            parts.append("took \(seconds(max(0, end - row.startMS)))")
        } else {
            parts.append("running")
        }
        return parts.joined(separator: ", ")
    }
}
