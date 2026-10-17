import SwiftUI

struct CanvasConnectionDialog: View {
    let boardID: CanvasID
    var edgeID: UUID? = nil
    var initialFrom: CanvasCardID? = nil
    var initialTo: CanvasCardID? = nil
    let session: WorkspaceSession
    @State private var from: CanvasCardID?
    @State private var to: CanvasCardID?
    @State private var label = "Related to"
    @State private var error: String?

    private var board: CanvasBoardState? { session.canvas.boards[boardID] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edgeID == nil ? "Connect Cards" : "Edit Connection").font(.title2.bold())
            Picker("From", selection: $from) {
                Text("Choose source").tag(Optional<CanvasCardID>.none)
                ForEach(board?.cards ?? []) { Text($0.title).tag(Optional($0.id)) }
            }
            Picker("To", selection: $to) {
                Text("Choose target").tag(Optional<CanvasCardID>.none)
                ForEach(board?.cards ?? []) { Text($0.title).tag(Optional($0.id)) }
            }
            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            Text("Related links show a relationship. They do not send commands or start work.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { session.canvasDialog = nil }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(
                        from == nil || to == nil || from == to
                    )
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            if let edge = board?.connections.first(where: { $0.id == edgeID }) {
                from = edge.from
                to = edge.to
                label = edge.label
            } else {
                from = initialFrom
                to = initialTo
            }
        }
    }

    private func save() {
        guard let board, let from, let to else { return }
        do {
            if let edgeID {
                try board.edit { document in
                    guard let index = document.connections.firstIndex(where: { $0.id == edgeID })
                    else { throw CanvasError.unavailable }
                    document.connections[index].from = from
                    document.connections[index].to = to
                    document.connections[index].label = label
                    document.connections[index].behavior = .related
                }
            } else {
                try board.addConnection(from: from, to: to, label: label, behavior: .related)
            }
            session.canvasDialog = nil
        } catch { self.error = error.localizedDescription }
    }
}
