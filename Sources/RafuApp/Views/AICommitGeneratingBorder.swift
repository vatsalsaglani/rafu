import SwiftUI

/// Animated gradient border shown around the Source Control commit composer
/// while an AI commit-message generation is in flight (issue #8). A rotating
/// `AngularGradient`, mixed from the active theme's palette, is masked to a
/// stroked rounded-rectangle border matching the composer's own corner
/// radius — the gradient's fill rotates in place, so the border's geometry
/// never exceeds the composer's bounds. Respects Reduce Motion: when
/// enabled, the border is shown as a static (non-rotating) gradient instead.
struct AICommitGeneratingBorder: ViewModifier {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool
    var cornerRadius: CGFloat = RafuMetrics.radiusPanel
    var lineWidth: CGFloat = 2

    @State private var rotationDegrees: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    AngularGradient(
                        colors: Self.gradientColors(from: theme.palette),
                        center: .center
                    )
                    .rotationEffect(.degrees(reduceMotion ? 0 : rotationDegrees))
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(lineWidth: lineWidth)
                    )
                    .accessibilityHidden(true)
                    .onAppear { startRotatingIfNeeded() }
                    .onDisappear { rotationDegrees = 0 }
                }
            }
    }

    private func startRotatingIfNeeded() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
            rotationDegrees = 360
        }
    }

    /// Mixes the theme's accent, info, and git added/modified tokens into a
    /// ring palette. Pure and independent of any live view state, so it is
    /// unit-testable without constructing a `View`.
    static func gradientColors(from palette: RafuThemePalette) -> [Color] {
        [
            palette.accent,
            palette.info,
            palette.gitAdded,
            palette.gitModified,
            palette.accent,
        ]
    }
}

extension View {
    /// Applies `AICommitGeneratingBorder` while `isActive` is true — the
    /// commit composer's "generating" affordance.
    func aiCommitGeneratingBorder(
        isActive: Bool,
        cornerRadius: CGFloat = RafuMetrics.radiusPanel
    ) -> some View {
        modifier(AICommitGeneratingBorder(isActive: isActive, cornerRadius: cornerRadius))
    }
}
