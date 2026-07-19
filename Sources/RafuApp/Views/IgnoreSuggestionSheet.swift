import SwiftUI

/// Accept/cancel sheet for an AI-proposed `.gitignore`/`.dockerignore` (see
/// `WorkspaceSession.suggestIgnoreFile(kind:)`). The proposed content stays
/// lightly editable before acceptance; each proposed pattern shows the
/// model's own stated reason next to it.
struct IgnoreSuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "eye.slash",
                title: session.ignoreSuggestion.map { "Proposed \($0.kind.displayName)" }
                    ?? "Proposed Ignore File",
                subtitle:
                    "Rafu sent only the workspace's file tree and the existing ignore file — never file contents."
            )

            if session.isSuggestingIgnore {
                // Same "generating" affordance as the commit composer: the
                // animated theme-gradient border (static under Reduce
                // Motion), not a bare spinner.
                VStack(spacing: 8) {
                    Text("Asking the configured AI provider…")
                        .font(.callout)
                        .foregroundStyle(theme.palette.textSecondary)
                    Button("Stop", systemImage: "stop.fill") {
                        session.cancelIgnoreSuggestion()
                        dismiss()
                    }
                    .buttonStyle(RafuSecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                        .fill(theme.palette.fieldBackground)
                )
                .aiCommitGeneratingBorder(isActive: true)
            } else if let suggestion = session.ignoreSuggestion {
                proposalContent(suggestion)
            }

            if let error = session.ignoreSuggestionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.error)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    session.cancelIgnoreSuggestion()
                    dismiss()
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Accept") {
                    guard let content = session.ignoreSuggestion?.editableContent else { return }
                    Task {
                        await session.acceptIgnoreSuggestion(content: content)
                        dismiss()
                    }
                }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(session.isSuggestingIgnore || !hasAcceptableContent)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 520, height: 460)
    }

    private var hasAcceptableContent: Bool {
        !(session.ignoreSuggestion?.editableContent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    @ViewBuilder
    private func proposalContent(_ suggestion: WorkspaceSession.IgnoreSuggestionState)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text("Content")
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            TextEditor(text: contentBinding)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140, maxHeight: 200)
                .rafuField()

            if !suggestion.proposed.reasons.isEmpty {
                Text("Reasons")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(suggestion.proposed.reasons, id: \.pattern) { reason in
                            HStack(alignment: .top, spacing: 8) {
                                RafuChip(text: reason.pattern, foreground: theme.palette.accent)
                                Text(reason.reason)
                                    .font(.caption)
                                    .foregroundStyle(theme.palette.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { session.ignoreSuggestion?.editableContent ?? "" },
            set: { session.ignoreSuggestion?.editableContent = $0 }
        )
    }
}
