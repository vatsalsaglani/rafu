import SwiftUI

/// An Activity-style concentric ring cluster: each ring keeps its OWN hue
/// for both its tinted track and its determinate, round-capped arc,
/// outermost first — the drawing primitive `UsageRingClusterView` composes
/// with a centre label and a legend. This file owns geometry and drawing
/// only; it knows nothing about usage, providers, or panes.
struct RafuProgressRing: View {
    /// One ring's fill and colour. `fraction == nil` draws the track with
    /// no arc at all — never a fabricated zero-length or full arc. `color`
    /// is a STABLE per-ring hue (never recoloured by a warning level — see
    /// `UsageCardInk.color(for:)`); the track reuses it at low opacity
    /// instead of a flat grey, matching Activity's tinted rings.
    struct Arc: Equatable {
        /// `0...1`, already clamped by the caller.
        let fraction: Double?
        let color: Color
    }

    /// Outermost first.
    let arcs: [Arc]
    let size: CGFloat
    let lineWidth: CGFloat
    let gap: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(arcs: [Arc], size: CGFloat, lineWidth: CGFloat, gap: CGFloat) {
        self.arcs = arcs
        self.size = size
        self.lineWidth = lineWidth
        self.gap = gap
    }

    /// The track's opacity over its own arc's hue — Increase Contrast
    /// widens it so the unfilled portion stays legible against the
    /// surface, never a flat, level-blind grey.
    private var trackOpacity: Double { contrast == .increased ? 0.35 : 0.22 }

    var body: some View {
        let diameters = Self.diameters(
            count: arcs.count, size: size, lineWidth: lineWidth, gap: gap)
        ZStack {
            ForEach(Array(arcs.enumerated()), id: \.offset) { index, arc in
                if let diameter = diameters[index] {
                    ring(arc, diameter: diameter)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ring(_ arc: Arc, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(arc.color.opacity(trackOpacity), lineWidth: lineWidth)
            if let fraction = arc.fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Ring `i`'s diameter (outermost first): `size - 2*i*(lineWidth +
    /// gap)`. `nil` once a ring would be too small to hold its own round
    /// cap (`diameter < lineWidth * 2`), so a crowded cluster quietly stops
    /// drawing inner rings instead of overlapping them into a smear. A
    /// pure, static helper so the skip rule is unit-testable with no view
    /// host.
    nonisolated static func diameters(
        count: Int, size: CGFloat, lineWidth: CGFloat, gap: CGFloat
    ) -> [CGFloat?] {
        (0..<max(0, count)).map { index in
            let diameter = size - 2 * CGFloat(index) * (lineWidth + gap)
            return diameter >= lineWidth * 2 ? diameter : nil
        }
    }
}
