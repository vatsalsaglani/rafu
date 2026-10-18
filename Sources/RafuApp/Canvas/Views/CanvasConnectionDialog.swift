import SwiftUI

/// The accessible path to make or edit a link (review C16). A form with
/// right-aligned labels; "Kind" appears only when both ends are terminals.
struct CanvasConnectionDialog: View {
    @Environment(\.rafuTheme) private var theme
    let boardID: CanvasID
    var edgeID: UUID? = nil
    var initialFrom: CanvasCardID? = nil
    var initialTo: CanvasCardID? = nil
    let session: WorkspaceSession
    @State private var from: CanvasCardID?
    @State private var to: CanvasCardID?
    @State private var label = ""
    @State private var kind = CanvasConnectionBehavior.session
    @State private var error: String?

    private var board: CanvasBoardState? { session.canvas.boards[boardID] }

    private func isTerminal(_ id: CanvasCardID?) -> Bool {
        guard let id, let card = board?.cards.first(where: { $0.id == id }) else { return false }
        if case .terminal = card.content { return true }
        return false
    }

    private var bothTerminals: Bool { isTerminal(from) && isTerminal(to) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edgeID == nil ? "Connect Cards" : "Edit Link")
                .font(.system(size: 15, weight: .semibold))
            Form {
                Picker("From:", selection: $from) {
                    Text("Choose a card").tag(Optional<CanvasCardID>.none)
                    ForEach(board?.cards ?? []) { Text($0.title).tag(Optional($0.id)) }
                }
                Picker("To:", selection: $to) {
                    Text("Choose a card").tag(Optional<CanvasCardID>.none)
                    ForEach(board?.cards ?? []) { Text($0.title).tag(Optional($0.id)) }
                }
                TextField("Label:", text: $label, prompt: Text("Label (optional)"))
                if bothTerminals {
                    Picker("Kind:", selection: $kind) {
                        Text("Relationship").tag(CanvasConnectionBehavior.related)
                        Text("Message link").tag(CanvasConnectionBehavior.session)
                    }
                }
            }
            .formStyle(.columns)
            Text(
                bothTerminals
                    ? "A message link lets the two agent sessions send messages both ways. A relationship only shows that the cards belong together."
                    : "A relationship shows that two cards belong together. It sends nothing."
            )
            .font(.callout).foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(theme.palette.error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { session.canvasDialog = nil }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(from == nil || to == nil || from == to)
            }
        }
        .padding(24).frame(width: 480)
        .onAppear {
            if let edge = board?.connections.first(where: { $0.id == edgeID }) {
                from = edge.from
                to = edge.to
                label = Self.isDefaultLabel(edge.label) ? "" : edge.label
                kind = edge.behavior
            } else {
                from = initialFrom
                to = initialTo
            }
        }
    }

    /// An empty label is stored under the default words, because a saved
    /// link needs a non-empty label. The form shows those words as empty.
    static func isDefaultLabel(_ text: String) -> Bool {
        text == "Related to" || text == "Session link"
    }

    private func save() {
        guard let board, let from, let to else { return }
        let behavior: CanvasConnectionBehavior = bothTerminals ? kind : .related
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored =
            trimmed.isEmpty ? (behavior == .session ? "Session link" : "Related to") : trimmed
        do {
            if let edgeID {
                try board.edit { document in
                    guard let index = document.connections.firstIndex(where: { $0.id == edgeID })
                    else { throw CanvasError.unavailable }
                    document.connections[index].from = from
                    document.connections[index].to = to
                    document.connections[index].label = stored
                    document.connections[index].behavior = behavior
                }
                // Editing never resumes a link; message links start and stay Paused
                // until the user chooses Resume.
                if behavior != .session {
                    CanvasLiveBridge.shared.disable(edgeID, in: board)
                }
            } else {
                try board.addConnection(from: from, to: to, label: stored, behavior: behavior)
            }
            session.canvasDialog = nil
        } catch { self.error = error.localizedDescription }
    }
}
