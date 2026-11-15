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
                HundredNotConnectedView(reason: reason)
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

/// The 10 × 10 grid, scaled to fit a square in the space it gets.
private struct HundredGrid: View {
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
private struct HundredLayout {
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
        switch shape {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedSquare:
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.28)
        }
    }
}

private struct HundredLocalEstimateView: View {
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

private struct HundredNotConnectedView: View {
    let reason: WidgetRingsPresentation.NotConnectedReason

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.grid.3x3")
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
