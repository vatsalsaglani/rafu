import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `Timeline`: events on a vertical rail, oldest first as given. At most 200.
@JRComponent(
    "Timeline",
    description: "Events on a vertical rail: events [{time, title, text?, intent?}], at most 200.")
nonisolated struct RafuTimeline: View {
    @JRProp(description: "Events of {time, title, text?, intent?}.")
    var events: [JSONRenderCore.JSONValue]

    @Environment(\.jsonRenderTheme) private var theme

    struct Event {
        let time: String
        let title: String
        let text: String?
        let intent: GeneratedViewIntent
    }

    var body: some View {
        let events = Self.events(events)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                HStack(alignment: .top, spacing: theme.space.s2) {
                    VStack(spacing: 0) {
                        Group {
                            if let symbol = event.intent.symbol {
                                Image(systemName: symbol).font(.system(size: 9))
                            } else {
                                Circle().frame(width: 7, height: 7)
                            }
                        }
                        .foregroundStyle(event.intent.color(theme))
                        .frame(width: 12, height: 14)
                        if index < events.count - 1 {
                            Rectangle().fill(theme.color.hairline).frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: theme.space.s2) {
                            Text(event.title)
                                .font(theme.type.bodyEmphasis)
                                .foregroundStyle(theme.color.text)
                            Spacer(minLength: 0)
                            Text(event.time)
                                .font(theme.type.caption.monospacedDigit())
                                .foregroundStyle(theme.color.textSecondary)
                        }
                        if let text = event.text {
                            Text(text)
                                .font(theme.type.footnote)
                                .foregroundStyle(theme.color.textSecondary)
                        }
                    }
                    .padding(.bottom, theme.space.s3)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        [event.time, event.title, event.text ?? "", event.intent.word]
                            .filter { !$0.isEmpty }.joined(separator: ", ")))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func events(_ values: [JSONRenderCore.JSONValue]) -> [Event] {
        values.prefix(RafuKeyValue.rowLimit).compactMap { value in
            guard case .object(let members) = value else { return nil }
            return Event(
                time: members["time"].map(RafuStat.text) ?? "",
                title: members["title"].map(RafuStat.text) ?? "",
                text: members["text"]?.stringValue,
                intent: GeneratedViewIntent(members["intent"]?.stringValue))
        }
    }
}
