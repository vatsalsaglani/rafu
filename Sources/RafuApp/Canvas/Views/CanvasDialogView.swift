import SwiftUI

struct CanvasDialogView: View {
    let dialog: CanvasDialog
    let session: WorkspaceSession
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            if case .library = dialog {
                library
            } else if case .reload = dialog {
                Text(
                    "Reload replaces this window's Canvas with the saved version. Unsaved Canvas changes will be lost."
                )
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                if case .web = dialog {
                    Text(
                        "Use a loopback URL. Credentials are not allowed. Query strings and fragments are removed before saving. The app can contact external services after you connect."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { session.canvasDialog = nil }
                if case .library = dialog {
                } else {
                    Button(actionTitle) { submit() }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding(24).frame(width: 480)
        .task {
            text = initialText
            if case .library = dialog { await session.prepareCanvasLibrary() }
        }
    }

    private var library: some View {
        VStack(alignment: .leading) {
            if let notice = session.canvas.libraryNotice { Text(notice).font(.callout) }
            if session.canvas.isLoading { ProgressView() }
            if session.canvas.library.isEmpty {
                Text("No saved Canvases.").foregroundStyle(.secondary)
            }
            List(session.canvas.library, id: \.id) { item in
                HStack {
                    Button(item.title) {
                        session.canvasDialog = nil
                        Task { await session.openCanvas(item.id) }
                    }.buttonStyle(.plain)
                    Spacer()
                    if session.canvas.boards[item.id] == nil {
                        Button("Delete Saved Canvas", systemImage: "trash", role: .destructive) {
                            // Deletion uses a separate confirmation with the record revision.
                            session.pendingCanvasDelete = item
                            session.canvasDialog = nil
                        }.labelStyle(.iconOnly)
                    }
                }
            }.frame(height: 240)
        }
    }

    private var title: String {
        switch dialog {
        case .newBoard: "New Canvas"
        case .library: "Saved Canvases"
        case .renameBoard: "Rename Canvas"
        case .renameCard: "Rename Card"
        case .web: "Add Local Web App"
        case .connection: "Connect Cards"
        case .connectionLabel: "Edit Connection"
        case .reload: "Reload Canvas?"
        }
    }
    private var placeholder: String {
        if case .web = dialog { "http://localhost:3000" } else { "Name" }
    }
    private var actionTitle: String { if case .reload = dialog { "Reload" } else { "Save" } }
    private var initialText: String {
        switch dialog {
        case .renameBoard(let id): session.canvas.boards[id]?.title ?? ""
        case .renameCard(let id, let card):
            session.canvas.boards[id]?.cards.first { $0.id == card }?.title ?? ""
        case .connectionLabel(let id, let edge):
            session.canvas.boards[id]?.connections.first { $0.id == edge }?.label ?? ""
        case .connection: "Related to"
        default: ""
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                switch dialog {
                case .newBoard:
                    guard await session.createCanvas(named: text) else {
                        error =
                            session.canvas.libraryNotice
                            ?? "Enter a Canvas name of 1 to 120 characters."
                        return
                    }
                case .library: break
                case .reload(let id):
                    guard await session.reloadCanvas(id) else {
                        error = "The Canvas could not be reloaded."
                        return
                    }
                case .renameBoard(let id):
                    try session.canvas.boards[id]?.edit { $0.title = text }
                case .renameCard(let id, let card):
                    try session.canvas.boards[id]?.edit { value in
                        if let index = value.cards.firstIndex(where: { $0.id == card }) {
                            value.cards[index].title = text
                        }
                    }
                case .web(let id):
                    let destination = try CanvasWebDestination(text)
                    try session.canvas.boards[id]?.add(
                        title: String(destination.address.prefix(120)),
                        content: .web(destination: destination))
                case .connection(let id, let from, let to):
                    try session.canvas.boards[id]?.edit {
                        $0.connections.append(.init(from: from, to: to, label: text))
                    }
                case .connectionLabel(let id, let edge):
                    try session.canvas.boards[id]?.edit { value in
                        if let index = value.connections.firstIndex(where: { $0.id == edge }) {
                            value.connections[index].label = text
                        }
                    }
                }
                session.canvasDialog = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
