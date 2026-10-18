import SwiftUI

/// The colours a usage card and its rings use. Every value comes from the
/// active Rafu theme (or the notch's `NotchInk`, which derives from it), so
/// callers choose the surface and the ring never hardcodes a colour.
struct UsageCardInk {
    let primary: Color
    let secondary: Color
    let muted: Color
    /// The ring's track: the subtle border token.
    let track: Color
    /// The ring's arc at the normal level: the accent token.
    let arc: Color
    let warning: Color
    let critical: Color
    /// The card fill, or `nil` where the container already draws one (a
    /// grouped `Form` row in Settings).
    let cardBackground: Color?

    init(
        primary: Color, secondary: Color, muted: Color, track: Color, arc: Color,
        warning: Color, critical: Color, cardBackground: Color?
    ) {
        self.primary = primary
        self.secondary = secondary
        self.muted = muted
        self.track = track
        self.arc = arc
        self.warning = warning
        self.critical = critical
        self.cardBackground = cardBackground
    }

    /// The notch panel is always dark, so light themes use white ink there
    /// (`NotchInk`) and a light track instead of the light theme's border.
    static func notch(theme: RafuTheme) -> UsageCardInk {
        let ink = NotchInk(theme: theme)
        return UsageCardInk(
            primary: ink.primary, secondary: ink.secondary, muted: ink.muted,
            track: theme.isDark ? theme.palette.borderSubtle : Color.white.opacity(0.18),
            arc: ink.accent, warning: theme.palette.warning, critical: theme.palette.error,
            cardBackground: Color.white.opacity(0.05))
    }

    /// Settings uses system text styles inside the grouped form.
    static func settings(theme: RafuTheme) -> UsageCardInk {
        UsageCardInk(
            primary: Color.primary, secondary: Color.secondary, muted: Color.secondary,
            track: theme.palette.borderSubtle, arc: theme.palette.accent,
            warning: theme.palette.warning, critical: theme.palette.error,
            cardBackground: nil)
    }

    func color(for level: UsageRingLevel) -> Color {
        switch level {
        case .normal: arc
        case .warning: warning
        case .critical: critical
        }
    }
}

/// A usage ring (Cider's "pie"): a track circle, an arc trimmed to the
/// percentage, and the rounded percentage in the centre. A warning or
/// critical level changes the arc colour AND adds a glyph, so the signal
/// never depends on colour alone. Under Reduce Motion the arc does not
/// sweep; it jumps to the new value.
struct UsageRing: View {
    let percent: Double?
    let level: UsageRingLevel
    let size: CGFloat
    /// The spoken name, for example "Claude 5-hour session used".
    let label: String
    let ink: UsageCardInk
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(percent: Double?, level: UsageRingLevel, size: CGFloat, label: String, ink: UsageCardInk)
    {
        self.percent = percent
        self.level = level
        self.size = size
        self.label = label
        self.ink = ink
    }

    private var isCompact: Bool { size < 44 }
    private var lineWidth: CGFloat { isCompact ? 3.5 : 5 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(ink.track, lineWidth: lineWidth)
            if let fraction = UsageRingLevel.fraction(percent: percent) {
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(
                        ink.color(for: level),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
            }
            Text(percentText)
                .font(.system(size: isCompact ? 10 : 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(roundedPercent == nil ? ink.muted : ink.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if level != .normal {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: isCompact ? 8 : 11, weight: .bold))
                    .foregroundStyle(ink.color(for: level))
                    .offset(x: 3, y: 3)
            }
        }
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    /// The rounded percentage, clamped like the arc. `nil` for a missing or
    /// non-finite value, so `Int(_:)` can never trap.
    private var roundedPercent: Int? {
        UsageRingLevel.fraction(percent: percent).map { Int(($0 * 100).rounded()) }
    }

    private var percentText: String {
        roundedPercent.map { "\($0)%" } ?? "—"
    }

    private var accessibilityValue: String {
        guard let roundedPercent else { return "Not reported" }
        let value = "\(roundedPercent) percent"
        switch level {
        case .normal: return value
        case .warning: return value + ", warning"
        case .critical: return value + ", near or at the limit"
        }
    }
}
