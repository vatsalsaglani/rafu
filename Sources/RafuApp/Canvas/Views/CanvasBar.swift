import SwiftUI

/// The one 36 pt Canvas bar (review C1, C2, C14, C17): the canvas name as a
/// pull-down, the link status, Add, Arrange and the overflow.
struct CanvasBar: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        HStack(spacing: 8) {
            nameMenu
            Spacer(minLength: 8)
            CanvasLinkStatusItem(board: board)
            CanvasAgentSummaryBar(board: board, session: session)
            CanvasAddCardMenu(board: board, session: session)
            arrangeMenu
            overflowMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .task { await session.prepareCanvasLibrary() }
    }

    private var nameMenu: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") {
                session.canvasDialog = .renameBoard(board.id)
            }
            Button("Duplicate Ensemble", systemImage: "plus.square.on.square") {
                session.saveCanvasCopy(board.id)
            }
            Divider()
            ForEach(recentCanvases) { item in
                Button(item.title) { Task { await session.openCanvas(item.id) } }
            }
            Button("Open Ensemble…") { session.requestCanvasLibrary() }
            Divider()
            Button("Close Ensemble", systemImage: "xmark") { session.closeCanvas(board.id) }
        } label: {
            HStack(spacing: 4) {
                Text(board.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .menuStyle(.borderlessButton)
        .tint(theme.palette.textSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ensemble name and actions")
        .accessibilityLabel("Ensemble \(board.title)")
    }

    private var recentCanvases: [CanvasSummary] {
        Array(session.canvas.library.filter { $0.id != board.id }.prefix(8))
    }

    private var arrangeMenu: some View {
        Menu {
            Button("Tidy Up", systemImage: "square.grid.2x2") {
                session.performCanvasEdit(board) { try board.arrange() }
            }
            Divider()
            alignButton(.left)
            alignButton(.centre)
            alignButton(.right)
            Divider()
            alignButton(.top)
            alignButton(.middle)
            alignButton(.bottom)
            Divider()
            ForEach(CanvasDistribution.allCases, id: \.self) { distribution in
                Button(distribution.title, systemImage: distribution.symbol) {
                    session.performCanvasEdit(board) { try board.distribute(distribution) }
                }
                .disabled(board.selection.count < 3)
            }
            Divider()
            Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") {
                session.performCanvasEdit(board) { try board.bringSelectionToFront() }
            }
            .disabled(board.selection.isEmpty)
            Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") {
                session.performCanvasEdit(board) { try board.sendSelectionToBack() }
            }
            .disabled(board.selection.isEmpty)
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .tint(theme.palette.textSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Arrange cards")
        .accessibilityLabel("Arrange")
    }

    private func alignButton(_ alignment: CanvasAlignment) -> some View {
        Button(alignment.title, systemImage: alignment.symbol) {
            session.performCanvasEdit(board) { try board.align(alignment) }
        }
        .disabled(board.selection.count < 2)
    }

    private var overflowMenu: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") {
                session.canvasDialog = .renameBoard(board.id)
            }
            Button("Duplicate Ensemble", systemImage: "plus.square.on.square") {
                session.saveCanvasCopy(board.id)
            }
            Divider()
            Button("Select All  ⌘A") { board.select(Set(board.cards.map(\.id))) }
                .disabled(board.cards.isEmpty)
            Divider()
            Picker("Show Links", selection: linkVisibility) {
                ForEach(CanvasLinkVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Button("Pause All Links", systemImage: "pause.circle") {
                CanvasLiveBridge.shared.pauseAll(in: board)
            }
            .disabled(!board.connections.contains { $0.behavior == .session })
            Button("Resume All Links", systemImage: "play.circle") {
                CanvasLiveBridge.shared.resumeAll(in: board)
            }
            .disabled(!board.connections.contains { $0.behavior == .session })
            CanvasDiagramMenuItems(board: board, session: session)  // X9 diagrams
            Divider()
            Button("Close Ensemble", systemImage: "xmark") { session.closeCanvas(board.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .tint(theme.palette.textSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Ensemble actions")
        .accessibilityLabel("Ensemble actions")
    }

    private var linkVisibility: Binding<CanvasLinkVisibility> {
        Binding(get: { board.linkVisibility }, set: { board.linkVisibility = $0 })
    }
}

/// "−  100% ⌄  +" in one capsule (review C10). Button and menu zoom animate;
/// pinch and scroll stay 1:1.
struct CanvasZoomCapsule: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState

    var body: some View {
        HStack(spacing: 0) {
            Button {
                board.zoom(1 / 1.2)
            } label: {
                Label("Zoom Out", systemImage: "minus")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 11))
            .help("Zoom Out")
            Menu {
                Button("Zoom to Fit") { board.fitAll() }
                Button("Zoom to Selection") { board.zoomToSelection() }
                    .disabled(board.selection.isEmpty)
                Button("Actual Size") { board.actualSize() }
                Divider()
                Button("50%") { board.zoom(toScale: 0.5) }
                Button("200%") { board.zoom(toScale: 2) }
            } label: {
                HStack(spacing: 3) {
                    Text(board.viewport.scale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .frame(minWidth: 50, minHeight: 24)
                .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .tint(theme.palette.textSecondary)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom: fit, selection, actual size")
            .accessibilityLabel("Zoom")
            .accessibilityValue(
                board.viewport.scale.formatted(.percent.precision(.fractionLength(0))))
            Button {
                board.zoom(1.2)
            } label: {
                Label("Zoom In", systemImage: "plus")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 11))
            .help("Zoom In")
        }
        .padding(.horizontal, 3)
        .frame(height: 28)
        .background(Capsule().fill(theme.palette.elevatedBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .fixedSize()
    }
}
