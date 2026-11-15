import RafuWidgetShared
import SwiftUI
import WidgetKit

/// The Hundred widget: 100 dots are one weekly limit. Small shows the first
/// provider, medium the first two side by side. Everything it says comes
/// from `WidgetHundredPresentation`.
///
/// Drawn with two `Canvas` layers (no view per dot), so the extension
/// stays far under its memory limit. The used, today, and projected dots
/// are one `widgetAccentable()` layer; the spare dots and the time marker
/// are not, so the accented (tinted) style tints only the usage. Hierarchy
/// also comes from opacity and shape: today is the brightest fill, earlier
/// days alternate two softer fills, projected dots are rings with a centre
/// point, and spare dots are hollow. Claude draws circles and Codex rounded
/// squares, so two providers never differ by colour alone. No animation:
/// WidgetKit has no continuous animation.
struct UsageHundredView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var presentation: WidgetHundredPresentation {
        WidgetHundredPresentation.make(
            snapshot: entry.snapshot, now: entry.date,
            maxProviders: family == .systemSmall ? 1 : 2)
    }

    var body: some View {
        let presentation = presentation
        let ink = WidgetInk(inks: entry.snapshot?.inks, palette: presentation.palette)
        Group {
            switch presentation.content {
            case .notConnected(let reason):
                UsageNotConnectedView(reason: reason, systemImage: "circle.grid.3x3")
            case .providers(let cards):
                if family == .systemSmall, let card = cards.first {
                    HundredProviderView(card: card, ink: ink, now: entry.date, compact: true)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(cards) { card in
                            HundredProviderView(
                                card: card, ink: ink, now: entry.date, compact: false)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private struct HundredProviderView: View {
    let card: WidgetHundredCard
    let ink: WidgetInk
    let now: Date
    let compact: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(card.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(card.headline)
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                if !card.headlineCaption.isEmpty, card.headline != "—" {
                    Text(card.headlineCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let dots = card.dots {
                HundredGrid(
                    dots: dots, marker: card.elapsedMarkerIndex, shape: card.shape, ink: ink
                )
                .opacity(card.isDimmed ? 0.45 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HundredLocalEstimateView(tokenSummary: card.tokenSummary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                Text(compact ? card.status.shortText(now: now) : card.status.longText(now: now))
                    .font(.caption2.weight(card.status.level == .normal ? .regular : .semibold))
                    .foregroundStyle(ink.levelColor(card.status.level, scheme: scheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if compact, !card.isDimmed, let todayText = card.todayText {
                    Spacer(minLength: 2)
                    Text(todayText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if !compact, !card.isDimmed {
                HStack(spacing: 6) {
                    if let todayText = card.todayText {
                        Text(todayText).monospacedDigit()
                    }
                    if let resetsAt = card.resetsAt {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise")
                            Text(resetsAt, style: .relative).monospacedDigit()
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
