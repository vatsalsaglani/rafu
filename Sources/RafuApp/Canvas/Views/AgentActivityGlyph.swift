import SwiftUI

/// The colour for one `AgentCardStatus`, shared by the glyph and the pill so
/// they can never disagree (review: "never communicate Git or connection
/// state using colour alone" — the word and the glyph shape carry the
/// meaning; colour is secondary here too).
nonisolated enum AgentCardStatusTint {
    static func color(for status: AgentCardStatus, palette: RafuThemePalette) -> Color {
        switch status {
        case .working, .done: palette.textSecondary
        case .needsYou: palette.warning
        case .failed: palette.error
        case .doneUnread: palette.success
        case .inactive, .stopped: palette.textMuted
        }
    }
}

/// The small glyph beside an agent card's status word: a spinning 3/4 arc
/// while working, else the status's SF Symbol. Decorative — the card's own
/// accessibility value already speaks the status — so this is always
/// `accessibilityHidden`.
struct AgentActivityGlyph: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    let status: AgentCardStatus
    /// Whether a `.working` glyph spins. Pass `false` for a dense row that
    /// must stay still; Reduce Motion, a hidden window and a locked screen
    /// stop the spin regardless.
    var animates = true
    /// The glyph's size in the view's own units: 9 in a header, larger on a
    /// zoomed-out face so it stays 9 screen points there too.
    var size: Double = 9
    @State private var isSpinning = false

    /// Whether a `.working` arc spins. Pure, so the gate is testable.
    nonisolated static func spins(animates: Bool, reduceMotion: Bool, motionAllowed: Bool)
        -> Bool
    {
        animates && !reduceMotion && motionAllowed
    }

    private var spins: Bool {
        Self.spins(animates: animates, reduceMotion: reduceMotion, motionAllowed: motionAllowed)
    }

    var body: some View {
        Group {
            if status == .working {
                arc
            } else if let symbol = status.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }

    /// When it does not spin, the arc stays static at its resting 3/4 sweep,
    /// as `AICommitGeneratingBorder` does for its rotating border. A spin
    /// that stops is replaced by a non-animated write, which ends the
    /// `repeatForever` animation.
    private var arc: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: 1.4 * size / 9, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear { setSpinning(spins) }
            .onChange(of: spins) { _, spins in setSpinning(spins) }
            .onDisappear { setSpinning(false) }
    }

    private func setSpinning(_ spinning: Bool) {
        if spinning {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isSpinning = false }
        }
    }

    private var color: Color { AgentCardStatusTint.color(for: status, palette: theme.palette) }
}

/// The header pill a terminal card with a matched agent status shows in
/// place of the plain state text: glyph, word, and an optional relative-time
/// suffix.
struct AgentStatusPill: View {
    @Environment(\.rafuTheme) private var theme
    let status: AgentCardStatus
    /// `nil` hides the suffix: `.stopped` and `.needsYou` are not
    /// time-relevant, and the card drops it first on a narrow header
    /// (`CanvasCardShell.minimumAgentElapsedWidth`) before truncating the
    /// title.
    var elapsed: String?
    /// The word's size in the view's own units. A zoomed-out card face passes
    /// `CanvasCompactFaceMetrics.pillFont` so the pill stays 11 screen points.
    var fontSize: Double = 11

    var body: some View {
        let unit = fontSize / 11
        HStack(spacing: 4 * unit) {
            AgentActivityGlyph(status: status, size: 9 * unit)
            Text(status.word)
                .fontWeight(status.readsTitleBold ? .semibold : .regular)
            if let elapsed {
                Text(elapsed).foregroundStyle(theme.palette.textMuted)
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(theme.palette.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, 7 * unit)
        .padding(.vertical, 2 * unit)
        .background(Capsule().fill(background))
        .fixedSize()
        .layoutPriority(-1)
        .accessibilityHidden(true)
    }

    private var background: Color {
        switch status {
        case .needsYou: theme.palette.warning.opacity(0.18)
        case .failed: theme.palette.error.opacity(0.18)
        default: theme.palette.chipBackground
        }
    }
}

/// The status dot on a silhouette card face: the status colour inside a
/// ring of the card's own surface, so it reads on any face. Decorative and
/// not interactive — the card's accessibility value speaks the status, and
/// the silhouette keeps its full-rect gesture.
struct AgentStatusDot: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let status: AgentCardStatus
    /// The diameter in the view's own units.
    let size: Double

    var body: some View {
        let ring = contrast == .increased ? 1.5 : 1.0
        Circle()
            .fill(AgentCardStatusTint.color(for: status, palette: theme.palette))
            .frame(width: size, height: size)
            .padding(ring * size / CanvasCompactFaceMetrics.statusDot)
            .background(
                Circle().fill(
                    contrast == .increased
                        ? theme.palette.borderStrong : theme.palette.elevatedBackground)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
