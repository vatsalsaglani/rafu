import AppKit
import SwiftUI

// Rafu popup language (ADR 0033). One quiet surface for every Rafu-drawn
// popup: Open Ensemble, the Icon Library, the Add palette, the Ensemble
// dialogs and confirmations, every alert and confirmation in the workbench,
// and the Command Palette container. Only the open and save panels stay
// native (`RafuPopupPresenter` keeps one no-window fallback alert).
//
// Tokens only: `cardBackground`, `borderStrong`, `selection`, `hover`,
// `textPrimary`/`textSecondary`/`textMuted`, `error`. No blur, so Reduce
// Transparency changes nothing. No shadow: the workbench keeps its two
// shadows (`RafuWorkbenchStyleContractTests`).

/// Where a popup surface sits. A floating surface (Command Palette, the
/// Icon Library panel) draws its own rounded card and hairline. A sheet
/// surface only fills the system sheet, which already has its own corners.
enum RafuPopupPlacement {
    case floating
    case sheet
}

/// The popup container: `cardBackground`, `radiusPanel` (12, continuous)
/// and a 1 pt `borderStrong` hairline at 0.5 (full under Increase Contrast).
struct RafuPopupSurface: ViewModifier {
    var placement: RafuPopupPlacement = .floating
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        switch placement {
        case .floating:
            content
                .background(theme.palette.cardBackground)
                .clipShape(.rect(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                        .strokeBorder(
                            theme.palette.borderStrong.opacity(
                                RafuPopupStyle.borderOpacity(
                                    increaseContrast: contrast == .increased)
                            ),
                            lineWidth: 1)
                )
                .accessibilityElement(children: .contain)
        case .sheet:
            content
                .background(theme.palette.cardBackground)
                .accessibilityElement(children: .contain)
        }
    }
}

/// Pure values of the popup language, so tests can pin them.
nonisolated enum RafuPopupStyle {
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 36

    static func borderOpacity(increaseContrast: Bool) -> Double {
        increaseContrast ? 1 : 0.5
    }

    /// The entry animation: a critically damped spring (scale 0.98 → 1 plus
    /// a fade), or only the fade under Reduce Motion.
    static let entrySpring: Animation = .spring(response: 0.25, dampingFraction: 1)
    static let entryScale: CGFloat = 0.98
}

extension View {
    /// Applies the popup container (see `RafuPopupSurface`).
    func rafuPopupSurface(_ placement: RafuPopupPlacement = .floating) -> some View {
        modifier(RafuPopupSurface(placement: placement))
    }

    /// Scale 0.98 → 1 plus a fade on first appearance; only the fade under
    /// Reduce Motion. Use on floating popups; system sheets animate
    /// themselves.
    func rafuPopupEntrance() -> some View {
        modifier(RafuPopupEntrance())
    }
}

private struct RafuPopupEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown || reduceMotion ? 1 : RafuPopupStyle.entryScale)
            .onAppear {
                withAnimation(
                    RafuMotion.resolve(
                        RafuPopupStyle.entrySpring, reduceMotion: reduceMotion,
                        reduced: RafuMotion.reducedFade)
                ) { isShown = true }
            }
    }
}

/// A key-cap hint: "esc", "⌘F", "N". Hidden from VoiceOver; put the same
/// shortcut in the control's `accessibilityHint` instead.
struct RafuKeyHint: View {
    let text: String
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String) { self.text = text }

    init(_ shortcut: KeyboardShortcut) { self.text = Self.text(for: shortcut) }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(
                contrast == .increased ? theme.palette.textSecondary : theme.palette.textMuted
            )
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.palette.chipBackground)
            )
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// The macOS order: ⌃ ⌥ ⇧ ⌘, then the key in upper case
    /// (`KeyboardShortcut("k", modifiers: [.command, .shift])` → "⇧⌘K").
    nonisolated static func text(for shortcut: KeyboardShortcut) -> String {
        var result = ""
        if shortcut.modifiers.contains(.control) { result += "⌃" }
        if shortcut.modifiers.contains(.option) { result += "⌥" }
        if shortcut.modifiers.contains(.shift) { result += "⇧" }
        if shortcut.modifiers.contains(.command) { result += "⌘" }
        return result + keyText(shortcut.key)
    }

    nonisolated static func keyText(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: "↩"
        case .escape: "esc"
        case .delete: "⌫"
        case .deleteForward: "⌦"
        case .tab: "⇥"
        case .space: "Space"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        default: String(key.character).uppercased()
        }
    }
}

/// The popup title row: leading SF Symbol, 15 pt semibold title, optional
/// 12 pt subtitle, an optional trailing accessory, and the `esc` hint.
struct RafuPopupHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var showsEscapeHint = true
    @ViewBuilder var accessory: Accessory
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            accessory
            if showsEscapeHint { RafuKeyHint("esc") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: RafuPopupStyle.headerHeight)
        .overlay(alignment: .bottom) { RafuPopupDivider() }
    }
}

extension RafuPopupHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil, showsEscapeHint: Bool = true) {
        self.init(
            symbol: symbol, title: title, subtitle: subtitle, showsEscapeHint: showsEscapeHint
        ) { EmptyView() }
    }
}

/// The 1 pt hairline between popup sections.
struct RafuPopupDivider: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(contrast == .increased ? theme.palette.borderStrong : theme.palette.borderSubtle)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A search row: magnifying glass, a plain field on `fieldBackground` with a
/// focus ring, and an optional trailing key hint.
struct RafuPopupSearchField: View {
    let prompt: String
    @Binding var text: String
    var hint: String?
    /// The caller's focus state, so the popup can focus the field on open
    /// and the ring follows it.
    var focus: FocusState<Bool>.Binding
    @Environment(\.rafuTheme) private var theme

    private var isFocused: Bool { focus.wrappedValue }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus)
                // The overlay below is the one focus indication, in the theme's
                // focus colour; the system ring would draw a second, blue one.
                .focusEffectDisabled()
                .accessibilityLabel(prompt)
            if let hint { RafuKeyHint(hint) }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                .fill(theme.palette.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                .strokeBorder(
                    isFocused ? theme.palette.focusRing : theme.palette.borderSubtle,
                    lineWidth: isFocused ? 2 : 1)
        )
    }
}

/// One 32 pt popup row: a 16 pt icon slot, a 13 pt title, an optional 11 pt
/// caption, and an optional trailing text or key hint. Hover uses `hover`;
/// the selected row uses `selection` plus a hairline, and adds the
/// `.isSelected` trait, so selection never relies on colour alone.
struct RafuPopupRow: View {
    let symbol: String
    let title: String
    var caption: String?
    var trailing: String?
    var keyHint: String?
    let isSelected: Bool
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(
                    isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
            }
            if let keyHint { RafuKeyHint(keyHint) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: RafuPopupStyle.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .strokeBorder(isSelected ? selectedBorder : .clear, lineWidth: 1)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(Self.accessibilityTraits(isSelected: isSelected))
    }

    private var fill: Color {
        if isSelected { return theme.palette.selection }
        return isHovering ? theme.palette.hover : .clear
    }

    private var selectedBorder: Color {
        contrast == .increased ? theme.palette.borderStrong : theme.palette.borderSubtle
    }

    nonisolated static func accessibilityTraits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : [.isButton]
    }
}

/// The bottom row: key hints on the left (hidden from VoiceOver), buttons on
/// the right.
struct RafuPopupFooter<Buttons: View>: View {
    var hints: [(key: String, label: String)] = []
    @ViewBuilder var buttons: Buttons
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(hints, id: \.key) { hint in
                    HStack(spacing: 4) {
                        RafuKeyHint(hint.key)
                        Text(hint.label)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: RafuPopupStyle.footerHeight)
        .overlay(alignment: .top) { RafuPopupDivider() }
    }
}

/// A centred empty state: a 22 pt symbol, one line, an optional action. It
/// fills the space it is given, so a short popup never floats its header
/// (AGENTS.md top-pinning rule).
struct RafuEmptyState: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A confirmation: title, one sentence, the actions, and Cancel.
///
/// Return never destroys: a destructive action is never the default. Cancel
/// is the default unless the caller names a non-destructive default action.
/// Escape always cancels.
struct RafuConfirmPopup: View {
    struct Action: Identifiable {
        let id: String
        let title: String
        var isDestructive = false
        let perform: () -> Void

        init(_ title: String, isDestructive: Bool = false, perform: @escaping () -> Void) {
            self.id = title
            self.title = title
            self.isDestructive = isDestructive
            self.perform = perform
        }
    }

    var symbol = "exclamationmark.triangle"
    let title: String
    let message: String
    let actions: [Action]
    /// A non-destructive action that Return runs. Ignored for a destructive
    /// action: then Cancel stays the default.
    var defaultActionID: String?
    var placement: RafuPopupPlacement = .sheet
    let cancel: () -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let defaultIndex = Self.defaultActionIndex(actions, preferred: defaultActionID)
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(symbol: symbol, title: title)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            let order = Self.footerOrder(actions)
            let defaultID = defaultIndex.map { actions[$0].id }
            RafuPopupFooter(hints: [("esc", "Cancel")]) {
                ForEach(order.leading) { action in
                    actionButton(action, isDefault: false)
                }
                cancelButton(isDefault: defaultIndex == nil)
                ForEach(order.trailing) { action in
                    actionButton(action, isDefault: action.id == defaultID)
                }
            }
        }
        .frame(width: 420, alignment: .top)
        .rafuPopupSurface(placement)
        .onExitCommand(perform: cancel)
    }

    @ViewBuilder
    private func cancelButton(isDefault: Bool) -> some View {
        let button = Button("Cancel", action: cancel)
            .buttonStyle(RafuSecondaryButtonStyle())
            .accessibilityHint("Closes without changes")
        if isDefault {
            button.keyboardShortcut(.defaultAction)
        } else {
            button.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Action, isDefault: Bool) -> some View {
        if action.isDestructive {
            Button(action.title, role: .destructive, action: action.perform)
                .buttonStyle(RafuDestructiveButtonStyle())
        } else if isDefault {
            Button(action.title, action: action.perform)
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
        } else {
            Button(action.title, action: action.perform)
                .buttonStyle(RafuSecondaryButtonStyle())
        }
    }

    /// The index of the action Return runs, or nil for Cancel. A destructive
    /// action is never the default.
    static func defaultActionIndex(_ actions: [Action], preferred: String?) -> Int? {
        guard let preferred, let index = actions.firstIndex(where: { $0.id == preferred }),
            !actions[index].isDestructive
        else { return nil }
        return index
    }

    /// The footer layout, left to right: destructive actions, Cancel, then
    /// the other actions. This is the macOS save-sheet order (Discard |
    /// Cancel | Save): the default action sits at the far right, away from
    /// the destructive one. Each group keeps the caller's order.
    static func footerOrder(_ actions: [Action]) -> (leading: [Action], trailing: [Action]) {
        (actions.filter(\.isDestructive), actions.filter { !$0.isDestructive })
    }
}

/// A bordered button in the theme's `error` colour, for a destructive action.
/// Colour is never the only signal: the title names the action.
struct RafuDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.rafuTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.palette.error)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering || configuration.isPressed ? theme.palette.hover : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.palette.error.opacity(0.6), lineWidth: 1)
                )
                .contentShape(.rect)
                .onHover { isHovering = $0 }
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// An error or information message: title, the message text, and one OK
/// button. Return and Escape both close it.
struct RafuMessagePopup: View {
    enum Kind {
        case error
        case info
    }

    var kind: Kind = .error
    let title: String
    let message: String
    var okTitle = "OK"
    var placement: RafuPopupPlacement = .sheet
    let dismiss: () -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(symbol: Self.symbol(for: kind), title: title)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
            RafuPopupFooter(hints: [("↩", okTitle)]) {
                // Escape closes too. The zero-size button gives the sheet a
                // cancel action without a second visible button.
                Button("Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                Button(okTitle, action: dismiss)
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 420, alignment: .top)
        .rafuPopupSurface(placement)
        .onExitCommand(perform: dismiss)
    }

    static func symbol(for kind: Kind) -> String {
        switch kind {
        case .error: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }
}

/// A popup with one text field: Rename, Create Branch, Duplicate Theme,
/// Edit Label. Return submits; Escape cancels. The action stays disabled
/// while the trimmed text is empty or `validate` returns a message.
struct RafuTextFieldPopup: View {
    var symbol = "pencil"
    let title: String
    var subtitle: String?
    let fieldLabel: String
    var initialText = ""
    let actionTitle: String
    /// An error message for text that is not acceptable, or nil. Receives
    /// the trimmed text.
    var validate: (String) -> String? = { _ in nil }
    var isBusy = false
    /// A failure from the caller's own work (for example a file error after
    /// submit). Shown under the field in place of a second popup.
    var errorMessage: String?
    var width: CGFloat = 420
    let cancel: () -> Void
    let submit: (String) -> Void
    @Environment(\.rafuTheme) private var theme
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let problem = Self.problem(text, validate: validate) ?? errorMessage
        let canSubmit = Self.canSubmit(text, validate: validate) && !isBusy
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(symbol: symbol, title: title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: 10) {
                TextField(fieldLabel, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .rafuField(isFocused: fieldFocused)
                    .accessibilityLabel(fieldLabel)
                    .onSubmit { if canSubmit { submit(text) } }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(theme.palette.error)
                }
            }
            .padding(16)
            RafuPopupFooter(hints: [("↩", actionTitle), ("esc", "Cancel")]) {
                Button("Cancel", action: cancel)
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { submit(text) }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .frame(width: width, alignment: .top)
        .rafuPopupSurface(.sheet)
        .onExitCommand(perform: cancel)
        .task {
            text = initialText
            fieldFocused = true
        }
    }

    /// True when the trimmed text is not empty and `validate` accepts it.
    nonisolated static func canSubmit(_ text: String, validate: (String) -> String?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && validate(trimmed) == nil
    }

    /// The validation message to show, if the text is not empty.
    nonisolated static func problem(_ text: String, validate: (String) -> String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : validate(trimmed)
    }
}
