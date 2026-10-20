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

    private var ringSize: CGFloat { compact ? 56 : 92 }
    private var lineWidth: CGFloat { compact ? 7 : 11 }
    private var gap: CGFloat { compact ? 2 : 3 }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 16) {
            ring
            // One shared `Grid` so every window's percent lines up in its
            // own right-aligned column, not just within one row.
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: compact ? 3 : 5) {
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
                    fraction: arc.fraction, color: ink.color(for: arc.tone), track: ink.trackColor)
            },
            size: ringSize, lineWidth: lineWidth, gap: gap
        )
        .overlay {
            // Activity shows no centre text once rings nest; one ring still
            // gets its percent, since there is nothing else to nest it against.
            if cluster.arcs.count == 1 {
                Text(cluster.centerText)
                    .font(.system(size: compact ? 15 : 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
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

/// One legend row, inside the cluster's shared `Grid`: a swatch in its
/// ring's exact colour (hue or monochrome shade), the short label, the right-aligned percent, the reset
/// countdown, and — full only — the pace note and hourly average as
/// column-spanning rows beneath it. ONE warning signal per window: the
/// trailing triangle here is the only glyph; `UsagePaceLine` below (full)
/// and the card-level pace summary (compact, `UsageCardBody`) keep their
/// warning TEXT and tint but pass `showGlyph: false`, since
/// `UsageRingLevel.level` is `.normal` only when `pace.warning` is also
/// false — whichever window either of those lines names, this row's own
/// triangle has already shown for it.
private struct UsageRingLegendRow: View {
    let arc: UsageRingArc
    let compact: Bool
    let ink: UsageCardInk

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Circle()
                .fill(ink.color(for: arc.tone))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(arc.shortLabel)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(ink.primary)
                .lineLimit(1)
            Text(arc.percentText)
                .font(.system(size: compact ? 10 : 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(ink.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                Text(arc.resetText)
                    .font(.system(size: compact ? 9 : 11))
                    .foregroundStyle(ink.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                if arc.level != .normal {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: compact ? 8 : 10, weight: .bold))
                        .foregroundStyle(ink.warningTint(for: arc.level))
                        .accessibilityHidden(true)
                }
            }
        }
        if !compact {
            GridRow {
                UsagePaceLine(
                    text: arc.pace.note, warning: arc.pace.warning, compact: false, ink: ink,
                    showGlyph: false
                )
                .gridCellColumns(4)
            }
            if let hourly = arc.pace.hourlyPercent {
                GridRow {
                    Text(UsageWindowPresentation.hourlyAverageText(hourly))
                        .font(.caption2)
                        .foregroundStyle(ink.secondary)
                        .gridCellColumns(4)
                }
            }
        }
    }
}
