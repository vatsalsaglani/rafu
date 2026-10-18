import AppKit
import RafuCore
import SwiftUI

struct CanvasAddCardMenu: View {
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        Menu("Add Card", systemImage: "plus") {
            Button("File…") { session.chooseCanvasFile(board.id, imageOnly: false) }
            Button("Image…") { session.chooseCanvasFile(board.id, imageOnly: true) }
            Button("Note") { session.addCanvasNote(board.id) }
            Button("Terminal") { session.addCanvasStoppedTerminal(board.id) }
            Button("Local Web App…") { session.canvasDialog = .web(board.id) }
            Button("Native macOS App…") { session.chooseCanvasApplication(board.id) }
        }
        .fixedSize()
        .disabled(board.cards.count >= CanvasLimits.cards)
    }
}

struct CanvasCardShell: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.canvasPresentationID) private var presentationID
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    var focusBoard: () -> Void = {}
    var isConnectionTarget = false
    var updateConnectionDrag: (CanvasCardID, CGPoint) -> Void = { _, _ in }
    var finishConnectionDrag: (CanvasCardID, CGPoint) -> Void = { _, _ in }
    var cancelConnectionDrag: (CanvasCardID) -> Void = { _ in }
    @State private var dragStart: CanvasRect?
    @State private var resizeStart: CanvasRect?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: card.content.symbol).foregroundStyle(theme.palette.accent)
                Button {
                    activateCard()
                } label: {
                    Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(board.selection.contains(card.id) ? .isSelected : [])
                Menu {
                    Button("Focus") { board.focus(card.id) }
                    Button("Rename…") { session.canvasDialog = .renameCard(board.id, card.id) }
                    if case .terminal = card.content {
                        Button("Copy Mention") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                CanvasBridgePeer.mention(for: card.title), forType: .string)
                        }
                    }
                    Menu("Connect to…") {
                        ForEach(board.cards) { target in
                            if target.id != card.id {
                                Button(target.title) {
                                    session.connectCanvasCards(
                                        boardID: board.id, from: card.id, to: target.id)
                                }
                            }
                        }
                    }
                    .disabled(board.cards.count < 2)
                    Button("Move Left") { move(dx: -20, dy: 0) }
                    Button("Move Right") { move(dx: 20, dy: 0) }
                    Button("Move Up") { move(dx: 0, dy: -20) }
                    Button("Move Down") { move(dx: 0, dy: 20) }
                    Button("Make Larger") { resize(40) }
                    Button("Make Smaller") { resize(-40) }
                    Button("Remove…") {
                        board.selection = [card.id]
                        session.requestCanvasCardRemoval(board.id)
                    }
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("\(card.title) actions")
                }
                .menuStyle(.borderlessButton).frame(width: 18)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(theme.palette.sidebarBackground)
            .contentShape(.rect)
            .highPriorityGesture(cardDrag)
            Divider()
            if case .nativeApp = card.content {
                CanvasNativeAppCard(card: card, board: board, session: session)
            } else if case .terminal = card.content {
                CanvasTerminalCard(card: card, board: board, session: session)
            } else if case .web = card.content {
                CanvasWebCard(card: card, board: board, session: session)
            } else if case .file(let path) = card.content, board.focusedCardID == card.id {
                CanvasFilePreview(path: path, session: session)
            } else if case .note = card.content {
                CanvasNoteCard(
                    card: card, board: board, session: session,
                    presentationID: presentationID,
                    isCurrentPresentation: session.canvasResources[board.id]?.canPresent(
                        owner: presentationID) == true,
                    scale: board.viewport.scale)
            } else if case .image(let path) = card.content {
                Button(action: activateCard) {
                    CanvasImageContent(path: path, session: session).padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                }.buttonStyle(.plain)
                    .highPriorityGesture(cardDrag)
            } else {
                Button {
                    activateCard()
                } label: {
                    CanvasCardSummary(card: card)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(14).contentShape(.rect)
                }.buttonStyle(.plain)
                    .highPriorityGesture(cardDrag)
            }
            Divider()
            HStack {
                if case .terminal(let groupID) = card.content {
                    CanvasTerminalSessionStatus(groupID: groupID, session: session)
                } else {
                    Text(card.content.kindName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if case .file(let path) = card.content {
                    Button("Open File") { session.openCanvasFile(path) }
                } else if case .image(let path) = card.content {
                    Button("Open Image") { session.openCanvasFile(path) }
                }
                Button("Focus") { board.focus(card.id) }
            }
            .font(.caption).buttonStyle(.plain).padding(.leading, 12).padding(.trailing, 28).frame(
                height: 30)
        }
        .background(theme.palette.editorBackground)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(
                isConnectionTarget || board.selection.contains(card.id)
                    ? theme.palette.accent : theme.palette.borderSubtle,
                lineWidth: isConnectionTarget ? 3 : (board.selection.contains(card.id) ? 2 : 1)
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global).onChanged { value in
                        if resizeStart == nil {
                            board.backToBoard()
                            focusBoard()
                            resizeStart = card.rect
                            board.beginGesture()
                        }
                        guard var rect = resizeStart else { return }
                        rect.width = min(
                            2_000,
                            max(240, rect.width + value.translation.width / board.viewport.scale))
                        rect.height = min(
                            2_000,
                            max(160, rect.height + value.translation.height / board.viewport.scale))
                        board.setRect(rect, for: card.id)
                    }.onEnded { _ in
                        board.endGesture()
                        resizeStart = nil
                    }
                )
                .accessibilityHidden(true)
        }
        .overlay(alignment: .trailing) {
            CanvasConnectionHandle(
                title: card.title,
                connect: { session.canvasDialog = .connection(board.id, card.id, nil) },
                changed: { updateConnectionDrag(card.id, $0) },
                ended: { finishConnectionDrag(card.id, $0) },
                cancelled: { cancelConnectionDrag(card.id) }
            )
            .offset(x: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.title), \(card.content.kindName)")
    }

    private func activateCard() {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            focusBoard()
            if board.selection.contains(card.id) {
                board.selection.remove(card.id)
            } else {
                board.selection.insert(card.id)
            }
        } else {
            board.focus(card.id)
        }
    }

    private var cardDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { value in
            if dragStart == nil {
                board.backToBoard()
                focusBoard()
                dragStart = card.rect
                board.beginGesture()
                board.selection = [card.id]
            }
            guard var rect = dragStart else { return }
            rect.x = min(
                50_000,
                max(-50_000, rect.x + value.translation.width / board.viewport.scale))
            rect.y = min(
                50_000,
                max(-50_000, rect.y + value.translation.height / board.viewport.scale))
            board.setRect(rect, for: card.id)
        }.onEnded { _ in
            if var rect = board.cards.first(where: { $0.id == card.id })?.rect {
                rect.x = (rect.x / 8).rounded() * 8
                rect.y = (rect.y / 8).rounded() * 8
                board.setRect(rect, for: card.id)
            }
            board.endGesture()
            dragStart = nil
        }
    }

    private func move(dx: Double, dy: Double) {
        board.selection = [card.id]
        session.performCanvasEdit(board) { try board.moveSelection(dx: dx, dy: dy) }
    }

    private func resize(_ delta: Double) {
        session.performCanvasEdit(board) {
            try board.edit { document in
                guard let index = document.cards.firstIndex(where: { $0.id == card.id }) else {
                    return
                }
                document.cards[index].rect.width = min(2_000, max(240, card.rect.width + delta))
                document.cards[index].rect.height = min(2_000, max(160, card.rect.height + delta))
            }
        }
    }
}

private struct CanvasCardSummary: View {
    let card: CanvasCard
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch card.content {
            case .file(let path):
                Label(path, systemImage: "doc.text").font(.callout)
                Text("Open in the existing editor to keep its text and undo history.")
            case .image(let path):
                Label(path, systemImage: "photo").font(.callout)
                Text("Focus to view the image.")
            case .note(let snapshot):
                Text(
                    snapshot.isEmpty
                        ? "An empty note. Focus to edit." : String(snapshot.prefix(512))
                )
                .lineLimit(9)
            case .terminal:
                Label("Terminal", systemImage: "terminal")
                Text("Click to use this terminal.")
            case .web(let destination):
                Label(destination.address, systemImage: "globe")
                Text("Focus and choose Connect. Rafu does not start a server.")
            case .nativeApp:
                EmptyView()
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}

struct CanvasListView: View {
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        List {
            Section("Cards") {
                ForEach(board.cards) { card in
                    HStack {
                        Button {
                            board.selection = [card.id]
                            board.focus(card.id)
                        } label: {
                            Label(card.title, systemImage: card.content.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Text(card.content.kindName).font(.caption).foregroundStyle(.secondary)
                        Button("Select") { board.selection.insert(card.id) }
                        Button("Remove…") {
                            board.selection = [card.id]
                            session.requestCanvasCardRemoval(board.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Relationships") {
                ForEach(board.connections) { connection in
                    HStack {
                        Text(relationshipText(connection))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Edit Connection…") {
                            session.canvasDialog = .connectionLabel(board.id, connection.id)
                        }
                        Button("Remove") {
                            session.performCanvasEdit(board) {
                                try board.edit {
                                    $0.connections.removeAll { $0.id == connection.id }
                                }
                                CanvasLiveBridge.shared.disable(connection.id, in: board)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func relationshipText(_ connection: CanvasConnection) -> String {
        let from = board.cards.first { $0.id == connection.from }?.title ?? "Missing card"
        let to = board.cards.first { $0.id == connection.to }?.title ?? "Missing card"
        if connection.behavior == .session {
            return "\(from) ↔ Session link: \(connection.label) ↔ \(to)"
        }
        return "\(from) → Related: \(connection.label) → \(to)"
    }
}
