import RafuWidgetShared
import SwiftUI
import WidgetKit

// The dot drawing the Hundred, Seven, and Board widgets share: the
// Hundred grid, the Seven columns, and the labels around them. Moved here
// unchanged from `UsageHundredView` and `UsageSevenView` so the Board draws
// exactly what those widgets draw.

extension WidgetDotShape {
    /// The mark in `rect`: a circle, or a square with corners at 28% of
    /// its side.
    func path(in rect: CGRect) -> Path {
        switch self {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedSquare:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.28)
        }
    }
}

// MARK: - Hundred

/// The 10 × 10 grid, scaled to fit a square in the space it gets.
struct HundredGrid: View {
    let dots: [WidgetHundredDot]
    let marker: Int?
    let shape: WidgetDotShape
    let ink: WidgetInk
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        let fill = ink.toneColor(.primary, scheme: scheme, increasedContrast: increased)
        let spareInk = Color.primary.opacity(increased ? 0.45 : 0.25)
        let markerInk = Color.primary
        ZStack {
            Canvas { context, size in
                let layout = HundredLayout(size: size)
                for (index, dot) in dots.enumerated() where dot == .spare {
                    context.stroke(
                        layout.path(index: index, shape: shape, inset: 0.75),
                        with: .color(spareInk), lineWidth: increased ? 1.2 : 0.8)
                }
                if let marker, dots.indices.contains(marker) {
                    context.stroke(
                        layout.path(index: marker, shape: shape, inset: -1.2),
                        with: .color(markerInk), lineWidth: 1.2)
                }
            }
            Canvas { context, size in
                let layout = HundredLayout(size: size)
                let bandOpacities = increased ? [0.75, 0.6] : [0.55, 0.38]
                for (index, dot) in dots.enumerated() {
                    switch dot {
                    case .today:
                        context.fill(
                            layout.path(index: index, shape: shape, inset: 0),
                            with: .color(fill))
                    case .used(let band):
                        context.fill(
                            layout.path(index: index, shape: shape, inset: 0),
                            with: .color(fill.opacity(bandOpacities[band % 2])))
                    case .projected:
                        context.stroke(
                            layout.path(index: index, shape: shape, inset: 0.75),
                            with: .color(fill.opacity(0.85)), lineWidth: 1)
                        context.fill(
                            layout.path(
                                index: index, shape: .circle, inset: layout.dot * 0.33),
                            with: .color(fill.opacity(0.85)))
                    case .spare:
                        break
                    }
                }
            }
            .widgetAccentable()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Dot positions for a square 10 × 10 grid inside `size`.
struct HundredLayout {
    let origin: CGPoint
    let pitch: CGFloat
    let dot: CGFloat

    init(size: CGSize) {
        let side = min(size.width, size.height)
        let columns = CGFloat(WidgetHundredPresentation.columns)
        pitch = side / columns
        dot = pitch * 0.78
        origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
    }

    func path(index: Int, shape: WidgetDotShape, inset: CGFloat) -> Path {
        let columns = WidgetHundredPresentation.columns
        let row = CGFloat(index / columns)
        let column = CGFloat(index % columns)
        let gap = (pitch - dot) / 2
        let rect = CGRect(
            x: origin.x + column * pitch + gap, y: origin.y + row * pitch + gap, width: dot,
            height: dot
        ).insetBy(dx: inset, dy: inset)
        return shape.path(in: rect)
    }
}

struct HundredLocalEstimateView: View {
    let tokenSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "circle.grid.3x3")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .widgetAccentable()
            if let tokenSummary {
                Text(tokenSummary)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

// MARK: - Seven

struct SevenHeadline: View {
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
struct SevenResetCountdown: View {
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
struct SevenChartArea: View {
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
struct SevenChart: View {
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
struct SevenLayout {
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
        return shape.path(in: rect)
    }
}

/// "Not connected" or "Rafu is not running", with the widget's own symbol.
struct UsageNotConnectedView: View {
    let reason: WidgetRingsPresentation.NotConnectedReason
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
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
