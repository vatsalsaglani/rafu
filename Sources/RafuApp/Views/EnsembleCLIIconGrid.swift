import SwiftUI

/// The layout half of the New Ensemble canvas's two CLI pickers: a wrapping
/// grid of square icon cards rather than a column of rows or switches. Both
/// pickers show the SAME seven providers in the same order, so a single grid
/// shape keeps them visually parallel — one is "which CLI coordinates", the
/// other "which CLIs may it reach".
struct EnsembleCLIIconGrid<Card: View>: View {
    let options: [AgentTerminalOption]
    @ViewBuilder let card: (AgentTerminalOption) -> Card

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: RafuMetrics.space2)],
            alignment: .leading,
            spacing: RafuMetrics.space2
        ) {
            ForEach(options) { option in
                card(option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One provider card. Selection is stated three ways — a filled badge glyph,
/// a heavier border, and a semibold label — so it never depends on color
/// alone, and an unavailable CLI stays visible with its reason reachable
/// through both `help` (pointer) and `accessibilityLabel` (VoiceOver),
/// because a grid has no room for the reason inline the way the old row list
/// did. The reason is bounded in the layout, never dropped.
struct EnsembleCLIIconCard: View {
    /// Which of the two pickers this card belongs to, and its state there.
    /// The coordinator picker is single-select; the allowed-CLI picker is a
    /// multi-select toggle, and says so in its accessibility traits.
    enum Selection {
        case unselected
        case selected
        case allowed

        var isOn: Bool { self != .unselected }

        var badge: String {
            switch self {
            case .unselected: "circle"
            case .selected: "checkmark.circle.fill"
            case .allowed: "checkmark.circle.fill"
            }
        }
    }

    let option: AgentTerminalOption
    let selection: Selection
    let reason: String?
    /// Verb fragment for the tooltip and VoiceOver label, e.g. "Use as the
    /// coordinator". Each picker names its own action.
    let actionDescription: String
    let activate: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: activate) {
            VStack(spacing: RafuMetrics.space1) {
                ZStack(alignment: .topTrailing) {
                    FileIconView(icon: ConductorCLIIcons.icon(for: option.id), size: 24)
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                    badgeGlyph
                        .offset(x: 4, y: -2)
                }
                Text(option.displayName)
                    .font(.system(size: 10.5, weight: selection.isOn ? .semibold : .regular))
                    .foregroundStyle(
                        option.isReady ? theme.palette.textPrimary : theme.palette.textMuted
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, RafuMetrics.space1)
            .padding(.vertical, RafuMetrics.space2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        selection.isOn ? theme.palette.accent : theme.palette.borderSubtle,
                        lineWidth: selection.isOn ? 2 : RafuMetrics.hairline)
            )
            .opacity(option.isReady ? 1 : 0.55)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!option.isReady)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selection.isOn ? .isSelected : [])
    }

    /// Unavailable CLIs carry a warning glyph in the badge slot, so the grid
    /// still distinguishes "off" from "cannot be turned on" without color.
    @ViewBuilder
    private var badgeGlyph: some View {
        if !option.isReady {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.warning)
                .background(Circle().fill(theme.palette.editorBackground))
        } else {
            Image(systemName: selection.badge)
                .font(.system(size: 11))
                .foregroundStyle(
                    selection.isOn ? theme.palette.accent : theme.palette.textMuted
                )
                .background(Circle().fill(theme.palette.editorBackground))
        }
    }

    private var fill: Color {
        if selection.isOn { return theme.palette.accentSoft }
        if isHovering && option.isReady { return theme.palette.hover }
        return theme.palette.cardBackground
    }

    private var helpText: String {
        if let reason { return "\(option.displayName) — \(reason)" }
        return "\(option.displayName) — \(actionDescription)"
    }

    private var accessibilityText: String {
        if let reason { return "\(option.displayName), unavailable, \(reason)" }
        return "\(option.displayName), \(actionDescription)"
    }
}
