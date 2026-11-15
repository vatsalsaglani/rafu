import RafuWidgetShared
import SwiftUI
import WidgetKit

/// The Seven widget: one column for each day of the weekly limit window,
/// one dot for each 1% of the limit. Medium shows the first provider,
/// large the first two stacked. Everything it says comes from
/// `WidgetSevenPresentation`.
///
/// Drawn with two `Canvas` layers (no view per dot). The filled usage dots
/// are one `widgetAccentable()` layer; the hollow pace dots, the dashed
/// pace line, the weekday letters, and the "+N" labels are not, so the
/// accented (tinted) style tints only the usage. Hierarchy also comes from
/// opacity and shape: today is the brightest fill with a bold letter and a
/// bar under it, earlier days a softer fill, and the days ahead hollow.
/// Claude draws circles and Codex rounded squares, so two providers never
/// differ by colour alone. No animation: WidgetKit has no continuous
/// animation, so today is brighter, not pulsing.
struct UsageSevenView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var presentation: WidgetSevenPresentation {
        WidgetSevenPresentation.make(
            snapshot: entry.snapshot, now: entry.date,
            maxProviders: family == .systemLarge ? 2 : 1)
    }

    var body: some View {
        let presentation = presentation
        let ink = WidgetInk(inks: entry.snapshot?.inks, palette: presentation.palette)
        Group {
            switch presentation.content {
            case .notConnected(let reason):
                UsageNotConnectedView(reason: reason, systemImage: "chart.bar")
            case .providers(let cards):
                if family == .systemLarge {
                    SevenLargeView(cards: cards, ink: ink, now: entry.date)
                } else if let card = cards.first {
                    SevenMediumView(card: card, ink: ink, now: entry.date)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// Medium: the headline column on the left, the chart on the right.
private struct SevenMediumView: View {
    let card: WidgetSevenCard
    let ink: WidgetInk
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                SevenHeadline(card: card, size: 28)
                if let dayText = card.dayText {
                    Text(dayText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !card.isDimmed, let todayText = card.todayText {
                    Text(todayText)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(card.status.longText(now: now))
                    .font(.caption2.weight(card.status.level == .normal ? .regular : .semibold))
                    .foregroundStyle(ink.levelColor(card.status.level, scheme: scheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                SevenResetCountdown(resetsAt: card.isDimmed ? nil : card.resetsAt)
            }
            .frame(width: 118, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            SevenChartArea(card: card, ink: ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Large: a title row, one panel for each provider, and a legend.
private struct SevenLargeView: View {
    let cards: [WidgetSevenCard]
    let ink: WidgetInk
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent usage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Divider() }
                SevenPanelView(card: card, ink: ink, now: now)
                    .frame(maxHeight: .infinity)
            }
            Text("1 dot = 1% of a weekly limit · dashed line = pace")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SevenPanelView: View {
    let card: WidgetSevenCard
    let ink: WidgetInk
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                SevenHeadline(card: card, size: 18)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if let dayText = card.dayText { Text(dayText) }
                    if !card.isDimmed, let todayText = card.todayText {
                        Text("·")
                        Text(todayText).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            SevenChartArea(card: card, ink: ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                Text(card.status.longText(now: now))
                    .font(.caption2.weight(card.status.level == .normal ? .regular : .semibold))
                    .foregroundStyle(ink.levelColor(card.status.level, scheme: scheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                SevenResetCountdown(resetsAt: card.isDimmed ? nil : card.resetsAt)
            }
        }
    }
}
