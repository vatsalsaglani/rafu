import SwiftUI

nonisolated enum TerminalShellPickerCommand: Equatable, Sendable {
    case previous
    case next
    case first
    case last
    case activate
    case cancel
}

nonisolated enum TerminalShellPickerEffect: Equatable, Sendable {
    case none
    case select(TerminalShell)
    case cancel
}

/// Pure focus and activation state for the shell picker. Opening and moving
/// focus can only return `.none`; a caller receives a shell only from the
/// explicit activation command.
nonisolated struct TerminalShellPickerState: Equatable, Sendable {
    let shells: [TerminalShell]
    private(set) var focusedShellID: TerminalShell.ID?

    init(shells: [TerminalShell]) {
        self.shells = shells
        focusedShellID = shells.first(where: \.isDefault)?.id ?? shells.first?.id
    }

    mutating func focus(_ shellID: TerminalShell.ID?) {
        guard let shellID, shells.contains(where: { $0.id == shellID }) else { return }
        focusedShellID = shellID
    }

    mutating func handle(_ command: TerminalShellPickerCommand) -> TerminalShellPickerEffect {
        switch command {
        case .previous:
            moveFocus(by: -1)
            return .none
        case .next:
            moveFocus(by: 1)
            return .none
        case .first:
            focusedShellID = shells.first?.id
            return .none
        case .last:
            focusedShellID = shells.last?.id
            return .none
        case .activate:
            guard let focusedShellID,
                let shell = shells.first(where: { $0.id == focusedShellID })
            else { return .none }
            return .select(shell)
        case .cancel:
            return .cancel
        }
    }

    private mutating func moveFocus(by delta: Int) {
        guard !shells.isEmpty else { return }
        let currentIndex =
            focusedShellID.flatMap { id in
                shells.firstIndex(where: { $0.id == id })
            } ?? 0
        let nextIndex = min(
            max(currentIndex + delta, shells.startIndex),
            shells.index(before: shells.endIndex)
        )
        focusedShellID = shells[nextIndex].id
    }
}

nonisolated enum TerminalShellPickerGeometry {
    static let minimumWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 520
    static let minimumHeight: CGFloat = 112
    static let maximumHeight: CGFloat = 420
    static let baseRowHeight: CGFloat = 44

    static func width(for scaledWidth: CGFloat) -> CGFloat {
        min(max(scaledWidth, minimumWidth), maximumWidth)
    }

    static func height(shellCount: Int, rowHeight: CGFloat) -> CGFloat {
        let headerAndInsets: CGFloat = 52
        let contentHeight = CGFloat(shellCount) * max(rowHeight, baseRowHeight) + headerAndInsets
        return min(max(contentHeight, minimumHeight), maximumHeight)
    }
}

nonisolated enum TerminalShellPickerAccessibility {
    static func label(for shell: TerminalShell, index: Int, count: Int) -> String {
        var parts = [shell.name, shell.path]
        if shell.isDefault { parts.append("Default shell") }
        parts.append("\(index + 1) of \(count)")
        return parts.joined(separator: ", ")
    }
}

/// Value-driven shell selection popover. It reads no catalog and owns no
/// process or session authority; only an explicit row activation returns one
/// of the exact input values to `onSelect`.
struct TerminalShellPickerView: View {
    let shells: [TerminalShell]
    let onSelect: (TerminalShell) -> Void
    let onCancel: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var pickerState: TerminalShellPickerState
    @State private var hoveredShellID: TerminalShell.ID?
    @FocusState private var focusedShellID: TerminalShell.ID?
    @ScaledMetric(relativeTo: .body) private var scaledWidth: CGFloat = 360
    @ScaledMetric(relativeTo: .body) private var scaledRowHeight: CGFloat = 44

    init(
        shells: [TerminalShell],
        onSelect: @escaping (TerminalShell) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.shells = shells
        self.onSelect = onSelect
        self.onCancel = onCancel
        _pickerState = State(initialValue: TerminalShellPickerState(shells: shells))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose Shell")
                .font(.callout.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, RafuMetrics.space3)
                .frame(minHeight: 36)
                .accessibilityAddTraits(.isHeader)
            Divider().overlay(theme.palette.borderSubtle)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: RafuMetrics.space1) {
                        ForEach(Array(shells.enumerated()), id: \.element.path) { index, shell in
                            shellRow(shell, index: index)
                                .id(shell.path)
                        }
                    }
                    .padding(RafuMetrics.space2)
                }
                .onChange(of: focusedShellID) { _, shellID in
                    pickerState.focus(shellID)
                    guard let shellID else { return }
                    proxy.scrollTo(shellID, anchor: nil)
                }
            }
        }
        .frame(width: TerminalShellPickerGeometry.width(for: scaledWidth))
        .frame(
            height: TerminalShellPickerGeometry.height(
                shellCount: shells.count,
                rowHeight: scaledRowHeight
            )
        )
        .background(theme.palette.cardBackground)
        .overlay {
            RoundedRectangle(
                cornerRadius: RafuMetrics.radiusTransientPopover,
                style: .continuous
            )
            .strokeBorder(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .focusSection()
        .defaultFocus($focusedShellID, pickerState.focusedShellID)
        .onKeyPress(.downArrow) { handle(.next) }
        .onKeyPress(.upArrow) { handle(.previous) }
        .onKeyPress(.home) { handle(.first) }
        .onKeyPress(.end) { handle(.last) }
        .onKeyPress(.escape) { handle(.cancel) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Available terminal shells")
    }

    private func shellRow(_ shell: TerminalShell, index: Int) -> some View {
        let isFocused = focusedShellID == shell.id
        let isHovered = hoveredShellID == shell.id
        return Button {
            onSelect(shell)
        } label: {
            HStack(alignment: .center, spacing: RafuMetrics.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shell.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: shell.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: RafuMetrics.space2)
                if shell.isDefault {
                    RafuChip(text: "Default")
                }
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, RafuMetrics.space1)
            .frame(
                maxWidth: .infinity,
                minHeight: max(scaledRowHeight, TerminalShellPickerGeometry.baseRowHeight),
                alignment: .leading
            )
            .background {
                RoundedRectangle(
                    cornerRadius: RafuMetrics.radiusDenseSelection,
                    style: .continuous
                )
                .fill(
                    isFocused
                        ? theme.palette.selection
                        : (isHovered ? theme.palette.hover : Color.clear)
                )
            }
            .contentShape(.rect)
        }
        .buttonStyle(TerminalShellPickerRowButtonStyle())
        .focused($focusedShellID, equals: shell.id)
        .onHover { hovering in hoveredShellID = hovering ? shell.id : nil }
        .onKeyPress(.return) {
            onSelect(shell)
            return .handled
        }
        .help(shell.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            TerminalShellPickerAccessibility.label(
                for: shell,
                index: index,
                count: shells.count
            )
        )
        .accessibilityHint("Open a new terminal with this shell")
    }

    private func handle(_ command: TerminalShellPickerCommand) -> KeyPress.Result {
        let effect = pickerState.handle(command)
        focusedShellID = pickerState.focusedShellID
        switch effect {
        case .none:
            break
        case .select(let shell):
            onSelect(shell)
        case .cancel:
            onCancel()
        }
        return .handled
    }
}

private struct TerminalShellPickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
