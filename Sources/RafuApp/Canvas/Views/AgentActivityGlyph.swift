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
    let status: AgentCardStatus
    /// Whether a `.working` glyph spins. Pass `false` for a dense row that
    /// must stay still; Reduce Motion stops the spin regardless.
    var animates = true
    @State private var isSpinning = false

    var body: some View {
        Group {
            if status == .working {
                arc
            } else if let symbol = status.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .accessibilityHidden(true)
    }

    /// Reduce Motion keeps the arc static at its resting 3/4 sweep, as
    /// `AICommitGeneratingBorder` does for its rotating border.
    private var arc: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear { startIfNeeded() }
            .onDisappear { isSpinning = false }
    }

    private func startIfNeeded() {
        guard animates, !reduceMotion else { return }
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            isSpinning = true
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

    var body: some View {
        HStack(spacing: 4) {
            AgentActivityGlyph(status: status)
            Text(status.word)
                .fontWeight(status.readsTitleBold ? .semibold : .regular)
            if let elapsed {
                Text(elapsed).foregroundStyle(theme.palette.textMuted)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.palette.textPrimary)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
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
