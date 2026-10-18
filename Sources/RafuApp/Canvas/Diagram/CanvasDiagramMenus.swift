import AppKit
import SwiftUI

/// Diagram items for the Canvas bar overflow menu and the Canvas menu:
/// Icon Library…, Convert to Frame, Export…, Import Icon Pack….
struct CanvasDiagramMenuItems: View {
    let board: CanvasBoardState
    let session: WorkspaceSession
    /// Only the app's Canvas menu registers the key equivalent.
    var showsShortcut = false

    var body: some View {
        Divider()
        Button("Icon Library…", systemImage: "square.grid.3x3") {
            CanvasDiagramPanels.showLibrary(board: board, session: session)
        }
        convertButton
        Button("Export…", systemImage: "square.and.arrow.up") {
            CanvasDiagramPanels.showExport(
                board: board, session: session,
                target: board.selection.isEmpty ? .board : .selection)
        }
        .disabled(board.cards.isEmpty || session.rootURL == nil)
        Button("Import Icon Pack…", systemImage: "square.and.arrow.down") {
            CanvasDiagramPanels.showImport()
        }
    }

    @ViewBuilder private var convertButton: some View {
        let button = Button("Convert to Frame", systemImage: "rectangle.dashed") {
            session.performCanvasEdit(board) { try board.convertSelectionToFrame() }
        }
        .disabled(board.selection.isEmpty)
        if showsShortcut {
            button.keyboardShortcut("g", modifiers: [.control, .command])
        } else {
            button
        }
    }
}

/// "Service Icon…" in the Add menu: opens the icon library.
struct CanvasDiagramAddMenuItem: View {
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        Divider()
        Button("Service Icon…", systemImage: "square.grid.3x3") {
            CanvasDiagramPanels.showLibrary(board: board, session: session)
        }
    }
}

/// Card context-menu items for frames, service icons and selections.
struct CanvasDiagramCardMenuItems: View {
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        Button("Convert to Frame", systemImage: "rectangle.dashed") {
            if !board.selection.contains(card.id) { board.select([card.id]) }
            session.performCanvasEdit(board) { try board.convertSelectionToFrame() }
        }
        if let frame = card.content.diagramFrame {
            Button("Select Frame Members", systemImage: "checkmark.rectangle.stack") {
                board.selectFrameMembers(card.id)
            }
            .disabled(frame.memberIDs.isEmpty)
            Menu("Frame Colour", systemImage: "paintpalette") {
                ForEach(CanvasFrameStyle.allCases, id: \.self) { style in
                    Button {
                        session.performCanvasEdit(board) { try board.setFrameStyle(card.id, style) }
                    } label: {
                        if frame.style == style {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Text(style.title)
                        }
                    }
                }
            }
            Button("Export Frame…", systemImage: "square.and.arrow.up") {
                CanvasDiagramPanels.showExport(
                    board: board, session: session, target: .frame(card.id))
            }
            .disabled(session.rootURL == nil)
        }
        if card.content.diagramServiceIcon != nil {
            Button("Edit Label…", systemImage: "character.cursor.ibeam") {
                CanvasDiagramPanels.editLabel(card: card, board: board, session: session)
            }
        }
    }
}

/// AppKit-hosted panels and sheets, so no view outside `Canvas/Diagram`
/// needs presentation state.
@MainActor
enum CanvasDiagramPanels {
    private static var libraryPanel: NSPanel?
    private static let libraryTarget = CanvasIconLibraryTarget()

    static func showLibrary(board: CanvasBoardState, session: WorkspaceSession) {
        libraryTarget.board = board
        libraryTarget.session = session
        if let panel = libraryPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: true)
        panel.title = "Icon Library"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(
            rootView: CanvasIconLibraryView(target: libraryTarget)
                .rafuTheme(RafuThemeCatalog.resolvedForCurrentAppearance()))
        panel.center()
        libraryPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    static func showExport(
        board: CanvasBoardState, session: WorkspaceSession, target: CanvasDiagramExportTarget
    ) {
        presentSheet(size: NSSize(width: 420, height: 360)) { dismiss in
            CanvasDiagramExportSheet(
                board: board, session: session, initialTarget: target, dismiss: dismiss)
        }
    }

    static func showImport() {
        presentSheet(size: NSSize(width: 480, height: 440)) { dismiss in
            CanvasIconPackImportView(dismiss: dismiss)
        }
    }

    static func editLabel(card: CanvasCard, board: CanvasBoardState, session: WorkspaceSession) {
        let alert = NSAlert()
        alert.messageText = "Edit Label"
        alert.informativeText = "The label appears below the icon."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: card.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel("Label")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let window = NSApp.keyWindow
        Task {
            let response: NSApplication.ModalResponse
            if let window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
            let label = field.stringValue
            session.performCanvasEdit(board) { try board.setServiceIconLabel(card.id, label) }
        }
    }

    private static func presentSheet<Content: View>(
        size: NSSize, @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
            backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        let dismiss: () -> Void = { [weak parent, weak sheet] in
            guard let sheet else { return }
            if let parent { parent.endSheet(sheet) } else { sheet.close() }
        }
        sheet.contentViewController = NSHostingController(
            rootView: content(dismiss)
                .rafuTheme(RafuThemeCatalog.resolvedForCurrentAppearance()))
        parent.beginSheet(sheet)
    }
}
