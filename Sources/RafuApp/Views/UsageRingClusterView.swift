import SwiftUI

/// One provider's Activity-style ring cluster: concentric rings
/// (`RafuProgressRing`) plus a legend listing EVERY window the provider
/// reports — `UsageRingCluster.legend` already includes the windows past
/// `UsageRingCluster.maxArcs` that only ever appear as text, no ring.
/// Compact (the notch) and full (Settings) share this view; only sizing
/// and the per-row detail differ.
struct UsageRingClusterView: View {
    let cluster: UsageRingCluster
    let ink: UsageCardInk
    let compact: Bool

    private var ringSize: CGFloat { compact ? 38 : 76 }
    private var lineWidth: CGFloat { compact ? 3 : 7 }
    private var gap: CGFloat { compact ? 1.5 : 3 }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 14) {
            ring
            VStack(alignment: .leading, spacing: compact ? 2 : 6) {
                ForEach(Array(cluster.legend.enumerated()), id: \.offset) { _, arc in
                    UsageRingLegendRow(arc: arc, compact: compact, ink: ink)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cluster.accessibilityLabel)
        .help(helpText)
    }

    private var ring: some View {
        RafuProgressRing(
            arcs: cluster.arcs.map { arc in
                RafuProgressRing.Arc(
                    fraction: arc.fraction, color: ink.color(for: arc.tone, level: arc.level))
            },
            trackColor: ink.track, size: ringSize, lineWidth: lineWidth, gap: gap
        )
        .overlay {
            Text(cluster.centerText)
                .font(.system(size: compact ? 10 : 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }

    /// The accessibility label plus the leading row's pace note — the same
    /// sentence the `.help(...)` tooltip pattern uses elsewhere in this
    /// card (`UsageRingLegendRow`/`UsagePaceLine` do not carry their own
    /// `.help`, so the cluster's one tooltip covers the whole row).
    private var helpText: String {
        guard let note = cluster.legend.first?.pace.note else { return cluster.accessibilityLabel }
        return cluster.accessibilityLabel + ". " + note
    }
}

/// One legend row: a tone swatch, the short label, the percent, the reset
/// countdown, and — full only — the pace note and hourly average. A level
/// above `.normal` adds a warning triangle; the signal never depends on
/// colour alone.
private struct UsageRingLegendRow: View {
    let arc: UsageRingArc
    let compact: Bool
    let ink: UsageCardInk

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle()
                    .fill(ink.color(for: arc.tone, level: arc.level))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(arc.shortLabel)
                    .font(.system(size: compact ? 10 : 12, weight: .medium))
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                Text(arc.percentText)
                    .font(.system(size: compact ? 10 : 12, design: .monospaced))
                    .foregroundStyle(ink.secondary)
                Text(arc.resetText)
                    .font(.system(size: compact ? 9 : 11))
                    .foregroundStyle(ink.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                if arc.level != .normal {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: compact ? 8 : 10, weight: .bold))
                        .foregroundStyle(ink.color(for: arc.tone, level: arc.level))
                        .accessibilityHidden(true)
                }
            }
            if !compact {
                UsagePaceLine(
                    text: arc.pace.note, warning: arc.pace.warning, compact: false, ink: ink)
                if let hourly = arc.pace.hourlyPercent {
                    Text(UsageWindowPresentation.hourlyAverageText(hourly))
                        .font(.caption2)
                        .foregroundStyle(ink.secondary)
                }
            }
        }
    }
}
