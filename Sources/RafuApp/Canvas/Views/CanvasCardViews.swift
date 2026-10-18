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
        let scale = board.viewport.scale
        let face = CanvasZoomFace(scale: scale)
        let selected = board.selection.contains(card.id)
        let contentFocused = board.contentIsActive && board.focusedCardID == card.id
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        faceContent(face, scale: scale, selected: selected, contentFocused: contentFocused)
            .background(theme.palette.elevatedBackground)
            .clipShape(shape)
            .background { surface(shape) }
            .overlay { border(shape, contentFocused: contentFocused) }
            .overlay { selectionRing(isOn: selected || isConnectionTarget) }
            .overlay { resizeOverlay(face, scale: scale, selected: selected) }
            .overlay { portsOverlay(scale: scale, selected: selected) }
            .onHover { inside in hoverChanged(inside) }
            .onDisappear { hideTask?.cancel() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(headerState ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .modifier(CanvasCardAccessibilityActions(card: card, board: board, session: session))
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
            CanvasResizeZones(
                size: CGSize(width: card.rect.width, height: card.rect.height),
                scale: scale, showsHandles: selected,
                changed: { edges, value in resizeChanged(edges, value) },
                ended: { resizeEnded() })
        }
    }

    private func portsOverlay(scale: Double, selected: Bool) -> some View {
        CanvasConnectionPorts(
            title: card.title,
            isVisible: isHovering || selected || board.focusedCardID == card.id,
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
                Image(systemName: card.content.symbol)
                    .font(.system(size: titleSize))
                    .foregroundStyle(theme.palette.textSecondary)
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

    private func header(scale: Double, selected: Bool, contentFocused: Bool) -> some View {
        let showsActions = isHovering || selected || board.focusedCardID == card.id
        let titleSize = CanvasZoomMetrics.titleFontSize(scale: scale)
        return HStack(spacing: 8) {
            Image(systemName: card.content.symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            if isDirtyFile { CanvasHeaderBadge(text: "Modified") }
            if showsPreviewBadge { CanvasHeaderBadge(text: "Preview", symbol: "eye") }
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
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
        .background(contentFocused ? theme.palette.accent.opacity(0.08) : Color.clear)
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
        let rest: [(Double, CGFloat, CGFloat)] =
            dark ? [(0.30, 1, 1), (0.22, 9, 6)] : [(0.08, 1, 1), (0.08, 9, 6)]
        let dragged: [(Double, CGFloat, CGFloat)] =
            dark ? [(0.30, 2, 2), (0.30, 16, 14)] : [(0.12, 2, 2), (0.14, 16, 14)]
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
            Button {
                activateCard()
            } label: {
                CanvasCardSummary(card: card)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14).contentShape(.rect)
            }.buttonStyle(.plain)
        }
    }

    // MARK: Header state

    private var displayTitle: String {
        CanvasCardPresentation.displayTitle(title: card.title, content: card.content)
    }

    private var accessibilityTitle: String {
        "\(displayTitle), \(card.content.kindName)"
    }

    private var terminalPane: TerminalPaneSnapshot? {
        guard case .terminal(let id) = card.content else { return nil }
        return session.terminal.terminalGroup(id)?.panes.first
    }

    private var terminalReportedTitle: String? { terminalPane?.reportedTitle?.rawValue }

    private var headerState: String? { commands.stateWord }

    private var isDirtyFile: Bool {
        guard case .file(let path) = card.content else { return false }
        return session.openDocuments.contains {
            $0.isDirty && session.relativePath(for: $0.url) == path
        }
    }

    private var showsPreviewBadge: Bool {
        guard case .nativeApp = card.content else { return false }
        return session.canvasResources[board.id]?.nativeApp(for: card)?.frame != nil
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
        session.performCanvasEdit(board) { try board.reorder([card.id], toFront: true) }
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
        if titleFrame.contains(location) {
            board.renamingCardID = card.id
        } else {
            commands.zoomToCard()
        }
    }

    private func startMove() {
        let ids = board.selection.contains(card.id) ? board.selection : [card.id]
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
            let others = board.cards.filter { !ids.contains($0.id) }.map(\.rect.cgRect)
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
        for (id, origin) in moveOrigins {
            var rect = origin
            rect.x = min(50_000, max(-50_000, origin.x + dx))
            rect.y = min(50_000, max(-50_000, origin.y + dy))
            board.setRect(rect, for: id)
        }
    }

    private func finishMove() {
        // Off a guide the card lands on the 8 pt grid; on a guide it stays exact.
        for id in moveOrigins.keys {
            guard var rect = board.cards.first(where: { $0.id == id })?.rect else { continue }
            if !snappedX { rect.x = (rect.x / 8).rounded() * 8 }
            if !snappedY { rect.y = (rect.y / 8).rounded() * 8 }
            board.setRect(rect, for: id)
        }
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

/// VoiceOver actions for the commands that otherwise need a pointer or a menu.
private struct CanvasCardAccessibilityActions: ViewModifier {
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    func body(content: Content) -> some View {
        let commands = CanvasCardCommands(card: card, board: board, session: session)
        content
            .accessibilityAction(named: "Zoom to Card") { commands.zoomToCard() }
            .accessibilityAction(named: "Connect") {
                session.canvasDialog = .connection(board.id, card.id, nil)
            }
            .accessibilityAction(named: "Move Left") { commands.move(dx: -8, dy: 0) }
            .accessibilityAction(named: "Move Right") { commands.move(dx: 8, dy: 0) }
            .accessibilityAction(named: "Move Up") { commands.move(dx: 0, dy: -8) }
            .accessibilityAction(named: "Move Down") { commands.move(dx: 0, dy: 8) }
            .accessibilityAction(named: "Make Larger") { commands.resize(dw: 8, dh: 8) }
            .accessibilityAction(named: "Make Smaller") { commands.resize(dw: -8, dh: -8) }
            .accessibilityAction(named: "Remove from Canvas") { commands.requestRemoval() }
    }
}

struct CanvasCardSummary: View {
    let card: CanvasCard
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch card.content {
            case .file(let path):
                Label(path, systemImage: "doc.text").font(.callout)
            case .image(let path):
                Label(path, systemImage: "photo").font(.callout)
                Text("Click to view the image.")
            case .note(let snapshot):
                Text(
                    snapshot.isEmpty
                        ? "An empty note. Click to edit." : String(snapshot.prefix(512))
                )
                .lineLimit(9)
            case .terminal:
                Label("Terminal", systemImage: "terminal")
            case .web(let destination):
                Label(destination.address, systemImage: "globe")
            case .nativeApp:
                EmptyView()
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}
