import MarkdownUI
import SwiftUI

/// The goal surface of the New Ensemble canvas: ONE pane that is a plain
/// Markdown text editor while focused and the rendered document when not.
/// Click (or the header's Edit action, or the accessibility action) puts the
/// caret back; clicking away renders.
///
/// Explicitly not a side-by-side editor/preview split. A split doubles the
/// width for a surface whose whole job is one column of prose, and it makes
/// the user watch two things while writing one.
///
/// Two properties this shape buys, both load-bearing:
///
/// 1. **The goal stays plain text.** `text` is the raw `String` the user
///    typed; the renderer is read-only and never writes back. That matters
///    because `EnsembleStartModel.start(in:)` pastes this string verbatim
///    into a CLI prompt (see `ensemble-onboarding.md`, "The paste-fallback
///    rule is universal") — a rich-text or attributed-string editor here
///    would be a correctness bug, not a nicety.
/// 2. **Zero Markdown work on the typing path.** The renderer only exists
///    while the editor is unfocused, so no parse, no debounce, and no
///    per-keystroke re-render — unlike `MarkdownPreviewView`'s live split
///    mode, which needs a 200 ms trailing debounce precisely because both
///    halves are on screen at once.
struct EnsembleGoalPane: View {
    @Binding var text: String

    @Environment(\.rafuTheme) private var theme
    @FocusState private var isEditorFocused: Bool
    @State private var isEditing = false

    /// An empty goal has nothing to render, so the editor is the only
    /// sensible face for it — the pane opens ready to type without stealing
    /// focus (see the `.task` guard below).
    private var showsEditor: Bool {
        isEditing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            if showsEditor {
                editor
            } else {
                renderedGoal
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var paneHeader: some View {
        RafuCardHeaderRow {
            HStack(spacing: RafuMetrics.space2) {
                Label("Goal", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .textCase(.uppercase)
                RafuChip(text: showsEditor ? "Editing Markdown" : "Rendered")
            }
        } trailing: {
            Button {
                if showsEditor {
                    endEditing()
                } else {
                    beginEditing()
                }
            } label: {
                Image(systemName: showsEditor ? "eye" : "pencil")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 11))
            .disabled(showsEditor && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(showsEditor ? "Preview the rendered goal" : "Edit the goal as Markdown")
            .accessibilityLabel(showsEditor ? "Preview rendered goal" : "Edit goal as Markdown")
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(
                    "What should the ensemble accomplish? Plain language. Markdown is rendered when you click away."
                )
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.textMuted)
                .padding(.top, RafuMetrics.space4 + 2)
                .padding(.leading, RafuMetrics.space5 + 5)
                .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(.horizontal, RafuMetrics.space5)
                .padding(.vertical, RafuMetrics.space4)
                .accessibilityLabel("Ensemble goal, Markdown")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.editorBackground)
        // Focus is only claimed for an edit the user asked for. Yielding once
        // lets SwiftUI install the `TextEditor` before the `@FocusState`
        // write lands on it; without the hop the write targets a view that
        // does not exist yet and is silently dropped.
        .task(id: isEditing) {
            guard isEditing else { return }
            await Task.yield()
            isEditorFocused = true
        }
        // Clicking away renders. Guarded on the true→false edge so the
        // editor's own unfocused first frame does not immediately cancel the
        // edit the user just started.
        .onChange(of: isEditorFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused { isEditing = false }
        }
    }

    private var renderedGoal: some View {
        ScrollView {
            Markdown(text)
                .rafuMarkdownStyling()
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, RafuMetrics.space5)
                .padding(.vertical, RafuMetrics.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.editorBackground)
        .contentShape(.rect)
        .onTapGesture(perform: beginEditing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ensemble goal, rendered Markdown")
        .accessibilityHint("Activate to edit the goal")
        .accessibilityAction(named: "Edit goal", beginEditing)
    }

    private func beginEditing() {
        isEditing = true
    }

    private func endEditing() {
        isEditing = false
        isEditorFocused = false
    }
}
