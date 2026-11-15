import RafuWidgetShared
import SwiftUI
import WidgetKit

/// SPIKE: a minimal "Rings" widget. Small shows one agent, medium shows two.
/// Hierarchy comes from opacity and line width as well as hue, so accented
/// and vibrant rendering stay readable.
struct UsageRingsView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let _ = widgetLog.notice(
            "render family=\(String(describing: family), privacy: .public) mode=\(String(describing: renderingMode), privacy: .public)"
        )
        Group {
            if let snapshot = entry.snapshot, !snapshot.providers.isEmpty {
                content(snapshot)
            } else {
                notConnected
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetUsageSnapshot) -> some View {
        let remaining = snapshot.displayMode == "remaining"
        let stale = entry.date.timeIntervalSince(snapshot.writtenAt) > 20 * 60
        switch family {
        case .systemSmall:
            ProviderRingsColumn(
                provider: snapshot.providers[0], remaining: remaining, stale: stale,
                showsLegend: false)
        default:
            HStack(spacing: 16) {
                ForEach(snapshot.providers.prefix(2)) { provider in
                    ProviderRingsColumn(
                        provider: provider, remaining: remaining, stale: stale, showsLegend: true)
                }
            }
        }
    }

    private var notConnected: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Not connected")
                .font(.caption.weight(.semibold))
            Text("Open Rafu")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderRingsColumn: View {
    let provider: WidgetUsageSnapshot.Provider
    let remaining: Bool
    let stale: Bool
    let showsLegend: Bool

    private var windows: [WidgetUsageSnapshot.Window] { Array(provider.windows.prefix(3)) }

    private func shown(_ window: WidgetUsageSnapshot.Window) -> Double {
        let used = min(max(window.usedPercent, 0), 100)
        return remaining ? 100 - used : used
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                Text(provider.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                ZStack {
                    ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                        RingArc(
                            fraction: shown(window) / 100, index: index)
                    }
                    if let first = windows.first {
                        Text("\(Int(shown(first).rounded()))%")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .frame(width: 84, height: 84)
                .opacity(stale ? 0.45 : 1)
                footer
            }
            if showsLegend {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(RingArc.tint(index))
                                .opacity(RingArc.opacity(index))
                                .frame(width: 6, height: 6)
                                .widgetAccentable()
                            Text("\(window.label) \(Int(shown(window).rounded()))%")
                                .font(.caption2)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySentence)
    }

    @ViewBuilder
    private var footer: some View {
        if stale {
            Label("Stale", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let reset = windows.first?.resetsAt, reset > .now {
            HStack(spacing: 2) {
                Image(systemName: "arrow.clockwise")
                Text(reset, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var accessibilitySentence: String {
        let parts = windows.map { window in
            "\(window.label) limit \(Int(shown(window).rounded())) percent \(remaining ? "remaining" : "used")"
        }
        return ([provider.displayName] + parts).joined(separator: ", ")
    }
}

private struct RingArc: View {
    let fraction: Double
    let index: Int

    static func tint(_ index: Int) -> Color {
        [Color.indigo, Color.teal, Color.green][min(index, 2)]
    }

    static func opacity(_ index: Int) -> Double {
        [1.0, 0.75, 0.55][min(index, 2)]
    }

    var body: some View {
        let inset = CGFloat(index) * 11
        let width: CGFloat = 8
        ZStack {
            Circle()
                .stroke(Self.tint(index).opacity(0.18), lineWidth: width)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    Self.tint(index).opacity(Self.opacity(index)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(inset + width / 2)
    }
}
