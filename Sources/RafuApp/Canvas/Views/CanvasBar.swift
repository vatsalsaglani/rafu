import SwiftUI

/// The width rule for the 30 pt Ensemble bar (UX Round C). Pure, so it is
/// unit-tested.
nonisolated enum CanvasBarLayout {
    static let height: CGFloat = 30
    /// The expanded tool palette (about 450 pt) plus the right-hand cluster
    /// (at most about 530 pt). From this width the palette sits in the bar.
    static let paletteHostWidth: CGFloat = 980

    static func hostsPalette(barWidth: CGFloat) -> Bool { barWidth >= paletteHostWidth }
}

/// The one 30 pt Ensemble bar: the tool palette when the bar is wide enough
/// (`CanvasBarLayout`), then the link status, the agent summary, Find, Add,
/// Arrange and Export. The board's name is on its tab only: rename,
/// duplicate, recents, Open Ensemble… and Close are in the tab's context menu
/// and the menu bar's Ensemble menu. There is no overflow menu.
struct CanvasBar: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    let interaction: CanvasInteractionState
    /// Gives the board keyboard focus; a palette tool choice calls it.
    var focusBoard: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            // A plain `if`, never animated: the placement only follows the
            // window width (Reduce Motion needs nothing more).
            if interaction.paletteHostedInBar {
                CanvasToolPalette(
                    board: board, session: session, tool: .forBoard(board.id),
                    focusBoard: focusBoard, placement: .hosted)
            }
            Spacer(minLength: 8)
            CanvasLinkStatusItem(board: board)
            CanvasAgentSummaryBar(board: board, session: session)
            findButton
            CanvasAddCardMenu(board: board, session: session)
            arrangeMenu
            exportButton
        }
        .padding(.horizontal, 12)
        .frame(height: CanvasBarLayout.height)
        .onGeometryChange(for: Bool.self) {
            CanvasBarLayout.hostsPalette(barWidth: $0.size.width)
        } action: { hosts in
            // Only a change writes, so a resize near the threshold does not
            // invalidate the board on every frame.
            if interaction.paletteHostedInBar != hosts { interaction.paletteHostedInBar = hosts }
        }
        // The tab's context menu and the Ensemble menu list recents.
        .task { await session.prepareCanvasLibrary() }
    }

    /// Find in Ensemble. The same state as the menu bar's Find in Ensemble…
    /// (⌘F) and the palette row; the board shows the palette
    /// (`CanvasFindOverlay`).
    private var findButton: some View {
        Button {
            board.isFindPresented.toggle()
        } label: {
            Label("Find in Ensemble", systemImage: "magnifyingglass")
        }
        .buttonStyle(RafuIconButtonStyle(isActive: board.isFindPresented, size: 24, iconSize: 13))
        .help("Find in Ensemble (⌘F)")
        .accessibilityLabel("Find in Ensemble")
    }

    /// The same action and disabled rule as the menu bar's Export….
    private var exportButton: some View {
        Button {
            CanvasDiagramPanels.showExport(
                board: board, session: session,
                target: board.selection.isEmpty ? .board : .selection)
        } label: {
            Label("Export Ensemble…", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 13))
        .disabled(board.cards.isEmpty || session.rootURL == nil)
        .help("Export Ensemble…")
        .accessibilityLabel("Export Ensemble…")
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
}

/// "−  100% ⌄  +  Fit" in one capsule (review C10, UX Round A B2). Button and
/// menu zoom animate and stop at 25 %; pinch and scroll stay 1:1. `Fit`
/// shows only while a card is out of view.
struct CanvasZoomCapsule: View {
    @Environment(\.rafuTheme) private var theme
    @AppStorage(CanvasOverviewPreference.pinnedKey) private var overviewPinned = false
    let board: CanvasBoardState

    var body: some View {
        // O(cards) on each viewport change; the percent already re-renders.
        let showsFit = CanvasArrival.anyCardOutOfView(
            cards: board.cards.map(\.rect), viewport: board.viewport,
            visible: board.visibleSize)
        HStack(spacing: 0) {
            Button {
                board.zoom(1 / 1.2)
            } label: {
                Label("Zoom Out", systemImage: "minus")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 11))
            .help("Zoom Out")
            .disabled(CanvasZoomMetrics.isAtInteractiveFloor(board.viewport.scale))
            Menu {
                Button("Zoom to Fit") { board.fitAll() }
                Button("Zoom to Selection") { board.zoomToSelection() }
                    .disabled(board.selection.isEmpty)
                Button("Actual Size") { board.actualSize() }
                Divider()
                Button("50%") { board.zoom(toScale: 0.5) }
                Button("200%") { board.zoom(toScale: 2) }
                Divider()
                Toggle("Show Overview", isOn: $overviewPinned)
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
            if showsFit {
                Button("Fit") { board.fitAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .contentShape(.rect)
                    .help("Zoom to Fit (⌘9)")
                    .accessibilityLabel("Zoom to Fit")
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 28)
        .background(Capsule().fill(theme.palette.elevatedBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .fixedSize()
    }
}
