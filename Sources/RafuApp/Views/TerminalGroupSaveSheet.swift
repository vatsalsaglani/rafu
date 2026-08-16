import SwiftUI

nonisolated enum TerminalGroupSheetPresentation {
    enum NameValidation: Equatable {
        case valid(String)
        case invalid(String)
    }

    static func validatedName(_ rawName: String) -> NameValidation {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalGroupName(trimmed) != nil else {
            return .invalid("Enter a Terminal Group name of 80 Unicode scalars or fewer.")
        }
        return .valid(trimmed)
    }

    static func layoutSummary(_ node: TerminalGroupNode) -> String {
        let counts = layoutCounts(node)
        let paneText = "\(counts.panes) \(counts.panes == 1 ? "pane" : "panes")"
        guard counts.columns + counts.rows > 0 else { return paneText }
        var forms: [String] = []
        if counts.columns > 0 {
            forms.append("\(counts.columns) side-by-side")
        }
        if counts.rows > 0 {
            forms.append("\(counts.rows) stacked")
        }
        return "\(paneText), \(forms.joined(separator: ", "))"
    }

    private static func layoutCounts(_ node: TerminalGroupNode) -> (
        panes: Int, columns: Int, rows: Int
    ) {
        switch node {
        case .pane:
            return (1, 0, 0)
        case .split(_, let axis, _, let first, let second):
            let left = layoutCounts(first)
            let right = layoutCounts(second)
            return (
                left.panes + right.panes,
                left.columns + right.columns + (axis == .columns ? 1 : 0),
                left.rows + right.rows + (axis == .rows ? 1 : 0)
            )
        }
    }
}

/// Window-scoped presentation for the frozen Terminal Group save request.
/// The session owns persistence and stale-request validation; this view owns
/// only its editable text and never reads the saved-layout store.
struct TerminalGroupSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession
    let request: WorkspaceSession.TerminalGroupSaveRequest
    @State private var name: String
    @State private var validationMessage: String?
    @FocusState private var nameFocused: Bool

    init(session: WorkspaceSession, request: WorkspaceSession.TerminalGroupSaveRequest) {
        self.session = session
        self.request = request
        _name = State(initialValue: request.proposedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "rectangle.3.group",
                title: request.kind == .saveAs ? "Save Terminal Group As" : "Save Terminal Group",
                subtitle: "Save a named Terminal Group layout for this workspace."
            )
            Text(layoutSummary)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
            TextField("Saved layout name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
                .accessibilityLabel("Saved Terminal Group name")
            Text(
                "Only layout metadata and ordinary shell profiles are saved. Restore is stopped and does not save terminal output."
            )
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error = validationMessage ?? session.terminalGroupStoreError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.error)
            }
            HStack {
                Button("Cancel", role: .cancel) {
                    session.cancelPendingTerminalGroupSave()
                    dismiss()
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(session.isPendingTerminalGroupSaveSubmission)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.isPendingTerminalGroupSaveSubmission || !isNameValid)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 460)
        .interactiveDismissDisabled(session.isPendingTerminalGroupSaveSubmission)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard case .valid(let trimmed) = TerminalGroupSheetPresentation.validatedName(name) else {
            validationMessage = "Enter a Terminal Group name of 80 Unicode scalars or fewer."
            return
        }
        validationMessage = nil
        session.updatePendingTerminalGroupSaveName(trimmed)
        session.completePendingTerminalGroupSave()
    }

    private var layoutSummary: String {
        guard let snapshot = session.terminal.terminalGroup(request.id) else {
            return "Layout summary unavailable."
        }
        return "Layout summary: \(TerminalGroupSheetPresentation.layoutSummary(snapshot.root))."
    }

    private var isNameValid: Bool {
        if case .valid = TerminalGroupSheetPresentation.validatedName(name) { return true }
        return false
    }
}

/// A separate native sheet so Rename has its own focused, cancellable draft.
struct TerminalGroupRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    let request: WorkspaceSession.TerminalGroupRenameRequest
    @State private var name: String
    @State private var validationMessage: String?
    @FocusState private var nameFocused: Bool

    init(session: WorkspaceSession, request: WorkspaceSession.TerminalGroupRenameRequest) {
        self.session = session
        self.request = request
        _name = State(initialValue: request.proposedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "pencil", title: "Rename Terminal Group",
                subtitle: "Update this open Terminal Group name.")
            TextField("Terminal Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(rename)
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) {
                    session.cancelPendingTerminalGroupRename()
                    dismiss()
                }
                .buttonStyle(RafuSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: rename)
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private func rename() {
        guard case .valid(let trimmed) = TerminalGroupSheetPresentation.validatedName(name) else {
            validationMessage = "Enter a Terminal Group name of 80 Unicode scalars or fewer."
            return
        }
        validationMessage = nil
        session.updatePendingTerminalGroupRename(trimmed)
        session.completePendingTerminalGroupRename()
        dismiss()
    }
}
