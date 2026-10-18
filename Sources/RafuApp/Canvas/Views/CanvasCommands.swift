import SwiftUI

struct CanvasCommands: Commands {
    @FocusedValue(\.workspaceSession) private var session
    private var board: CanvasBoardState? { session?.selectedCanvas }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Canvas…") { session?.requestNewCanvas() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(session?.rootURL == nil)
            Button("Open Canvas…") { session?.requestCanvasLibrary() }.disabled(
                session?.rootURL == nil)
        }
        CommandMenu("Canvas") {
            if let board, let session {
                Menu("Add to Canvas") { CanvasAddMenuItems(board: board, session: session) }
            }
            Divider()
            Button("Board") {
                board?.backToBoard()
                board?.showsList = false
            }
            .keyboardShortcut("1", modifiers: [.control, .command])
            .disabled(board == nil)
            Button("List") {
                board?.backToBoard()
                board?.showsList = true
            }
            .keyboardShortcut("2", modifiers: [.control, .command])
            .disabled(board == nil)
            Divider()
            Button("Zoom to Fit") { board?.fitAll() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(board == nil)
            Button("Zoom to Selection") { board?.zoomToSelection() }
                .keyboardShortcut("9", modifiers: [.command, .option])
                .disabled(board?.selection.isEmpty != false)
            Button("Actual Size") { board?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(board == nil)
            Button("Zoom In") { board?.zoom(1.2) }.disabled(board == nil)
            Button("Zoom Out") { board?.zoom(1 / 1.2) }.disabled(board == nil)
            Divider()
            Menu("Arrange") {
                Button("Tidy Up") {
                    if let board { session?.performCanvasEdit(board) { try board.arrange() } }
                }
                .disabled(board == nil)
                Divider()
                ForEach(CanvasAlignment.allCases, id: \.self) { alignment in
                    Button(alignment.title) {
                        if let board {
                            session?.performCanvasEdit(board) { try board.align(alignment) }
                        }
                    }
                    .disabled((board?.selection.count ?? 0) < 2)
                }
                Divider()
                ForEach(CanvasDistribution.allCases, id: \.self) { distribution in
                    Button(distribution.title) {
                        if let board {
                            session?.performCanvasEdit(board) { try board.distribute(distribution) }
                        }
                    }
                    .disabled((board?.selection.count ?? 0) < 3)
                }
                Divider()
                Button("Bring to Front") {
                    if let board {
                        session?.performCanvasEdit(board) { try board.bringSelectionToFront() }
                    }
                }
                .disabled(board?.selection.isEmpty != false)
                Button("Send to Back") {
                    if let board {
                        session?.performCanvasEdit(board) { try board.sendSelectionToBack() }
                    }
                }
                .disabled(board?.selection.isEmpty != false)
            }
            .disabled(board == nil)
            Menu("Show Links") {
                ForEach(CanvasLinkVisibility.allCases, id: \.self) { choice in
                    Button {
                        board?.linkVisibility = choice
                    } label: {
                        if board?.linkVisibility == choice {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            }
            .disabled(board == nil)
            Button("Connect Selected Cards…") {
                if let board { session?.requestCanvasConnection(board.id) }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(board?.selection.count != 2)
            Divider()
            Button("Zoom to Card") {
                if let id = board?.selection.first { board?.zoomToCard(id) }
            }
            .disabled(board?.selection.count != 1)
            Button("Return to Board") {
                board?.backToBoard()
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(board?.contentIsActive != true)
            Divider()
            Button("Undo Canvas Layout") { board?.performUndo() }.disabled(board?.canUndo != true)
            Button("Redo Canvas Layout") { board?.performRedo() }.disabled(board?.canRedo != true)
            Button("Close Selected Cards") { session?.closeSelectedCanvasNodes() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(session?.canCloseSelectedCanvasNodes != true)
            Button("Remove Selected Cards…") {
                if let board { session?.requestCanvasCardRemoval(board.id) }
            }.disabled(board?.selection.isEmpty != false)
        }
        CommandGroup(after: .help) {
            Button("Canvas Shortcuts") { session?.canvasDialog = .shortcuts }
                .disabled(session == nil)
        }
    }
}
