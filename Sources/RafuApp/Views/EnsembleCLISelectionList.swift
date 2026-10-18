import SwiftUI

/// A compact, source-ordered provider list for the New Ensemble canvas.
///
/// A provider is represented once, on a ~32 pt line that holds its selection
/// control, name, and readiness. Its model picker appears directly below the
/// row only while that row is chosen, so an unchosen CLI costs one line.
struct EnsembleCLISelectionList<Row: View>: View {
    let options: [AgentTerminalOption]
    @ViewBuilder let row: (AgentTerminalOption) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options) { option in
                row(option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One CLI and its one model relationship. The lead list uses radio semantics
/// while the allowed list uses checkbox semantics; each group labels that
/// distinction before VoiceOver reaches its rows.
struct EnsembleCLISelectionRow<ModelContent: View>: View {
    enum Selection {
        case lead(isSelected: Bool)
        case allowed(isSelected: Bool)

        var isSelected: Bool {
            switch self {
            case .lead(let isSelected), .allowed(let isSelected): isSelected
            }
        }

        var symbolName: String {
            switch self {
            case .lead(let isSelected):
                isSelected ? "largecircle.fill.circle" : "circle"
            case .allowed(let isSelected):
                isSelected ? "checkmark.square.fill" : "square"
            }
        }

        var accessibilityRole: String {
            switch self {
            case .lead: "Lead coordinator radio button"
            case .allowed: "Allowed CLI checkbox"
            }
        }

        var actionDescription: String {
            switch self {
            case .lead: "Use as the lead coordinator"
            case .allowed: "Allow the coordinator to reach this CLI"
            }
        }
    }

    let option: AgentTerminalOption
    let selection: Selection
    let unavailableReason: String?
    let activate: () -> Void
    @ViewBuilder let modelContent: () -> ModelContent

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    init(
        option: AgentTerminalOption,
        selection: Selection,
        unavailableReason: String?,
        activate: @escaping () -> Void,
        @ViewBuilder modelContent: @escaping () -> ModelContent
    ) {
        self.option = option
        self.selection = selection
        self.unavailableReason = unavailableReason
        self.activate = activate
        self.modelContent = modelContent
    }

    /// Height of the one-line row; the model picker is extra, below it.
    static var rowHeight: CGFloat { 32 }
    /// The model line aligns under the name: control column + icon column.
    private static var modelLeadingInset: CGFloat { 15 + 20 + 2 * RafuMetrics.space2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: activate) {
                HStack(spacing: RafuMetrics.space2) {
                    Image(systemName: selection.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(
                            selection.isSelected
                                ? theme.palette.accent : theme.palette.textSecondary
                        )
                        .frame(width: 15)
                        .accessibilityHidden(true)

                    FileIconView(icon: ConductorCLIIcons.icon(for: option.id), size: 16)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)

                    Text(option.displayName)
                        .font(.callout.weight(selection.isSelected ? .semibold : .regular))
                        .foregroundStyle(
                            option.isReady ? theme.palette.textPrimary : theme.palette.textMuted
                        )
                        .lineLimit(1)

                    Spacer(minLength: RafuMetrics.space2)

                    Text(option.isReady ? "Ready" : "Unavailable")
                        .font(.caption)
                        .foregroundStyle(
                            option.isReady ? theme.palette.textSecondary : theme.palette.warning
                        )
                        .lineLimit(1)
                }
                .frame(minHeight: Self.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!option.isReady)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(selection.isSelected ? "Selected" : "Not selected")
            .accessibilityHint(option.isReady ? selection.actionDescription : "Unavailable")
            .accessibilityAddTraits(selection.isSelected ? .isSelected : [])

            if let unavailableReason {
                Label("Unavailable — \(unavailableReason)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.modelLeadingInset)
                    .padding(.bottom, RafuMetrics.space2)
                    .accessibilityLabel("Unavailable: \(unavailableReason)")
            } else if selection.isSelected {
                HStack(alignment: .top, spacing: RafuMetrics.space2) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 42, alignment: .leading)
                    modelContent()
                }
                .padding(.leading, Self.modelLeadingInset)
                .padding(.bottom, RafuMetrics.space2)
            }
        }
        .padding(.horizontal, RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseSelection, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selection.accessibilityRole)
    }

    private var rowFill: Color {
        // One chosen coordinator reads as selection; a checklist of allowed
        // CLIs stays calm and only the glyph carries the accent.
        if case .lead(let isSelected) = selection, isSelected { return theme.palette.accentSoft }
        if isHovering && option.isReady { return theme.palette.hover }
        return .clear
    }

    private var accessibilityLabel: String {
        var components = [option.displayName, selection.accessibilityRole]
        if option.isReady {
            components.append("Ready")
        } else if let unavailableReason {
            components.append("Unavailable: \(unavailableReason)")
        } else {
            components.append("Unavailable")
        }
        return components.joined(separator: ", ")
    }
}
