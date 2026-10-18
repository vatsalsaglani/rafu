import SwiftUI

/// Shared geometry for the Ensemble run forms (New Ensemble Run and the
/// Existing Workflow door of New Ensemble).
nonisolated enum ConductorFormMetrics {
    /// One label column for every row of a form, so controls line up.
    static let labelWidth: CGFloat = 128
    static let promptMinimumHeight: CGFloat = 96
    static let promptMaximumHeight: CGFloat = 168
}

/// Pure option list behind the Base reference combo box: `HEAD` first, then
/// the workspace's local branches (already loaded by the Source Control
/// model, so no Git process runs here).
nonisolated enum ConductorBaseReferenceOptions {
    static let defaultReference = "HEAD"
    /// Keeps the menu bounded in repositories with many branches.
    static let maximumBranchCount = 40

    static func options(branchNames: [String]) -> [String] {
        var seen: Set<String> = [defaultReference]
        var result = [defaultReference]
        for name in branchNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count > maximumBranchCount { break }
        }
        return result
    }
}

/// A grouped form surface on theme tokens (`cardBackground` over the editor
/// deck, `borderSubtle` hairline). It replaces the system grouped `Form`
/// card, whose neutral grey belongs to no theme.
struct ConductorFormCard<Content: View>: View {
    let title: String?
    let content: Content

    @Environment(\.rafuTheme) private var theme

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .fill(theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

/// One form row: a right-aligned label in the shared label column, then the
/// control filling the remaining width.
struct ConductorFormRow<Content: View>: View {
    let label: String
    let alignment: VerticalAlignment
    let content: Content

    @Environment(\.rafuTheme) private var theme

    init(
        _ label: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: RafuMetrics.space3) {
            Text(label)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.trailing)
                .frame(width: ConductorFormMetrics.labelWidth, alignment: .trailing)
                .padding(.top, alignment == .top ? RafuMetrics.space1 : 0)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A bordered multi-line prompt editor with a placeholder. `TextEditor` has
/// no edge or placeholder of its own, which left the prompt looking like
/// empty space.
struct ConductorPromptEditor: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textPrimary)
                .scrollContentBackground(.hidden)
                .focused(isFocused)
                .padding(.horizontal, RafuMetrics.space1)
                .padding(.vertical, RafuMetrics.space1)
                .accessibilityLabel(label)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textMuted)
                    .padding(.leading, RafuMetrics.space2 + 1)
                    .padding(.top, RafuMetrics.space1 + 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(
            minHeight: ConductorFormMetrics.promptMinimumHeight,
            maxHeight: ConductorFormMetrics.promptMaximumHeight
        )
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField, style: .continuous)
                .fill(theme.palette.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField, style: .continuous)
                .strokeBorder(
                    isFocused.wrappedValue ? theme.palette.focusRing : theme.palette.borderSubtle,
                    lineWidth: RafuMetrics.hairline
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

/// Base reference as a combo box: editable text (any branch, tag, or commit)
/// plus a menu of `HEAD` and the local branches. Tags are not offered because
/// no already-loaded service lists them; the field still accepts one.
struct ConductorBaseReferenceField: View {
    @Binding var reference: String
    let branchNames: [String]

    @Environment(\.rafuTheme) private var theme
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: RafuMetrics.space1) {
            TextField(ConductorBaseReferenceOptions.defaultReference, text: $reference)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary)
                .focused($isFieldFocused)
                .help("Branch, tag, or commit. Defaults to the current HEAD.")
                .accessibilityLabel("Base reference")
            Menu {
                ForEach(ConductorBaseReferenceOptions.options(branchNames: branchNames), id: \.self)
                { option in
                    Button(option) { reference = option }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose HEAD or a local branch")
            .accessibilityLabel("Choose base reference")
        }
        .rafuField(isFocused: isFieldFocused)
    }
}
