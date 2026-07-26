import SwiftUI

/// One "which model" control: a picker over what the CLI actually offers,
/// plus a way to name a model Rafu has never heard of.
///
/// Used once for the coordinator and once per allowed CLI in the New Ensemble
/// canvas, so both read and behave identically. Two properties are the point:
///
/// 1. **Free text stays possible.** `ConductorModelResolution` deliberately
///    accepts an unknown id, so a user must be able to enter one. The picker's
///    "Custom…" item reveals a field for exactly that, and a custom value that
///    is already set is listed back as a real, re-selectable row — a picker
///    that silently dropped a hand-typed value would lose the user's choice.
/// 2. **"Default" is not a claim.** Choosing "CLI default" passes no `--model`
///    flag, which is not the same as knowing what will run. When something
///    further down the chain does name a model, the caption says which and
///    where it came from, rather than leaving the picker's word as the last
///    thing the user reads.
struct EnsembleModelField: View {
    /// Prefix for the accessibility labels, e.g. "Coordinator model".
    let label: String
    /// What this CLI offers right now — curated plus anything discovered.
    let available: [ConductorModelChoice]
    /// What will actually run, from the shared resolver.
    let resolution: ConductorModelResolution
    @Binding var value: String

    @Environment(\.rafuTheme) private var theme
    @State private var isEditingCustom = false
    @State private var customDraft = ""
    @FocusState private var isCustomFieldFocused: Bool

    /// A sentinel no model id can collide with: `ConductorModelResolution`
    /// trims and empty-checks every value it is given, so a tag containing a
    /// NUL byte can never be produced by a real selection.
    private static let customTag = "\u{0}rafu.custom"
    /// The "pass no `--model` flag" selection. `""` is already the not-set
    /// value throughout the Conductor stores, so it needs no sentinel.
    private static let defaultTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Picker(label, selection: selectionBinding) {
                Text(ConductorModelResolution.unsetLabel).tag(Self.defaultTag)
                ForEach(available) { choice in
                    Text(choice.displayName).tag(choice.id)
                }
                if let custom = customChoice {
                    Text("\(custom.displayName) (custom)").tag(custom.id)
                }
                Text("Custom…").tag(Self.customTag)
            }
            .labelsHidden()
            .font(.callout)
            .accessibilityLabel(label)

            if isEditingCustom {
                HStack(spacing: RafuMetrics.space1) {
                    TextField("Model identifier", text: $customDraft)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(theme.palette.textPrimary)
                        .focused($isCustomFieldFocused)
                        .rafuField(isFocused: isCustomFieldFocused)
                        .onSubmit(applyCustom)
                        .accessibilityLabel("\(label), custom model identifier")
                    Button("Use", action: applyCustom)
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .disabled(
                            ConductorModelResolution.normalized(customDraft) == nil
                        )
                        .accessibilityLabel("Use this custom model for \(label)")
                }
                // Focus cannot be set in the same update that inserts the
                // field — the target view does not exist yet — so hop once
                // rather than sleeping (the goal pane's own rule).
                .task(id: isEditingCustom) {
                    guard isEditingCustom else { return }
                    await Task.yield()
                    isCustomFieldFocused = true
                }
            }

            if inheritedCaption != nil {
                Label(inheritedCaption ?? "", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(label): \(resolution.detailedLabel)")
            }
        }
    }

    /// Shown only when the picker's own text does not already name what will
    /// run — i.e. the field says "CLI default" but something inherited
    /// actually names a model. Repeating the value the picker already
    /// displays would be noise.
    private var inheritedCaption: String? {
        guard ConductorModelResolution.normalized(value) == nil,
            resolution.namesAModel
        else { return nil }
        return resolution.detailedLabel
    }

    /// The current value when it is one no catalog entry matches, so a
    /// hand-typed id remains a selectable row rather than vanishing from its
    /// own picker.
    private var customChoice: ConductorModelChoice? {
        guard let choice = ConductorModelCatalog.choice(for: value, in: available),
            choice.source == .custom
        else { return nil }
        return choice
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { isEditingCustom ? Self.customTag : value },
            set: { newValue in
                guard newValue != Self.customTag else {
                    customDraft = value
                    isEditingCustom = true
                    return
                }
                isEditingCustom = false
                value = newValue
            })
    }

    private func applyCustom() {
        guard let trimmed = ConductorModelResolution.normalized(customDraft) else { return }
        value = trimmed
        isEditingCustom = false
    }
}
