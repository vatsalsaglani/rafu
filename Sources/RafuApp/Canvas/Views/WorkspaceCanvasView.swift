import AppKit
import SwiftUI

private struct CanvasPresentationKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var canvasPresentationID: UUID? {
        get { self[CanvasPresentationKey.self] }
        set { self[CanvasPresentationKey.self] = newValue }
    }
}

struct WorkspaceCanvasView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    let board: CanvasBoardState
    let session: WorkspaceSession
    @State private var connectionDrag = CanvasConnectionDrag()
    @State private var interaction = CanvasInteractionState()
    @State private var pan = CanvasBoardPan()
    @State private var magnifyStart: CanvasViewport?
    @State private var magnifyLastScale = 1.0
    @State private var marqueeStart: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var presentationID = UUID()
    @State private var spaceIsDown = false
    /// True from a background drag's first change to its end OR cancel, one
    /// per attachment (grid, board). SwiftUI resets gesture state on cancel
    /// too (a mask flip, a view change), where `onEnded` never runs; when
    /// neither is live the pan ends, so it never stays "active" with a stuck
    /// grab pointer. Two states, so a mask flip that hands a live drag from
    /// one attachment to the other does not end it.
    @GestureState private var gridDragIsLive = false
    @GestureState private var boardDragIsLive = false
    @FocusState private var boardHasKeyboardFocus: Bool
    /// Ensemble ▸ Show Overview: keeps the board overview on screen.
    @AppStorage(CanvasOverviewPreference.pinnedKey) private var overviewPinned = false
    @State private var showsRestoredLinksNotice = false
    /// Rotor targets: every rendered card shell registers here, so the
    /// "Cards" rotor gives VoiceOver the list-like path the List view had.
    @Namespace private var cardRotorNamespace

    private var pausedLinkCount: Int {
        CanvasLiveBridge.shared.linkStates(in: board).values.count { $0.kind == .paused }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Save failures only. Every other message is the board notice
            // under the tool palette (`CanvasBoardNoticeView`).
            if let message = board.saveFailureMessage {
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button("Save Again") { session.saveCanvas(board.id) }
                    Button("Save Copy") { session.saveCanvasCopy(board.id) }
                    Button("Reload…") { session.requestCanvasReload(board.id) }
                }
                .padding(10)
                .background(theme.palette.sidebarBackground)
            }
            CanvasBar(
                board: board, session: session, interaction: interaction,
                focusBoard: { boardHasKeyboardFocus = true })
            Divider()
            // The board is the only surface. The restored-links notice stacks
            // below the tool palette (`boardTopOverlay`).
            boardSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .top) {
                    CanvasFindOverlay(board: board, session: session)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.editorBackground)
        .environment(\.canvasPresentationID, presentationID)
        .environment(interaction)
        .background(
            CanvasScrollBridge(
                isEnabled: false, pan: { _, _ in }, zoom: { _, _ in },
                hidden: { session.canvasResources[board.id]?.pause() },
                visible: { session.canvasResources[board.id]?.windowBecameAvailable() })
        )
        .background(
            CanvasReturnKeyMonitor(isActive: board.contentIsActive) {
                board.backToBoard()
                boardHasKeyboardFocus = true
            }
        )
        .background(
            CanvasEdgeDeleteKeyMonitor(
                isActive: edgeDeleteKeyIsActive,
                perform: { board.deleteSelectedConnectionIfAny() })
        )
        .onChange(of: board.changeStamp) { _, _ in session.canvasResources[board.id]?.prune() }
        .onChange(of: board.contentIsActive) { wasActive, isActive in
            // Leaving content by any route (menu, palette, button) returns keys to the board.
            if wasActive, !isActive { boardHasKeyboardFocus = true }
            board.attentionFocusChanged()
        }
        // Tidy Up reads focus time. Only these coarse transitions feed it.
        .onChange(of: board.focusedCardID) { _, _ in board.attentionFocusChanged() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) {
            _ in
            board.suspendAttention()
            session.flushCanvasAttention(board)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) {
            _ in
            board.resumeAttention()
            // A drag that ended in another app cannot leave a preview behind.
            board.clearDropPreview()
        }
        // Last safety net for the hover preview: some drag destinations
        // under the board (a card's text view, the editor group) can end a
        // session without telling either drop half. A drag always holds the
        // primary button, so once it is up the preview is stale.
        .task(id: board.dropPreview != nil) {
            while board.dropPreview != nil {
                do {
                    try await Task.sleep(
                        for: CanvasDropPreviewWatchdog.interval,
                        tolerance: CanvasDropPreviewWatchdog.tolerance)
                } catch {
                    return
                }
                if CanvasDropPreviewWatchdog.dragHasEnded(
                    pressedMouseButtons: NSEvent.pressedMouseButtons)
                {
                    board.clearDropPreview()
                }
            }
        }
        .canvasAssetImportConsent(board: board, session: session)
        .onAppear {
            session.canvasResources[board.id]?.present(owner: presentationID)
            // A reopened board restores message links Paused; say so once.
            showsRestoredLinksNotice = pausedLinkCount > 0
            if NSApplication.shared.isActive { board.resumeAttention() }
        }
        .onDisappear {
            board.clearDropPreview()
            board.suspendAttention()
            session.flushCanvasAttention(board)
            connectionDrag.reset()
            session.canvasResources[board.id]?.hide(owner: presentationID)
        }
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scale(scale: 0.96).combined(with: .opacity),
                removal: .scale(scale: 0.98).combined(with: .opacity))
    }

    private var boardSurface: some View {
        GeometryReader { geometry in
            boardKeys(boardChrome(boardLayers(geometry), geometry: geometry))
        }
        // VoiceOver's list-like path through the board: every card by its
        // display title. Choosing one selects it and scrolls it into view;
        // off-screen cards are not rendered, so `prepare` reveals first.
        .accessibilityRotor("Cards") {
            ForEach(board.cards) { card in
                AccessibilityRotorEntry(
                    Text(
                        CanvasCardPresentation.displayTitle(
                            title: card.title, content: card.content)),
                    id: card.id, in: cardRotorNamespace
                ) {
                    board.select([card.id])
                    board.revealCard(card.id)
                }
            }
        }
    }

    /// The only card a connection drag may drop on, or nil.
    private var validConnectionTarget: CanvasCardID? {
        guard let source = connectionDrag.source,
            let target = connectionDrag.target(in: board.cards, viewport: board.viewport),
            board.canConnect(from: source, to: target)
        else { return nil }
        return target
    }

    /// Stage 1: the grid, edges, cards, overlays and the board coordinate space.
    private func boardLayers(_ geometry: GeometryProxy) -> some View {
        // Only a valid target gets the shell's outline; invalid ones are dimmed
        // by the edge overlay.
        let connectionTarget = validConnectionTarget
        return ZStack(alignment: .topLeading) {
            // Pan and marquee have one owner at a time: this grid gesture for
            // a plain drag, or the board's high-priority gesture while Space
            // is held or the Hand tool is on (see `boardChrome`). The masks
            // never enable both.
            grid
                .contentShape(.rect)
                .gesture(
                    backgroundDrag(live: $gridDragIsLive),
                    including: panOverridesCards ? .subviews : .all
                )
                .onTapGesture {
                    board.backToBoard()
                    boardHasKeyboardFocus = true
                    board.selection = []
                    board.clearConnectionSelection()
                }
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        interaction.addPopoverBoardPoint = unproject(value.location)
                        interaction.addPopoverAnchor = value.location
                    }
                )
                .pointerStyle(pan.isPanning ? .grabActive : .grabIdle)
            // An empty board's first moves, on the board itself. After the
            // grid, so pan and double-click still work around the seeds.
            if board.cards.isEmpty, board.dropPreview == nil {
                CanvasSeedLayer(board: board, session: session, interaction: interaction)
            }
            CanvasEdgeLayer(
                board: board, session: session, focusBoard: { boardHasKeyboardFocus = true })
            ForEach(visibleCards(in: geometry.size)) { card in
                CanvasCardShell(
                    card: card, board: board, session: session,
                    focusBoard: { boardHasKeyboardFocus = true },
                    isConnectionTarget: connectionTarget == card.id,
                    updateConnectionDrag: { source, point in
                        if connectionDrag.source == nil {
                            board.backToBoard()
                            boardHasKeyboardFocus = true
                        }
                        connectionDrag.update(from: source, at: point)
                    },
                    finishConnectionDrag: { source, point in
                        if let drop = connectionDrag.finish(
                            from: source, at: point, cards: board.cards,
                            viewport: board.viewport)
                        {
                            session.connectCanvasCards(
                                boardID: board.id, from: drop.from, to: drop.to)
                        }
                    },
                    cancelConnectionDrag: { source in
                        if connectionDrag.source == source { connectionDrag.reset() }
                    }
                )
                .modifier(
                    CanvasCardPlacement(
                        id: card.id, rect: card.rect, viewport: board.viewport,
                        live: board.liveGeometry)
                )
                .transition(cardTransition)
                .accessibilityRotorEntry(id: card.id, in: cardRotorNamespace)
            }
            CanvasSetDownRing(board: board)
            CanvasEdgeOverlay(board: board, session: session, drag: connectionDrag)
            // X5 whiteboard
            CanvasWhiteboardCreationLayer(
                board: board, tool: .forBoard(board.id), viewportProject: project,
                unproject: unproject)
            // Its own view: guides change on many drag frames, and only this
            // layer reads them, so the board body does not re-run with them.
            CanvasSnapGuideLayer(interaction: interaction, viewport: board.viewport)
            if let marquee = interaction.marquee {
                Rectangle().stroke(theme.palette.accent, lineWidth: 1)
                    .background(theme.palette.accent.opacity(0.08))
                    .frame(width: marquee.width, height: marquee.height)
                    .offset(x: marquee.minX, y: marquee.minY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            if let dropPreview = board.dropPreview {
                dropPreviewOverlay(dropPreview, in: geometry.size)
                    .animation(
                        RafuMotion.resolve(RafuMotion.targetHighlight, reduceMotion: reduceMotion),
                        value: dropPreview)
            }
            // The tool palette is NOT a layer here: it is an overlay of the
            // gesture-carrying board (`boardChrome`), so no board gesture
            // (pan, Hand, drawing tool, magnify) can take a palette click.
        }
        // Hand: grab over the whole board, cards included (nil otherwise).
        .pointerStyle(
            CanvasBoardPanRouting.pointer(tool: toolKind, isPanning: pan.isPanning)?.style
        )
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        .coordinateSpace(name: CanvasConnectionCoordinateSpace.board)
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            board.visibleSize = $0
            // The first real size fits a board that would open with nothing
            // in view (UX Round A, B1). Runs once per board object.
            board.arriveIfNeeded()
        }
        // A reload installs a new board object under the same view identity
        // (`.id(board.id)`); the size does not change, so hand it over here.
        .onChange(of: ObjectIdentifier(board)) { _, _ in
            board.visibleSize = geometry.size
            board.arriveIfNeeded()
        }
        // `clipped()` clips drawing only. Without the content shape, a card
        // that extends past the board edge still takes clicks meant for the
        // sidebar, the tab bar, or other chrome painted over it.
        .clipped()
        .contentShape(.rect)
    }

    /// Stage 2: popover, drop, scroll and magnify bridges, zoom capsule, focus.
    private func boardChrome(_ content: some View, geometry: GeometryProxy) -> some View {
        content
            .popover(
                isPresented: Binding(
                    get: { interaction.addPopoverAnchor != nil },
                    set: { if !$0 { interaction.addPopoverAnchor = nil } }),
                attachmentAnchor: .rect(
                    .rect(
                        CGRect(
                            origin: interaction.addPopoverAnchor ?? .zero,
                            size: CGSize(width: 1, height: 1)))),
                arrowEdge: .bottom
            ) {
                CanvasAddPopover(
                    board: board, session: session,
                    boardPoint: interaction.addPopoverBoardPoint,
                    dismiss: { interaction.addPopoverAnchor = nil })
            }
            .onDrop(
                of: [.rafuEnsembleDrag, .rafuEditorDrag, .fileURL],
                delegate: CanvasFileDropDelegate(
                    boardID: board.id, session: session, surfaceSize: geometry.size)
            )
            .background(
                CanvasScrollBridge(
                    isEnabled: true,
                    capturesScroll: { point in
                        guard board.contentIsActive, let card = board.focusedCard else {
                            return true
                        }
                        // The body starts below the 32 pt header and its hairline.
                        let origin = project(CGPoint(x: card.rect.x, y: card.rect.y + 33))
                        return !CGRect(
                            origin: origin,
                            size: CGSize(
                                width: card.rect.width * board.viewport.scale,
                                height: (card.rect.height - 33) * board.viewport.scale)
                        ).contains(point)
                    },
                    pan: { dx, dy in
                        var viewport = board.viewport
                        viewport.x = min(100_000, max(-100_000, viewport.x - dx))
                        viewport.y = min(100_000, max(-100_000, viewport.y - dy))
                        board.setViewport(viewport)
                        interaction.holdOverviewAfterPan()
                    },
                    zoom: { factor, point in
                        setScale(
                            board.viewport.scale * factor, from: board.viewport,
                            size: geometry.size, anchor: point)
                    },
                    hidden: {},
                    drop: CanvasFileDrop.target(boardID: board.id, session: session)
                )
            )
            // Space-drag and the Hand tool pan over cards too. Otherwise this
            // mask disables the gesture and leaves the grid's own pan
            // gesture in charge. A click (no movement) still reaches cards.
            .highPriorityGesture(
                backgroundDrag(live: $boardDragIsLive),
                including: panOverridesCards ? .all : .subviews
            )
            .gesture(
                MagnifyGesture().onChanged { value in
                    if magnifyStart == nil {
                        magnifyStart = board.viewport
                        magnifyLastScale = board.viewport.scale
                    }
                    guard let start = magnifyStart else { return }
                    // Hand zoom stops at 25 % (B2); Fit may have gone lower.
                    let raw = CanvasZoomMetrics.interactiveClamped(
                        start.scale * value.magnification, from: start.scale)
                    if CanvasZoomDetent.crossed(from: magnifyLastScale, to: raw) {
                        RafuHaptics.alignment(channel: "zoom")
                    }
                    magnifyLastScale = raw
                    setScale(
                        CanvasZoomDetent.apply(raw), from: start, size: geometry.size,
                        anchor: value.startLocation)
                }.onEnded { _ in magnifyStart = nil }
            )
            .overlay(alignment: .bottomTrailing) { zoomCorner }
            // Above every board layer and outside every board gesture, in
            // every tool. A wide bar hosts the palette instead (UX Round C).
            .overlay(alignment: .top) { boardTopOverlay }
            // The palette's letter keys belong to the board, so they work
            // with the palette floating here or hosted in the bar. The
            // monitor reads the board's own focus state, never `isFocused`.
            .background(
                CanvasToolKeyMonitor(
                    isActive: CanvasToolKeyHandler.keysActive(
                        boardFocused: boardHasKeyboardFocus, board: board)
                ) { key in
                    CanvasToolKeyHandler.handle(
                        key, tool: .forBoard(board.id), board: board, session: session)
                }
            )
            .onChange(of: gridDragIsLive || boardDragIsLive) { _, live in
                if !live { endBackgroundDrag() }
            }
            // The board takes keys, but it is a surface, not a control: the
            // system focus ring would outline the whole board (and spill over
            // the sidebar). Cards draw their own gold content-focus stroke.
            .focusable()
            .focusEffectDisabled()
            .focused($boardHasKeyboardFocus)
            .onChange(of: boardHasKeyboardFocus) { _, focused in if !focused { spaceIsDown = false }
            }
    }

    /// Board shortcuts apply only while no card content and no inline title
    /// field has the keys. Otherwise Return, Space, Delete, arrows, Tab and
    /// the letter shortcuts reach the board before the field: Return opened
    /// the card instead of saving the new name.
    private var boardTakesKeys: Bool {
        CanvasInlineRename.boardTakesKeys(
            contentIsActive: board.contentIsActive, renamingCardID: board.renamingCardID,
            isFindPresented: board.isFindPresented)
    }

    /// Delete reaches a selected edge even when the board has no keyboard
    /// focus (`CanvasEdgeDeleteKeyMonitor`), but only on the focused board and
    /// never while its label popover is open.
    private var edgeDeleteKeyIsActive: Bool {
        board.selectedConnectionID != nil && board.labelEditorConnectionID == nil
            && boardTakesKeys && session.selectedCanvasID == board.id
    }

    /// Stage 3: keyboard handling for the board.
    private func boardKeys(_ content: some View) -> some View {
        content
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { event in
                guard boardTakesKeys else { return .ignored }
                spaceIsDown = event.phase != .up
                return .handled
            }
            .onKeyPress("z", phases: .down) { event in
                guard boardTakesKeys, event.modifiers.contains(.command) else {
                    return .ignored
                }
                if event.modifiers.contains(.shift) {
                    board.performRedo()
                } else {
                    board.performUndo()
                }
                return .handled
            }
            .onKeyPress("a", phases: .down) { event in
                guard boardTakesKeys, event.modifiers == .command else { return .ignored }
                board.select(Set(board.cards.map(\.id)))
                return .handled
            }
            .onKeyPress("n", phases: .down) { event in
                guard boardTakesKeys, event.modifiers.isEmpty else { return .ignored }
                CanvasAddKind.note.perform(on: board, session: session, animated: false)
                return .handled
            }
            .onKeyPress("t", phases: .down) { event in
                guard boardTakesKeys, event.modifiers.isEmpty else { return .ignored }
                CanvasAddKind.terminal.perform(on: board, session: session, animated: false)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard boardTakesKeys else { return .ignored }
                if board.deleteSelectedConnectionIfAny() { return .handled }
                guard session.canCloseSelectedCanvasNodes else { return .ignored }
                session.closeSelectedCanvasNodes()
                return .handled
            }
            // Edit > Delete (and any other delete command routed to the
            // focused board) does the same as the Delete key.
            .onDeleteCommand {
                guard boardTakesKeys else { return }
                if board.deleteSelectedConnectionIfAny() { return }
                if session.canCloseSelectedCanvasNodes { session.closeSelectedCanvasNodes() }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
                guard boardTakesKeys else { return .ignored }
                return arrowKey(event) ? .handled : .ignored
            }
            .onKeyPress(.return, phases: .down) { event in
                guard boardTakesKeys, board.selection.count == 1,
                    let id = board.selection.first
                else { return .ignored }
                if event.modifiers == .option {
                    // Option-Return: Zoom to Card.
                    board.zoomToCard(id)
                    return .handled
                }
                guard event.modifiers.isEmpty else { return .ignored }
                enterContent(of: id, zoomingIfNeeded: true)
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { event in
                guard boardTakesKeys else { return .ignored }
                let forward = !event.modifiers.contains(.shift)
                let current = board.selection.count == 1 ? board.selection.first : nil
                guard
                    let next = CanvasLayoutMath.neighbour(
                        of: current, in: board.cards, forward: forward)
                else { return .ignored }
                board.select([next])
                board.revealCard(next)
                return .handled
            }
            .onKeyPress(.escape) {
                if connectionDrag.source != nil {
                    connectionDrag.cancel()
                    return .handled
                }
                guard boardTakesKeys else { return .ignored }
                if board.notice != nil {
                    board.dismissNotice()
                    return .handled
                }
                board.selection = []
                board.clearConnectionSelection()
                board.connectingFrom = nil
                return .handled
            }
    }

    /// The X5 whiteboard tool palette and, below it, the paused-links notice.
    /// Both are top-centre overlays; one stack keeps the notice under the
    /// palette at every board width, so they never overlap. A wide bar hosts
    /// the palette (`CanvasBarLayout`); then the notices start at the top.
    private var boardTopOverlay: some View {
        VStack(spacing: CanvasBoardTopOverlayMetrics.spacing) {
            if !interaction.paletteHostedInBar {
                CanvasToolPalette(
                    board: board, session: session, tool: .forBoard(board.id),
                    focusBoard: { boardHasKeyboardFocus = true })
            }
            // A compact capsule over the board, not a full-width strip.
            if showsRestoredLinksNotice && pausedLinkCount > 0 {
                pausedLinksNotice
                    .transition(.opacity)
            }
            CanvasBoardNoticeView(board: board)
        }
        .padding(.top, CanvasBoardTopOverlayMetrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "1 link paused · Resume Links ×" as one compact capsule at the top of
    /// the board. Shape and words carry the state, not colour.
    private var pausedLinksNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(pausedLinkCount == 1 ? "1 link paused" : "\(pausedLinkCount) links paused")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
            Text("·").foregroundStyle(theme.palette.textMuted).accessibilityHidden(true)
            Button("Resume Links") {
                CanvasLiveBridge.shared.resumeAll(in: board)
                showsRestoredLinksNotice = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.palette.textPrimary)
            .help("Resume every paused link on this Ensemble")
            Button {
                showsRestoredLinksNotice = false
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 9))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(Capsule().fill(theme.palette.elevatedBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    /// The board's hover drop preview (UX Round A, B5). Accept and refuse
    /// differ by shape, glyph and cursor, not by hue alone:
    /// - accept: a solid ring ghost (or one per card of a batch) with the
    ///   kind's glyph and the file name, and the label pill below it;
    /// - refuse (warn tone): no ghost and no outline, a 3 pt bar on the
    ///   board's top edge, and an octagon pill below the tool palette;
    /// - a tab split: the edge band, unchanged.
    /// Rects are board-space; they are projected through the viewport here
    /// (`project`), so a ghost and the drop it describes never disagree.
    @ViewBuilder
    private func dropPreviewOverlay(_ preview: CanvasDropPreview, in size: CGSize) -> some View {
        switch preview.shape {
        case .card(let rect):
            dropGhost(rect, preview: preview, isFirst: true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        case .cards(let rects):
            // The label already says the count; at most 24 ghosts draw.
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.prefix(24).enumerated()), id: \.offset) { index, rect in
                    dropGhost(rect, preview: preview, isFirst: index == 0)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .edge(let edge):
            ZStack(alignment: edgeAlignment(edge)) {
                edgeBand(edge, color: theme.palette.accent, in: size)
                dropPreviewLabel(preview.label)
                    .padding(14)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .board where preview.tone == .warn:
            // The refusal is read aloud by the notice path, not here.
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(theme.palette.warning)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
                dropRefusalPill(preview.label)
                    .padding(
                        .top,
                        CanvasBoardTopOverlayMetrics.belowPalette(
                            hosted: interaction.paletteHostedInBar))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        case .board:
            // A tab moving into the editor group under the board.
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.palette.accent.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.palette.accent, lineWidth: ringWidth)
                    )
                    .padding(6)
                dropPreviewLabel(preview.label)
                    .padding(
                        .top,
                        CanvasBoardTopOverlayMetrics.belowPalette(
                            hosted: interaction.paletteHostedInBar))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The accept ring: 1.5 pt, 2.5 pt under Increase Contrast. Solid, so
    /// it never reads as the old dashed "maybe".
    private var ringWidth: CGFloat { contrast == .increased ? 2.5 : 1.5 }

    /// One ghost card at `rect` (board units): the solid accept ring, the
    /// glyph, the name on the first ghost when it fits, and the label pill
    /// below the first ghost.
    private func dropGhost(_ rect: CGRect, preview: CanvasDropPreview, isFirst: Bool)
        -> some View
    {
        let origin = project(rect.origin)
        let width = rect.width * board.viewport.scale
        let height = rect.height * board.viewport.scale
        let name = isFirst && width >= 120 ? preview.name : nil
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.palette.accent.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.palette.accent, lineWidth: ringWidth)
            )
            .overlay {
                VStack(spacing: 6) {
                    if let glyph = preview.glyph, height >= 36 {
                        Image(systemName: glyph)
                            .font(.system(size: 20))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    if let name {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                if isFirst {
                    dropPreviewLabel(preview.label)
                        .alignmentGuide(.bottom) { $0[.top] - 8 }
                }
            }
            .offset(x: origin.x, y: origin.y)
    }

    /// The accept label: the accent capsule.
    private func dropPreviewLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.palette.onAccent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(theme.palette.accent))
            .fixedSize()
    }

    /// The refusal pill: an octagon glyph in the warning hue and the reason
    /// in primary text on the card surface. Shape and words carry the state.
    private func dropRefusalPill(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.warning)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(theme.palette.cardBackground))
        .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
        .fixedSize()
    }

    /// The zoom capsule and, above it, the board overview (B3). The overview
    /// shows while the pointer is over this corner, while a pan runs and a
    /// moment after it, or always with Show Overview. It hides during a drop
    /// and on an empty board.
    private var zoomCorner: some View {
        let showsOverview =
            !board.cards.isEmpty && board.dropPreview == nil
            && (overviewPinned || interaction.overviewHover || pan.isPanning
                || interaction.overviewPanHold)
        return VStack(alignment: .trailing, spacing: 8) {
            if showsOverview {
                CanvasMinimapView(board: board)
                    .transition(.opacity)
            }
            CanvasZoomCapsule(board: board)
        }
        .contentShape(.rect)
        .onHover { interaction.overviewHover = $0 }
        .padding(12)
        .animation(
            RafuMotion.resolve(RafuMotion.panelToggle, reduceMotion: reduceMotion),
            value: showsOverview)
    }

    /// A thin band along one edge of a `size` surface, for the "this tab
    /// will split here" preview.
    private func edgeBand(_ edge: EditorSplitEdge, color: Color, in size: CGSize) -> some View {
        let thickness: CGFloat = 10
        let rect: CGRect
        switch edge {
        case .leading: rect = CGRect(x: 0, y: 0, width: thickness, height: size.height)
        case .trailing:
            rect = CGRect(x: size.width - thickness, y: 0, width: thickness, height: size.height)
        case .top: rect = CGRect(x: 0, y: 0, width: size.width, height: thickness)
        case .bottom:
            rect = CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness)
        }
        return Rectangle()
            .fill(color.opacity(0.5))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func edgeAlignment(_ edge: EditorSplitEdge) -> Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// Arrow keys move the selection 8 pt (Shift: 40 pt). Option-Command with
    /// an arrow resizes the one selected card instead.
    private func arrowKey(_ event: KeyPress) -> Bool {
        let step = event.modifiers.contains(.shift) ? 40.0 : 8.0
        var dx = 0.0
        var dy = 0.0
        switch event.key {
        case .leftArrow: dx = -1
        case .rightArrow: dx = 1
        case .upArrow: dy = -1
        case .downArrow: dy = 1
        default: return false
        }
        if event.modifiers.contains(.command), event.modifiers.contains(.option) {
            guard board.selection.count == 1 else { return false }
            session.performCanvasEdit(board) { try board.resizeSelection(dw: dx * 8, dh: dy * 8) }
            return true
        }
        guard !board.selection.isEmpty else { return false }
        session.performCanvasEdit(board) { try board.moveSelection(dx: dx * step, dy: dy * step) }
        return true
    }

    /// Return on a selected card. A stopped terminal starts its shell (an
    /// explicit key press); other cards take keyboard focus. Below 50% zoom
    /// the card first fills the view, because its content is not shown.
    private func enterContent(of id: CanvasCardID, zoomingIfNeeded: Bool) {
        guard let card = board.cards.first(where: { $0.id == id }) else { return }
        if zoomingIfNeeded, !CanvasZoomFace(scale: board.viewport.scale).showsLiveContent {
            board.zoomToCard(id)
        }
        if case .note = card.content,
            let model = CanvasCardCommands(card: card, board: board, session: session).noteModel
        {
            // Return on a selected note starts editing (Zoom to Card first below 50%).
            if model.beginEditing() { return }
        }
        // Return on a selected whiteboard item or Mermaid card opens its editor.
        if case .mermaid = card.content {
            CanvasWhiteboardEditing.shared.request(card.id)
            return
        }
        if CanvasWhiteboardEditing.shared.requestEditing(card) { return }
        if case .terminal = card.content,
            let primary = CanvasCardCommands(card: card, board: board, session: session).primary,
            primary.id == "start" || primary.id == "restart"
        {
            primary.perform()
        }
        board.focus(id)
        board.clearConnectionSelection()
    }

    /// The dot grid is the only thing that moves when an empty board pans.
    /// Read the viewport here, in `body`, not inside the `Canvas` renderer:
    /// the renderer runs outside Observation tracking, so a viewport read
    /// only there never re-renders the grid and an empty board looked frozen.
    private var grid: some View {
        let viewport = board.viewport
        let dot = theme.palette.textSecondary.opacity(0.25)
        return Canvas { context, size in
            let spacing = max(12, 24 * viewport.scale)
            let ox = viewport.x.truncatingRemainder(dividingBy: spacing)
            let oy = viewport.y.truncatingRemainder(dividingBy: spacing)
            for x in stride(from: ox - spacing, through: size.width, by: spacing) {
                for y in stride(from: oy - spacing, through: size.height, by: spacing) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(dot))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var toolKind: CanvasWhiteboardToolKind { CanvasWhiteboardTool.forBoard(board.id).kind }

    /// Space held or the Hand tool on: the board's pan wins over cards.
    private var panOverridesCards: Bool {
        CanvasBoardPanRouting.panOverridesCards(spaceIsDown: spaceIsDown, tool: toolKind)
    }

    /// Drag on the background pans. Shift-drag draws a marquee and selects
    /// live (not with the Hand tool, which only pans). `live` is this
    /// attachment's gesture state (see `gridDragIsLive`).
    private func backgroundDrag(live: GestureState<Bool>) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating(live) { _, isLive, _ in isLive = true }
            .onChanged { value in
                // A new start point is a new drag. SwiftUI may not call onEnded
                // when a gesture mask flips mid-drag (Space pressed or released);
                // without this reset the next drag would pan from a stale start.
                if dragOrigin != value.startLocation {
                    dragOrigin = value.startLocation
                    pan.end()
                    marqueeStart = nil
                    interaction.marquee = nil
                }
                if !pan.isPanning && marqueeStart == nil {
                    if NSEvent.modifierFlags.contains(.shift) && !panOverridesCards {
                        marqueeStart = value.startLocation
                    } else {
                        pan.begin(from: board.viewport)
                        // A Hand pan that starts over a card keeps the keys
                        // on the board, so Escape and V still leave Hand.
                        if panOverridesCards { boardHasKeyboardFocus = true }
                    }
                }
                if let start = marqueeStart {
                    let marquee = CGRect(
                        x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                        width: abs(start.x - value.location.x),
                        height: abs(start.y - value.location.y))
                    interaction.marquee = marquee
                    let hits = Set(
                        board.cards.filter { card in
                            marquee.intersects(
                                CGRect(
                                    origin: project(CGPoint(x: card.rect.x, y: card.rect.y)),
                                    size: CGSize(
                                        width: card.rect.width * board.viewport.scale,
                                        height: card.rect.height * board.viewport.scale)))
                        }.map(\.id))
                    if hits != board.selection { board.select(hits) }
                } else if let next = pan.viewport(for: value.translation) {
                    board.setViewport(next)
                }
            }
            .onEnded { _ in endBackgroundDrag() }
    }

    /// Ends a pan or marquee. Runs on mouse-up (`onEnded`), and also when
    /// SwiftUI cancels the drag without `onEnded` (both drag states reset), so a pan and the grab pointer never stay stuck.
    private func endBackgroundDrag() {
        interaction.marquee = nil
        marqueeStart = nil
        // The overview stays a moment after a pan (B3).
        if pan.isPanning { interaction.holdOverviewAfterPan() }
        pan.end()
        dragOrigin = nil
    }

    private func project(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * board.viewport.scale + board.viewport.x,
            y: point.y * board.viewport.scale + board.viewport.y)
    }

    private func unproject(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - board.viewport.x) / board.viewport.scale,
            y: (point.y - board.viewport.y) / board.viewport.scale)
    }

    private func visibleCards(in size: CGSize) -> [CanvasCard] {
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        return board.cards.filter {
            visible.intersects(
                CGRect(
                    origin: project(CGPoint(x: $0.rect.x, y: $0.rect.y)),
                    size: CGSize(
                        width: $0.rect.width * board.viewport.scale,
                        height: $0.rect.height * board.viewport.scale)))
        }
    }

    /// Pinch and scroll zoom set the viewport directly, 1:1 with the pointer.
    /// Both stop at the hand-zoom floor (25 %).
    private func setScale(
        _ scale: Double, from start: CanvasViewport, size: CGSize, anchor: CGPoint? = nil
    ) {
        let scale = CanvasZoomMetrics.interactiveClamped(scale, from: start.scale)
        board.setViewport(
            CanvasZoomMetrics.viewport(scaling: start, to: scale, in: size, anchor: anchor))
    }
}

/// Places one card on the board: its size, the zoom and its position. It
/// reads the live rect of a move or resize (`CanvasLiveGeometry`), so a drag
/// frame re-runs this small modifier for each card. It never re-runs the
/// card's own body or the board's: a modifier's `content` is not re-evaluated
/// when only the modifier body runs. The frame is top-leading: should a card
/// ever report more than its rect, it overflows downward, so its header and
/// top border stay on the rect that edges and ports are computed from.
struct CanvasCardPlacement: ViewModifier {
    let id: CanvasCardID
    let rect: CanvasRect
    let viewport: CanvasViewport
    let live: CanvasLiveGeometry

    func body(content: Content) -> some View {
        let shown = live.rect(for: id) ?? rect
        content
            .frame(width: shown.width, height: shown.height, alignment: .topLeading)
            .scaleEffect(viewport.scale, anchor: .topLeading)
            .offset(
                x: shown.x * viewport.scale + viewport.x,
                y: shown.y * viewport.scale + viewport.y
            )
    }
}

/// The snap guides of a card drag, drawn in board-surface points.
private struct CanvasSnapGuideLayer: View {
    @Environment(\.rafuTheme) private var theme
    let interaction: CanvasInteractionState
    let viewport: CanvasViewport

    var body: some View {
        ForEach(interaction.guides, id: \.key) { guide in
            guideLine(guide)
        }
    }

    private func guideLine(_ guide: CanvasSnapGuide) -> some View {
        let scale = viewport.scale
        let isVertical = guide.axis == .vertical
        let point =
            isVertical
            ? CGPoint(x: guide.position, y: guide.start)
            : CGPoint(x: guide.start, y: guide.position)
        let origin = CGPoint(
            x: point.x * scale + viewport.x, y: point.y * scale + viewport.y)
        let length = (guide.end - guide.start) * scale
        return Rectangle()
            .fill(theme.palette.accent)
            .frame(width: isVertical ? 1 : length, height: isVertical ? length : 1)
            .offset(x: origin.x - (isVertical ? 0.5 : 0), y: origin.y - (isVertical ? 0 : 0.5))
            .transition(.opacity)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// When a drop preview is stale: no drag runs without the primary button.
nonisolated enum CanvasDropPreviewWatchdog {
    static let interval: Duration = .milliseconds(500)
    static let tolerance: Duration = .milliseconds(100)

    static func dragHasEnded(pressedMouseButtons: Int) -> Bool {
        pressedMouseButtons & 1 == 0
    }
}

/// Spacing of the board's top-centre overlay stack: the tool palette, then
/// the paused-links notice.
nonisolated enum CanvasBoardTopOverlayMetrics {
    static let topInset: CGFloat = 10
    static let spacing: CGFloat = 8
    /// The tool palette's height: 26 pt buttons and 4 pt padding.
    static let paletteHeight: CGFloat = 34
    /// The first free line below the palette, for the drop labels. With the
    /// palette hosted in the bar it is the top inset.
    static func belowPalette(hosted: Bool) -> CGFloat {
        hosted ? topInset : topInset + paletteHeight + spacing
    }
}

/// Ensemble ▸ Show Overview (UX Round A, B3). One app-wide choice.
nonisolated enum CanvasOverviewPreference {
    static let pinnedKey = "canvasOverviewPinned"
}
