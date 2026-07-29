import SwiftUI

/// A compact, source-ordered provider list for the New Ensemble canvas.
///
/// A provider is represented once. Its readiness and selection control share
/// the first logical line; its resolved model or model picker stays directly
/// below rather than being repeated in a detached stack later in the form.
struct EnsembleCLISelectionList<Row: View>: View {
    let options: [AgentTerminalOption]
    @ViewBuilder let row: (AgentTerminalOption) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Button(action: activate) {
                HStack(spacing: RafuMetrics.space2) {
                    FileIconView(icon: ConductorCLIIcons.icon(for: option.id), size: 18)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.displayName)
                            .font(.callout.weight(selection.isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                option.isReady ? theme.palette.textPrimary : theme.palette.textMuted
                            )
                            .lineLimit(1)
                        Text(option.isReady ? "Ready" : "Unavailable")
                            .font(.caption)
                            .foregroundStyle(
                                option.isReady ? theme.palette.textSecondary : theme.palette.warning
                            )
                    }

                    Spacer(minLength: RafuMetrics.space2)

                    Image(systemName: selection.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(
                            selection.isSelected
                                ? theme.palette.accent : theme.palette.textSecondary
                        )
                        .accessibilityHidden(true)
                }
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
                    .accessibilityLabel("Unavailable: \(unavailableReason)")
            } else {
                HStack(alignment: .top, spacing: RafuMetrics.space2) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(width: 42, alignment: .leading)
                    modelContent()
                }
            }
        }
        .padding(RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseSelection, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseSelection, style: .continuous)
                .strokeBorder(
                    selection.isSelected ? theme.palette.accent : theme.palette.borderSubtle,
                    lineWidth: selection.isSelected ? 2 : RafuMetrics.hairline
                )
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(selection.accessibilityRole)
    }

    private var rowFill: Color {
        if selection.isSelected { return theme.palette.accentSoft }
        if isHovering && option.isReady { return theme.palette.hover }
        return theme.palette.cardBackground
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
