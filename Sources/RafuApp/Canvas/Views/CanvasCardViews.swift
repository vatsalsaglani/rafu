import AppKit
import RafuCore
import SwiftUI

/// One card: a 32 pt header that moves it, a body that uses its content, no
/// footer (review 7.1). The header drags; the body never does.
struct CanvasCardShell: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.canvasPresentationID) private var presentationID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(CanvasInteractionState.self) private var interaction
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    var focusBoard: () -> Void = {}
    var isConnectionTarget = false
    var updateConnectionDrag: (CanvasCardID, CGPoint) -> Void = { _, _ in }
    var finishConnectionDrag: (CanvasCardID, CGPoint) -> Void = { _, _ in }
    var cancelConnectionDrag: (CanvasCardID) -> Void = { _ in }
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?
    @State private var isLifted = false
    @State private var isPressed = false
    @State private var moveOrigins: [CanvasCardID: CanvasRect] = [:]
    @State private var snappedX = false
    @State private var snappedY = false
    @State private var resizeStart: CanvasRect?
    @State private var frozenBodySize: CGSize?
    @State private var resizeHapticPlayed = false
    @State private var titleFrame = CGRect.zero

    private let cornerRadius: CGFloat = 8
    private let headerHeight: CGFloat = 32

    private var commands: CanvasCardCommands {
        CanvasCardCommands(card: card, board: board, session: session)
    }

    var body: some View {
        if isWhiteboardItem {
            whiteboardItem
        } else {
            standardCard
        }
    }

    private var standardCard: some View {
        let scale = board.viewport.scale
        let face = CanvasZoomFace(scale: scale)
        let selected = board.selection.contains(card.id)
        let contentFocused = board.contentIsActive && board.focusedCardID == card.id
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return faceContent(face, scale: scale, selected: selected, contentFocused: contentFocused)
            .background(theme.palette.elevatedBackground)
            .clipShape(shape)
            .background { surface(shape) }
            .overlay { border(shape, contentFocused: contentFocused) }
            .overlay { selectionRing(isOn: selected || isConnectionTarget) }
            .overlay { resizeOverlay(face, scale: scale, selected: selected) }
            .overlay { portsOverlay(scale: scale) }
            .onHover { inside in hoverChanged(inside) }
            .onDisappear { hideTask?.cancel() }
            .modifier(cardAccessibility(selected: selected))
    }

    /// A whiteboard item (shape, stroke, text) has no header or card surface:
    /// its face fills the frame and is itself the move handle. Selection,
    /// resize and ports stay the same as for every other card.
    private var whiteboardItem: some View {
        let scale = board.viewport.scale
        let selected = board.selection.contains(card.id)
        return CanvasWhiteboardCardFace(card: card, board: board)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(headerGesture)
            .contextMenu { CanvasCardMenuContent(card: card, board: board, session: session) }
            .overlay { selectionRing(isOn: selected || isConnectionTarget) }
            .overlay { resizeZones(scale: scale, selected: selected) }
            .overlay { portsOverlay(scale: scale) }
            .onHover { inside in hoverChanged(inside) }
            .onDisappear { hideTask?.cancel() }
            .modifier(cardAccessibility(selected: selected))
    }

    private func cardAccessibility(selected: Bool) -> CanvasCardAccessibility {
        CanvasCardAccessibility(
            card: card, board: board, session: session, label: accessibilityTitle,
            value: headerState ?? "", isSelected: selected)
    }

    /// The card kinds this shell draws itself. Every other kind (the
    /// whiteboard items) draws through `CanvasWhiteboardCardFace`; a Mermaid
    /// diagram keeps the standard header and uses the face as its body.
    private var isWhiteboardItem: Bool {
        // One rule, owned by the whiteboard face, for which kinds skip chrome.
        !CanvasWhiteboardCardFace.usesCardChrome(card.content)
    }

    @ViewBuilder
    private func faceContent(
        _ face: CanvasZoomFace, scale: Double, selected: Bool, contentFocused: Bool
    ) -> some View {
        if face.showsLiveContent {
            liveFace(scale: scale, selected: selected, contentFocused: contentFocused)
        } else {
            compactFace(face, scale: scale)
        }
    }

    /// The gold ring for a selected card or a valid connection target.
    private func selectionRing(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
            .strokeBorder(theme.palette.accent, lineWidth: contrast == .increased ? 2.5 : 1.5)
            .padding(-2)
            .opacity(isOn ? 1 : 0)
            .animation(RafuMotion.selection, value: isOn)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func resizeOverlay(_ face: CanvasZoomFace, scale: Double, selected: Bool)
        -> some View
    {
        if face.showsLiveContent {
            resizeZones(scale: scale, selected: selected)
        }
    }

    /// No zones on a frame: its size is derived from its members.
    @ViewBuilder
    private func resizeZones(scale: Double, selected: Bool) -> some View {
        if !card.content.hasDerivedSize {
            CanvasResizeZones(
                size: CGSize(width: card.rect.width, height: card.rect.height),
                scale: scale, showsHandles: selected,
                changed: { edges, value in resizeChanged(edges, value) },
                ended: { resizeEnded() })
        }
    }

    /// Ports appear only while the pointer is over the card (and stay while a
    /// port is dragged). Keyboard and VoiceOver users connect through the
    /// Connect action and the "Connect To" menu instead.
    private func portsOverlay(scale: Double) -> some View {
        CanvasConnectionPorts(
            title: card.title,
            isVisible: isHovering,
            connect: { session.canvasDialog = .connection(board.id, card.id, nil) },
            changed: { updateConnectionDrag(card.id, $0) },
            ended: { finishConnectionDrag(card.id, $0) },
            cancelled: { cancelConnectionDrag(card.id) },
            viewportScale: scale
        )
    }

    // MARK: Faces

    private func liveFace(scale: Double, selected: Bool, contentFocused: Bool) -> some View {
        VStack(spacing: 0) {
            header(scale: scale, selected: selected, contentFocused: contentFocused)
            Rectangle().fill(theme.palette.borderSubtle).frame(height: 1)
            sizedBody
        }
    }

    /// While a terminal or web card is being resized its content keeps the
    /// start size and scales, so the PTY sees one size change on mouse-up.
    @ViewBuilder private var sizedBody: some View {
        if let frozen = frozenBodySize {
            let width = CGFloat(card.rect.width)
            let height = max(1, CGFloat(card.rect.height) - headerHeight - 1)
            cardBody
                .frame(width: frozen.width, height: frozen.height)
                .scaleEffect(
                    x: width / max(1, frozen.width), y: height / max(1, frozen.height),
                    anchor: .topLeading
                )
                .frame(width: width, height: height, alignment: .topLeading)
                .clipped()
        } else {
            cardBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func compactFace(_ face: CanvasZoomFace, scale: Double) -> some View {
        let titleSize = CanvasZoomMetrics.titleFontSize(scale: scale)
        let detailSize = max(12, 11 / scale)
        return VStack(alignment: .leading, spacing: 6 / max(scale, 0.1)) {
            HStack(spacing: 6) {
                kindGlyph(size: titleSize)
                Text(displayTitle)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(face == .silhouette ? 2 : 1)
            }
            if face == .summary {
                if let state = headerState {
                    Text(state)
                        .font(.system(size: detailSize, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary).lineLimit(1)
                }
                let line =
                    commands.noteModel?.excerpt
                    ?? CanvasCardPresentation.summaryLine(
                        for: card.content, terminalTitle: terminalReportedTitle)
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: detailSize))
                        .foregroundStyle(theme.palette.textMuted).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .gesture(headerGesture)
        .contextMenu { CanvasCardMenuContent(card: card, board: board, session: session) }
    }

    // MARK: Header

    /// The vendor mark of the agent CLI a terminal runs, or the card type's
    /// symbol. Vendor SVGs render through `AgentIconView` (SwiftUI only).
    @ViewBuilder
    private func kindGlyph(size: Double) -> some View {
        if let cli = agentCLI {
            AgentIconView(cli: cli, size: CGFloat(size) + 2)
                .help(cli.displayName)
                .accessibilityHidden(true)
        } else {
            Image(systemName: card.content.symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private func header(scale: Double, selected: Bool, contentFocused: Bool) -> some View {
        let showsActions = isHovering || selected || board.focusedCardID == card.id
        // 12 pt semibold, never below 11 screen points while zoomed out.
        let titleSize = max(
            12,
            CanvasZoomMetrics.minimumTitleScreenPoints / max(scale, CanvasZoomMetrics.minimumScale))
        return HStack(spacing: 7) {
            kindGlyph(size: 12)
                .frame(width: 16, height: 16)
            if board.renamingCardID == card.id {
                CanvasCardRenameField(
                    card: card, board: board, session: session, fontSize: titleSize)
            } else {
                Text(displayTitle)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        titleFrame = $0
                    }
            }
            if let state = headerState {
                if case .note = card.content, state != "Editing" {
                    CanvasHeaderBadge(text: state)
                } else {
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .monospacedDigit()
                        .layoutPriority(-1)
                }
            }
            if isDirtyFile { CanvasHeaderBadge(text: "Modified") }
            if showsDockedBadge { CanvasHeaderBadge(text: "Docked", symbol: "pin.fill") }
            if let model = commands.noteModel, model.isEditing {
                CanvasNoteFormatBar(
                    model: model, availableWidth: CGFloat(card.rect.width), showsEditingLabel: false
                )
            } else {
                Spacer(minLength: 4)
            }
            if contentFocused {
                CanvasReturnToBoardButton { returnToBoard() }
            }
            actionCluster(visible: showsActions)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: headerHeight)
        .background(contentFocused ? theme.palette.accent.opacity(0.06) : Color.clear)
        .contentShape(.rect)
        .gesture(headerGesture)
        .contextMenu { CanvasCardMenuContent(card: card, board: board, session: session) }
    }

    private func actionCluster(visible: Bool) -> some View {
        HStack(spacing: 2) {
            headerButton(
                title: "Zoom to Card", symbol: "arrow.up.left.and.arrow.down.right"
            ) { commands.zoomToCard() }
            if let primary = commands.primary {
                headerButton(title: primary.title, symbol: primary.symbol, action: primary.perform)
            }
            Menu {
                CanvasCardMenuContent(card: card, board: board, session: session)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .tint(theme.palette.textSecondary)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(card.title) actions")
            .accessibilityLabel("\(card.title) actions")
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    private func headerButton(title: String, symbol: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 13))
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Surface

    private func surface(_ shape: RoundedRectangle) -> some View {
        let dark = theme.isDark
        // Two quiet layers: a contact hairline and a soft ambient shadow.
        let rest: [(Double, CGFloat, CGFloat)] =
            dark ? [(0.26, 1, 0.5), (0.16, 8, 4)] : [(0.06, 1, 0.5), (0.06, 8, 4)]
        let dragged: [(Double, CGFloat, CGFloat)] =
            dark ? [(0.28, 2, 1), (0.26, 14, 10)] : [(0.08, 2, 1), (0.12, 14, 10)]
        let values = isLifted ? dragged : rest
        return shape.fill(theme.palette.elevatedBackground)
            .shadow(color: Color.black.opacity(values[0].0), radius: values[0].1, y: values[0].2)
            .shadow(color: Color.black.opacity(values[1].0), radius: values[1].1, y: values[1].2)
            .animation(
                reduceMotion ? nil : (isLifted ? RafuMotion.lift : RafuMotion.setDown),
                value: isLifted)
    }

    private func border(_ shape: RoundedRectangle, contentFocused: Bool) -> some View {
        ZStack {
            shape.strokeBorder(
                contrast == .increased
                    ? theme.palette.borderStrong
                    : (isHovering
                        ? theme.palette.borderStrong.opacity(0.5) : theme.palette.borderSubtle),
                lineWidth: 1)
            if contentFocused {
                shape.strokeBorder(
                    theme.palette.accent, lineWidth: contrast == .increased ? 2.5 : 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Card body

    @ViewBuilder private var cardBody: some View {
        if case .nativeApp = card.content {
            CanvasNativeAppCard(card: card, board: board, session: session)
        } else if case .terminal = card.content {
            CanvasTerminalCard(card: card, board: board, session: session)
        } else if case .web = card.content {
            CanvasWebCard(card: card, board: board, session: session)
        } else if case .file(let path) = card.content {
            CanvasFileExcerptCard(
                card: card, path: path, board: board, session: session, activate: activateCard)
        } else if case .note = card.content {
            CanvasNoteCard(
                card: card, board: board, session: session,
                presentationID: presentationID,
                isCurrentPresentation: session.canvasResources[board.id]?.canPresent(
                    owner: presentationID) == true,
                scale: board.viewport.scale, showsInlineChrome: false)
        } else if case .image(let path) = card.content {
            Button(action: activateCard) {
                CanvasImageContent(path: path, session: session, pixels: 256).padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
            }.buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { session.openCanvasFile(path) })
        } else {
            // Kinds this shell does not draw itself (a Mermaid diagram).
            CanvasWhiteboardCardFace(card: card, board: board)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header state

    private var displayTitle: String {
        CanvasCardPresentation.displayTitle(title: card.title, content: card.content)
    }

    private var accessibilityTitle: String {
        if let cli = agentCLI {
            return "\(displayTitle), \(cli.displayName) \(card.content.kindName)"
        }
        return "\(displayTitle), \(card.content.kindName)"
    }

    private var terminalPane: TerminalPaneSnapshot? {
        guard case .terminal(let id) = card.content else { return nil }
        return session.terminal.terminalGroup(id)?.panes.first
    }

    /// The agent CLI this terminal runs: a direct agent terminal names its
    /// provider; a live shell asks its controller (the Rafu-launched provider,
    /// else detection from the terminal title).
    private var agentCLI: ConductorCLIID? {
        guard let pane = terminalPane else { return nil }
        if case .directAgentTerminal(let provider) = pane.runtimeKind { return provider }
        guard pane.status == .live,
            let controller = session.terminal.terminalController(for: pane.id)
        else { return nil }
        return controller.resolvedAgentProvider
    }

    private var terminalReportedTitle: String? { terminalPane?.reportedTitle?.rawValue }

    private var headerState: String? { commands.stateWord }

    private var isDirtyFile: Bool {
        guard case .file(let path) = card.content else { return false }
        return session.openDocuments.contains {
            $0.isDirty && session.relativePath(for: $0.url) == path
        }
    }

    private var showsDockedBadge: Bool {
        guard case .nativeApp = card.content else { return false }
        return CanvasAppDocking.shared.state(for: card.id).isDocked
    }

    // MARK: Hover

    private func hoverChanged(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            withAnimation(RafuMotion.hoverIn) { isHovering = true }
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .seconds(RafuMotion.contextualHideDelay))
                guard !Task.isCancelled else { return }
                withAnimation(RafuMotion.hoverOut) { isHovering = false }
            }
        }
    }

    // MARK: Selection

    private func returnToBoard() {
        board.backToBoard()
        focusBoard()
    }

    private func raiseIfNeeded() {
        guard board.frontmostCardID != card.id else { return }
        let ids = board.cardIDsMovingTogether(with: [card.id])  // X9 diagrams: members stay above
        session.performCanvasEdit(board) { try board.reorder(ids, toFront: true) }
    }

    private func toggleMembership() {
        var next = board.selection
        if next.contains(card.id) { next.remove(card.id) } else { next.insert(card.id) }
        board.select(next)
    }

    /// A click in a non-native body. Native terminal and web bodies take their
    /// own first mouse-down and report focus through their callbacks.
    private func activateCard() {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            focusBoard()
            toggleMembership()
        } else {
            raiseIfNeeded()
            board.focus(card.id)
            board.select([card.id])
        }
    }

    // MARK: Header gesture: click, double-click, move

    private var headerGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isPressed {
                    isPressed = true
                    pressBegan()
                }
                if moveOrigins.isEmpty,
                    hypot(value.translation.width, value.translation.height) >= 3
                {
                    startMove()
                }
                if !moveOrigins.isEmpty { updateMove(value.translation) }
            }
            .onEnded { value in
                isPressed = false
                if moveOrigins.isEmpty {
                    finishClick(at: value.startLocation)
                } else {
                    finishMove()
                }
            }
    }

    private func pressBegan() {
        let flags = NSEvent.modifierFlags
        guard !flags.contains(.command), !flags.contains(.shift) else { return }
        focusBoard()
        if !board.selection.contains(card.id) { board.select([card.id]) }
    }

    private func finishClick(at location: CGPoint) {
        let flags = NSEvent.modifierFlags
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        focusBoard()
        if flags.contains(.command) || flags.contains(.shift) {
            toggleMembership()
            return
        }
        board.backToBoard()
        board.select([card.id])
        raiseIfNeeded()
        guard clicks >= 2 else { return }
        if CanvasWhiteboardEditing.shared.requestEditing(card) { return }  // X5 whiteboard
        if titleFrame.contains(location) {
            board.renamingCardID = card.id
        } else {
            commands.zoomToCard()
        }
    }

    private func startMove() {
        let picked = board.selection.contains(card.id) ? board.selection : [card.id]
        let ids = board.cardIDsMovingTogether(with: picked)  // X9 diagrams: frames carry members
        if !board.selection.contains(card.id) { board.select([card.id]) }
        board.backToBoard()
        focusBoard()
        board.raiseDuringGesture(ids)
        board.beginGesture()
        moveOrigins = Dictionary(
            uniqueKeysWithValues: board.cards.filter { ids.contains($0.id) }.map {
                ($0.id, $0.rect)
            }
        )
        CanvasMotion.animate(RafuMotion.lift) { isLifted = true }
    }

    private func updateMove(_ translation: CGSize) {
        let scale = board.viewport.scale
        var dx = Double(translation.width) / scale
        var dy = Double(translation.height) / scale
        let ids = Set(moveOrigins.keys)
        let frames = moveOrigins.values.map(\.cgRect)
        if let first = frames.first, !NSEvent.modifierFlags.contains(.command) {
            let union = frames.dropFirst().reduce(first) { $0.union($1) }
            // Frame edges follow their members, so they are no snap targets.
            let others = board.cards.filter {
                !ids.contains($0.id) && !$0.content.hasDerivedSize
            }.map(\.rect.cgRect)
            let snap = CanvasSnapper.snap(
                moving: union.offsetBy(dx: CGFloat(dx), dy: CGFloat(dy)), others: others,
                scale: scale)
            dx += snap.dx
            dy += snap.dy
            snappedX = snap.snappedX
            snappedY = snap.snappedY
            interaction.show(guides: snap.guides)
        } else {
            snappedX = false
            snappedY = false
            interaction.show(guides: [])
        }
        // One batch, so the frame refit sees the whole group moved at once.
        var rects: [CanvasCardID: CanvasRect] = [:]
        for (id, origin) in moveOrigins {
            var rect = origin
            rect.x = min(50_000, max(-50_000, origin.x + dx))
            rect.y = min(50_000, max(-50_000, origin.y + dy))
            rects[id] = rect
        }
        board.setRects(rects)
    }

    private func finishMove() {
        // Off a guide the card lands on the 8 pt grid; on a guide it stays exact.
        var rects: [CanvasCardID: CanvasRect] = [:]
        for card in board.cards where moveOrigins[card.id] != nil {
            var rect = card.rect
            if !snappedX { rect.x = (rect.x / 8).rounded() * 8 }
            if !snappedY { rect.y = (rect.y / 8).rounded() * 8 }
            rects[card.id] = rect
        }
        board.setRects(rects)
        board.endGesture()
        interaction.clearGuides(fade: true)
        CanvasMotion.animate(RafuMotion.setDown) { isLifted = false }
        moveOrigins = [:]
        snappedX = false
        snappedY = false
    }

    // MARK: Resize

    private func resizeChanged(_ edges: CanvasResizeEdges, _ value: DragGesture.Value) {
        if resizeStart == nil {
            board.backToBoard()
            focusBoard()
            board.select([card.id])
            resizeStart = card.rect
            resizeHapticPlayed = false
            board.beginGesture()
            switch card.content {
            case .terminal, .web:
                frozenBodySize = CGSize(
                    width: CGFloat(card.rect.width),
                    height: CGFloat(card.rect.height) - headerHeight - 1)
            default: break
            }
        }
        guard let start = resizeStart else { return }
        let scale = board.viewport.scale
        let outcome = CanvasLayoutMath.resize(
            start, edges: edges,
            dx: Double(value.translation.width) / scale,
            dy: Double(value.translation.height) / scale,
            minimum: card.content.minimumSize,
            aspect: card.content.keepsAspect ? start.width / start.height : nil,
            allowsResistance: !reduceMotion)
        board.setRect(outcome.rect, for: card.id)
        if outcome.reachedMinimum, !resizeHapticPlayed {
            resizeHapticPlayed = true
            RafuHaptics.alignment(channel: "resize")
        }
    }

    private func resizeEnded() {
        if let rect = board.cards.first(where: { $0.id == card.id })?.rect {
            let clamped = CanvasLayoutMath.clampedToMinimum(
                rect, minimum: card.content.minimumSize)
            if clamped != rect {
                CanvasMotion.animate(RafuMotion.resizeReturn) {
                    board.setRect(clamped, for: card.id)
                }
            }
        }
        board.endGesture()
        resizeStart = nil
        frozenBodySize = nil
    }
}

/// The card's VoiceOver element: its name, state, selection, and actions for
/// the commands that otherwise need a pointer or a menu.
private struct CanvasCardAccessibility: ViewModifier {
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    let label: String
    let value: String
    let isSelected: Bool

    func body(content: Content) -> some View {
        let commands = CanvasCardCommands(card: card, board: board, session: session)
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: "Zoom to Card") { commands.zoomToCard() }
            .accessibilityAction(named: "Connect") {
                session.canvasDialog = .connection(board.id, card.id, nil)
            }
            .accessibilityAction(named: "Move Left") { commands.move(dx: -8, dy: 0) }
            .accessibilityAction(named: "Move Right") { commands.move(dx: 8, dy: 0) }
            .accessibilityAction(named: "Move Up") { commands.move(dx: 0, dy: -8) }
            .accessibilityAction(named: "Move Down") { commands.move(dx: 0, dy: 8) }
            .accessibilityActions {
                // A frame fits its members; it has no size of its own.
                if !card.content.hasDerivedSize {
                    Button("Make Larger") { commands.resize(dw: 8, dh: 8) }
                    Button("Make Smaller") { commands.resize(dw: -8, dh: -8) }
                }
            }
            .accessibilityAction(named: "Remove from Ensemble") { commands.requestRemoval() }
    }
}
