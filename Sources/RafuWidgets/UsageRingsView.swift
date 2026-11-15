import RafuWidgetShared
import SwiftUI
import WidgetKit

/// The Rings widget. Small shows the first provider, medium the first two.
/// Everything it says comes from `WidgetRingsPresentation`, which runs the
/// app's own ring, pace, and level rules. Plain shapes only, so the
/// extension stays far under its memory limit.
///
/// Rendering modes: the ring fills and legend swatches are
/// `widgetAccentable()`, so the accented (tinted) desktop style tints them;
/// the tracks are not. Hierarchy also comes from opacity and ring order, so
/// vibrant and accented modes stay readable. Warnings always carry a glyph
/// and words.
struct UsageRingsView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var presentation: WidgetRingsPresentation {
        WidgetRingsPresentation.make(
            snapshot: entry.snapshot, now: entry.date,
            maxProviders: family == .systemSmall ? 1 : 2)
    }

    var body: some View {
        let presentation = presentation
        let ink = WidgetInk(inks: entry.snapshot?.inks, palette: presentation.palette)
        Group {
            switch presentation.content {
            case .notConnected(let reason):
                NotConnectedView(reason: reason)
            case .providers(let cards):
                if family == .systemSmall, let card = cards.first {
                    SmallProviderView(card: card, ink: ink, now: entry.date)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(cards) { card in
                            MediumProviderView(card: card, ink: ink, now: entry.date)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// The rings' colours for this snapshot and desktop appearance. Colour
/// mode uses the theme's accent, info, and success hues (as the app's
/// `UsageCardInk`); Monochrome uses the primary ink at the app's stepped
/// opacities. A missing or bad theme hex falls back to a system colour.
struct WidgetInk {
    let inks: WidgetUsageSnapshot.ThemeInks?
    let palette: UsageRingPalette

    func set(for scheme: ColorScheme) -> WidgetUsageSnapshot.InkSet? {
        scheme == .dark ? inks?.dark : inks?.light
    }

    func toneColor(_ tone: UsageRingTone, scheme: ColorScheme, increasedContrast: Bool) -> Color {
        let index: Int =
            switch tone {
            case .primary: 0
            case .secondary: 1
            case .tertiary: 2
            }
        switch palette {
        case .color:
            let set = set(for: scheme)
            let hexes = [set?.accent, set?.info, set?.success]
            let fallbacks: [Color] = [.accentColor, .teal, .green]
            return Self.color(hex: hexes[index]) ?? fallbacks[index]
        case .monochrome:
            let opacities = UsageRingPalette.monochromeOpacities(
                increasedContrast: increasedContrast)
            return Color.primary.opacity(opacities[min(index, opacities.count - 1)])
        }
    }

    /// `nil` lets each ring tint its own track.
    func trackColor(increasedContrast: Bool) -> Color? {
        palette == .monochrome
            ? Color.primary.opacity(
                UsageRingPalette.monochromeTrackOpacity(increasedContrast: increasedContrast))
            : nil
    }

    func levelColor(_ level: UsageRingLevel, scheme: ColorScheme) -> Color {
        let set = set(for: scheme)
        switch level {
        case .normal: return .secondary
        case .warning: return Self.color(hex: set?.warning) ?? .orange
        case .critical: return Self.color(hex: set?.critical) ?? .red
        }
    }

    static func color(hex: String?) -> Color? {
        guard let hex, let rgba = WidgetRGBA(hex: hex) else { return nil }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

/// Concentric rings, outermost first, with the app's geometry
/// (`RafuProgressRing`) and no animation.
private struct WidgetRingCluster: View {
    let cluster: UsageRingCluster
    let ink: WidgetInk
    let size: CGFloat
    let lineWidth: CGFloat
    let gap: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        let track = ink.trackColor(increasedContrast: increased)
        ZStack {
            ForEach(Array(cluster.arcs.enumerated()), id: \.offset) { index, arc in
                let diameter = size - 2 * CGFloat(index) * (lineWidth + gap)
                if diameter >= lineWidth * 2 {
                    let color = ink.toneColor(
                        arc.tone, scheme: scheme, increasedContrast: increased)
                    ZStack {
                        Circle()
                            .stroke(
                                track ?? color.opacity(increased ? 0.35 : 0.22),
                                lineWidth: lineWidth)
                        if let fraction = arc.fraction {
                            Circle()
                                .trim(from: 0, to: CGFloat(fraction))
                                .stroke(
                                    color,
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .widgetAccentable()
                        }
                    }
                    .frame(width: diameter, height: diameter)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The status line: a glyph-bearing text in the level colour.
private struct StatusLine: View {
    let text: String
    let level: UsageRingLevel
    let ink: WidgetInk
    let lineLimit: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.caption2.weight(level == .normal ? .regular : .semibold))
            .foregroundStyle(ink.levelColor(level, scheme: scheme))
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `↻ 1 day, 8 hours` with a live countdown, so the reset ages without a
/// timeline reload.
private struct ResetCountdown: View {
    let resetsAt: Date?

    var body: some View {
        if let resetsAt {
            HStack(spacing: 2) {
                Image(systemName: "arrow.clockwise")
                Text(resetsAt, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

private struct SmallProviderView: View {
    let card: WidgetProviderCard
    let ink: WidgetInk
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let cluster = card.cluster {
                    Text(cluster.centerText)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if let cluster = card.cluster {
                WidgetRingCluster(cluster: cluster, ink: ink, size: 62, lineWidth: 8, gap: 2)
                    .opacity(card.isDimmed ? 0.45 : 1)
                    .frame(maxWidth: .infinity)
            } else {
                LocalEstimateView(tokenSummary: card.tokenSummary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            StatusLine(
                text: card.status.shortText(now: now), level: card.status.level, ink: ink,
                lineLimit: 1)
            if !card.isDimmed {
                ResetCountdown(resetsAt: card.resetsAt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumProviderView: View {
    let card: WidgetProviderCard
    let ink: WidgetInk
    let now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let cluster = card.cluster {
                HStack(alignment: .center, spacing: 8) {
                    WidgetRingCluster(cluster: cluster, ink: ink, size: 54, lineWidth: 7, gap: 2)
                        .opacity(card.isDimmed ? 0.45 : 1)
                    legend(cluster)
                }
            } else {
                LocalEstimateView(tokenSummary: card.tokenSummary)
            }
            Spacer(minLength: 0)
            StatusLine(
                text: card.status.longText(now: now), level: card.status.level, ink: ink,
                lineLimit: 2)
            if !card.isDimmed {
                ResetCountdown(resetsAt: card.resetsAt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One row per ring (the overflow windows have no ring in the widget):
    /// swatch, short label, percent, and a triangle when the window warns.
    private func legend(_ cluster: UsageRingCluster) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(cluster.arcs.enumerated()), id: \.offset) { _, arc in
                HStack(spacing: 4) {
                    Circle()
                        .fill(
                            ink.toneColor(
                                arc.tone, scheme: scheme,
                                increasedContrast: contrast == .increased)
                        )
                        .frame(width: 6, height: 6)
                        .widgetAccentable()
                    Text(arc.shortLabel)
                        .lineLimit(1)
                    Text(arc.percentText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if arc.level != .normal {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ink.levelColor(arc.level, scheme: scheme))
                    }
                }
                .font(.caption2)
                .minimumScaleFactor(0.85)
            }
        }
    }
}

/// Token totals only: no ring, because there is no percent to draw.
private struct LocalEstimateView: View {
    let tokenSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "circle.dashed")
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

private struct NotConnectedView: View {
    let reason: WidgetRingsPresentation.NotConnectedReason

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 34, weight: .light))
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
