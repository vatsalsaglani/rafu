import AppKit
import SwiftUI

/// Diagram items for the menu bar's Ensemble menu: Icon Library…, Convert to
/// Frame, Export…, Import Icon Pack…. The Ensemble bar has no overflow menu;
/// it offers Export as a button and the icon library as an Add palette tile.
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
    /// The Icon Library panel while it is on screen. Closing it releases the
    /// panel, its hosting view and its search results (no keep-alive).
    static let libraryHolder = CanvasLibraryPanelHolder()
    private static let libraryTarget = CanvasIconLibraryTarget()

    /// Test seam: whether an Icon Library panel is alive.
    static var libraryPanelIsLoaded: Bool { libraryHolder.isLoaded }

    /// Adds "Icon Library…" (S) and "Convert Selection to Frame" (G) to the
    /// whiteboard tool palette. Called once at launch.
    static func registerPaletteItems() {
        CanvasBoardKeyMap.assertUnique()
        CanvasToolPalette.register(
            CanvasToolPaletteItem(
                id: CanvasBoardKeyMap.iconLibraryItemID, title: "Icon Library…",
                symbol: "square.grid.3x3",
                key: CanvasBoardKeyMap.paletteItemKeys[CanvasBoardKeyMap.iconLibraryItemID]
            ) { board, session in showLibrary(board: board, session: session) })
        CanvasToolPalette.register(
            CanvasToolPaletteItem(
                id: CanvasBoardKeyMap.convertToFrameItemID, title: "Convert Selection to Frame",
                symbol: "rectangle.dashed",
                key: CanvasBoardKeyMap.paletteItemKeys[CanvasBoardKeyMap.convertToFrameItemID]
            ) { board, session in
                session.performCanvasEdit(board) { try board.convertSelectionToFrame() }
            })
    }

    /// Shows the floating Icon Library: a borderless, non-activating panel
    /// with the Rafu popup surface. Arrow keys move, Return adds, Escape
    /// closes.
    static func showLibrary(board: CanvasBoardState, session: WorkspaceSession) {
        libraryTarget.board = board
        libraryTarget.session = session
        if let panel = libraryHolder.panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = CanvasIconLibraryPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: CanvasIconLibraryMetrics.minimumPanelWidth, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .resizable],
            backing: .buffered, defer: true)
        panel.title = "Icon Library"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.minSize = NSSize(width: CanvasIconLibraryMetrics.minimumPanelWidth, height: 400)
        panel.setAccessibilityTitle("Icon Library")
        panel.contentView = NSHostingView(
            rootView: CanvasIconLibraryView(
                target: libraryTarget, close: { [weak panel] in panel?.close() }
            )
            .rafuPopupSurface(.floating)
            .rafuTheme(RafuThemeCatalog.resolvedForCurrentAppearance())
            .rafuMotionScope())
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow {
            let frame = parent.frame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - 220, y: max(frame.minY, frame.midY - 270)))
        } else {
            panel.center()
        }
        libraryHolder.install(panel)
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
        presentSheet(size: NSSize(width: 420, height: 190)) { dismiss in
            RafuTextFieldPopup(
                symbol: "character.cursor.ibeam", title: "Edit Label",
                subtitle: "The label appears below the icon.", fieldLabel: "Label",
                initialText: card.title, actionTitle: "Save", cancel: dismiss
            ) { label in
                dismiss()
                session.performCanvasEdit(board) { try board.setServiceIconLabel(card.id, label) }
            }
        }
    }

    /// Asks a yes/no question in a Rafu popup sheet on the workspace window.
    /// Returns false when the user cancels, or when no window can host it
    /// (nothing changes then).
    static func confirm(
        symbol: String, title: String, message: String, actionTitle: String
    ) async -> Bool {
        guard RafuPopupPresenter.parentWindow() != nil else { return false }
        return await withCheckedContinuation { continuation in
            let answer = CanvasPopupAnswer(continuation)
            presentSheet(size: NSSize(width: 420, height: 180)) { dismiss in
                RafuConfirmPopup(
                    symbol: symbol, title: title, message: message,
                    actions: [
                        .init(actionTitle) {
                            dismiss()
                            answer.resume(true)
                        }
                    ],
                    defaultActionID: actionTitle
                ) {
                    dismiss()
                    answer.resume(false)
                }
            }
        }
    }

    static func presentSheet<Content: View>(
        size: NSSize, @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        RafuPopupPresenter.presentSheet(size: size, content: content)
    }
}

/// Holds the Icon Library panel only while it is open. The panel's close
/// drops the reference, so the panel, its hosting view and its search
/// results are freed (E-fix 1).
@MainActor
final class CanvasLibraryPanelHolder {
    private(set) var panel: NSPanel?
    private var closeObserver: (any NSObjectProtocol)?

    var isLoaded: Bool { panel != nil }

    func install(_ panel: NSPanel) {
        release()
        self.panel = panel
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.release() }
        }
    }

    /// Drops the panel. AppKit is still inside `close()` when this runs, so
    /// the last reference lives until the next main-actor turn.
    func release() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let closing = panel else { return }
        panel = nil
        Task { @MainActor in withExtendedLifetime(closing) {} }
    }
}

/// A borderless panel that still takes the keys (its search field), and
/// closes on Escape.
final class CanvasIconLibraryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
}
