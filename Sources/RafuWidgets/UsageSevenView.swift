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
                SevenNotConnectedView(reason: reason)
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

private struct SevenHeadline: View {
    let card: WidgetSevenCard
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(card.headline)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !card.headlineCaption.isEmpty, card.headline != "—" {
                Text(card.headlineCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// `↻ 1 day, 8 hours` with a live countdown.
private struct SevenResetCountdown: View {
    let resetsAt: Date?

    var body: some View {
        if let resetsAt {
            HStack(spacing: 2) {
                Image(systemName: "arrow.clockwise")
                Text(resetsAt, style: .relative).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

/// The chart, or what stands in for it, with the "est." and "no daily
/// data yet" captions.
private struct SevenChartArea: View {
    let card: WidgetSevenCard
    let ink: WidgetInk

    var body: some View {
        if let columns = card.columns {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    if card.hasDailySplit {
                        Text(card.paceLineText)
                    } else {
                        Text("Daily split after Rafu logs a day")
                    }
                    if card.isEstimated {
                        Text("est.").italic()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                SevenChart(
                    columns: columns, paceLineRow: card.paceLineRow, shape: card.shape, ink: ink
                )
                .opacity(card.isDimmed ? 0.45 : 1)
            }
        } else if let tokenSummary = card.tokenSummary {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                Text(tokenSummary)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            Image(systemName: "chart.bar")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .opacity(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Seven columns of dots with the pace line and weekday letters.
private struct SevenChart: View {
    let columns: [WidgetSevenColumn]
    let paceLineRow: Double
    let shape: WidgetDotShape
    let ink: WidgetInk
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        let fill = ink.toneColor(.primary, scheme: scheme, increasedContrast: increased)
        let hollowInk = Color.primary.opacity(increased ? 0.5 : 0.28)
        let lineInk = Color.primary.opacity(increased ? 0.7 : 0.45)
        ZStack {
            Canvas { context, size in
                let layout = SevenLayout(size: size, count: columns.count)
                let y = layout.rowY(paceLineRow)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    line, with: .color(lineInk),
                    style: StrokeStyle(lineWidth: increased ? 1.2 : 0.8, dash: [3, 2.5]))
                for column in columns {
                    for dot in column.filled..<(column.filled + column.hollow) {
                        context.stroke(
                            layout.path(column: column.id, dot: dot, shape: shape, inset: 0.6),
                            with: .color(hollowInk), lineWidth: increased ? 1.1 : 0.8)
                    }
                    let isToday = column.kind == .today
                    let label = context.resolve(
                        Text(column.label)
                            .font(.system(size: 9, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.primary : Color.secondary))
                    context.draw(
                        label,
                        at: CGPoint(x: layout.centerX(column.id), y: layout.labelY),
                        anchor: .center)
                    if isToday {
                        let bar = CGRect(
                            x: layout.centerX(column.id) - 5, y: layout.labelY + 6, width: 10,
                            height: 1.5)
                        context.fill(
                            Path(roundedRect: bar, cornerRadius: 0.75), with: .color(.primary))
                    }
                    if column.overflow > 0 {
                        let more = context.resolve(
                            Text("+\(column.overflow)")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.secondary))
                        context.draw(
                            more,
                            at: CGPoint(x: layout.centerX(column.id), y: layout.top - 1),
                            anchor: .bottom)
                    }
                }
            }
            Canvas { context, size in
                let layout = SevenLayout(size: size, count: columns.count)
                let pastOpacity = increased ? 0.75 : 0.55
                for column in columns where column.filled > 0 {
                    let color = column.kind == .today ? fill : fill.opacity(pastOpacity)
                    for dot in 0..<column.filled {
                        context.fill(
                            layout.path(column: column.id, dot: dot, shape: shape, inset: 0),
                            with: .color(color))
                    }
                }
            }
            .widgetAccentable()
        }
        .accessibilityHidden(true)
    }
}

/// Dot positions: `count` columns across the width, each two dots wide and
/// `WidgetSevenPresentation.rows` dots tall, filled from the bottom; a band
/// on top for "+N" and one at the bottom for the weekday letters.
private struct SevenLayout {
    static let topBand: CGFloat = 10
    static let labelBand: CGFloat = 16

    let columnPitch: CGFloat
    let pitch: CGFloat
    let dot: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    let labelY: CGFloat

    init(size: CGSize, count: Int) {
        let rows = CGFloat(WidgetSevenPresentation.rows)
        columnPitch = size.width / CGFloat(max(1, count))
        let chartHeight = max(1, size.height - Self.topBand - Self.labelBand)
        pitch = max(1, min(columnPitch / 2.6, chartHeight / rows))
        dot = pitch * 0.8
        bottom = Self.topBand + chartHeight
        top = bottom - rows * pitch
        labelY = bottom + Self.labelBand / 2 - 1
    }

    func centerX(_ column: Int) -> CGFloat {
        (CGFloat(column) + 0.5) * columnPitch
    }

    /// The y of a height in dot rows from the column bottom.
    func rowY(_ rows: Double) -> CGFloat {
        bottom - CGFloat(rows) * pitch
    }

    func path(column: Int, dot index: Int, shape: WidgetDotShape, inset: CGFloat) -> Path {
        let perRow = WidgetSevenPresentation.dotsPerRow
        let row = CGFloat(index / perRow)
        let side = CGFloat(index % perRow)
        let gap = (pitch - dot) / 2
        let left = centerX(column) - pitch
        let rect = CGRect(
            x: left + side * pitch + gap, y: bottom - (row + 1) * pitch + gap, width: dot,
            height: dot
        ).insetBy(dx: inset, dy: inset)
        switch shape {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedSquare:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.28)
        }
    }
}

private struct SevenNotConnectedView: View {
    let reason: WidgetRingsPresentation.NotConnectedReason

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text(reason == .rafuNotRunning ? "Rafu is not running" : "Not connected")
                .font(.caption.weight(.semibold))
            Text(reason == .rafuNotRunning ? "Open Rafu ›" : "Open Usage settings ›")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
