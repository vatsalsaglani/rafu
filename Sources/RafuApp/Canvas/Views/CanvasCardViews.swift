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
    @State private var isDraggingPort = false
    @State private var isPortHovered = false

    private let cornerRadius: CGFloat = 8
    private let headerHeight: CGFloat = 32
    /// Below this on-screen header width, the agent status pill drops its
    /// elapsed-time suffix first, before the title itself has to truncate.
    private static let minimumAgentElapsedWidth: Double = 260

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
        // Exactly the stored rect, whatever the body asks for: the surface,
        // border, ring and ports must sit where edges are computed.
        return faceContent(face, scale: scale, selected: selected, contentFocused: contentFocused)
            .canvasCardFill()
            .background(theme.palette.elevatedBackground)
            .clipShape(shape)
            .background { surface(shape) }
            .overlay { border(shape, contentFocused: contentFocused) }
            .overlay { selectionRing(isOn: selected || isConnectionTarget) }
            .overlay { resizeOverlay(face, scale: scale, selected: selected) }
            .overlay { portsOverlay(scale: scale) }
            .onHover { inside in hoverChanged(inside) }
            .onDisappear { disappeared() }
            .modifier(cardAccessibility(selected: selected))
            .onChange(of: commands.agentCardStatus) { _, newStatus in
                markReadIfAlreadyLookingAt(newStatus, contentFocused: contentFocused)
            }
    }

    /// A whiteboard item (shape, stroke, text) has no header or card surface:
    /// its face fills the frame and is itself the move handle. Selection,
    /// resize and ports stay the same as for every other card.
    private var whiteboardItem: some View {
        let scale = board.viewport.scale
        let selected = board.selection.contains(card.id)
        return CanvasWhiteboardCardFace(card: card, board: board)
            .canvasCardFill(alignment: .center)
            .contentShape(.rect)
            .gesture(headerGesture)
            .contextMenu { CanvasCardMenuContent(card: card, board: board, session: session) }
            .overlay { selectionRing(isOn: selected || isConnectionTarget) }
            .overlay { resizeZones(scale: scale, selected: selected) }
            .overlay { portsOverlay(scale: scale) }
            .onHover { inside in hoverChanged(inside) }
            .onDisappear { disappeared() }
            .modifier(cardAccessibility(selected: selected))
    }

    /// A card culled or removed mid-gesture still commits what it showed, so
    /// no live rect is left behind and the gesture stays one undo step.
    private func disappeared() {
        hideTask?.cancel()
        if !moveOrigins.isEmpty {
            isPressed = false
            finishMove()
        }
        if resizeStart != nil { resizeEnded() }
    }

    private func cardAccessibility(selected: Bool) -> CanvasCardAccessibility {
        CanvasCardAccessibility(
            card: card, board: board, session: session, label: accessibilityTitle,
            value: accessibilityValue, isSelected: selected)
    }

    /// An agent card speaks its full status sentence ("Done, unread, 4
    /// minutes ago"); every other card keeps its plain state word.
    private var accessibilityValue: String {
        guard let status = commands.agentCardStatus else { return headerState ?? "" }
        let elapsed = commands.agentCardStatusDate.map {
            AgentActivityStore.shared.now.timeIntervalSince($0)
        }
        return status.accessibilityValue(elapsed: elapsed ?? 0)
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

    /// No zones on a frame: its size is derived from its members. The eight
    /// zones exist only on the hovered, selected or resizing card, so the
    /// pointer does not hit-test them on every other card of the board.
    @ViewBuilder
    private func resizeZones(scale: Double, selected: Bool) -> some View {
        if !card.content.hasDerivedSize, isHovering || selected || resizeStart != nil {
            let rect = shownRect
            CanvasResizeZones(
                size: CGSize(width: rect.width, height: rect.height),
                scale: scale, showsHandles: selected,
                changed: { edges, value in resizeChanged(edges, value) },
                ended: { resizeEnded() })
        }
    }

    /// Ports appear only while the pointer is over the card (and stay while a
    /// port is dragged). Keyboard and VoiceOver users connect through the
    /// Connect action and the "Connect To" menu instead. They are mounted
    /// only then (or while a port itself is hovered, since a port reaches
    /// past the card's edge), so a board of cards does not hit-test four port
    /// dots per card on every pointer move.
    @ViewBuilder
    private func portsOverlay(scale: Double) -> some View {
        if isHovering || isDraggingPort || isPortHovered {
            CanvasConnectionPorts(
                title: card.title,
                isVisible: isHovering,
                connect: { session.canvasDialog = .connection(board.id, card.id, nil) },
                changed: {
                    if !isDraggingPort { isDraggingPort = true }
                    updateConnectionDrag(card.id, $0)
                },
                ended: {
                    isDraggingPort = false
                    finishConnectionDrag(card.id, $0)
                },
                cancelled: {
                    isDraggingPort = false
                    cancelConnectionDrag(card.id)
                },
                viewportScale: scale,
                portHoverChanged: { inside in
                    if isPortHovered != inside { isPortHovered = inside }
                }
            )
        }
    }

    /// The rect this card shows: the live rect while this card resizes (only
    /// then does its body read the live geometry), otherwise the stored rect.
    private var shownRect: CanvasRect {
        guard resizeStart != nil else { return card.rect }
        return board.liveGeometry.rect(for: card.id) ?? card.rect
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
            let rect = shownRect
            let width = CGFloat(rect.width)
            let height = max(1, CGFloat(rect.height) - headerHeight - 1)
            cardBody
                .frame(width: frozen.width, height: frozen.height)
                .scaleEffect(
                    x: width / max(1, frozen.width), y: height / max(1, frozen.height),
                    anchor: .topLeading
                )
                .frame(width: width, height: height, alignment: .topLeading)
                .clipped()
        } else {
            // Content taller than the body (a centred block in a short card)
            // overflows downward, where the face's clip shape cuts it at the
            // card's bottom edge; it never pushes the header up.
            cardBody
                .canvasCardFill()
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
                if let status = commands.agentCardStatus {
                    HStack(spacing: 4) {
                        AgentActivityGlyph(status: status)
                        Text(status.word)
                            .font(.system(size: detailSize, weight: .medium))
                            .foregroundStyle(theme.palette.textSecondary).lineLimit(1)
                    }
                } else if let state = headerState {
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
        let agentStatus = commands.agentCardStatus
        return HStack(spacing: 7) {
            kindGlyph(size: 12)
                .frame(width: 16, height: 16)
            if board.renamingCardID == card.id {
                CanvasCardRenameField(
                    card: card, board: board, session: session, fontSize: titleSize,
                    shownTitle: terminalPane == nil ? nil : displayTitle)
            } else {
                Text(displayTitle)
                    .font(.system(size: titleSize, weight: .semibold))
                    .fontWeight(agentStatus?.readsTitleBold == true ? .bold : nil)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        titleFrame = $0
                    }
            }
            if let agentStatus {
                AgentStatusPill(
                    status: agentStatus, elapsed: agentElapsedLabel(for: agentStatus, scale: scale))
            } else if let state = headerState {
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
        // While lifted, one blurred shadow: the contact hairline drops to a
        // clear, unblurred no-op, so a drag pays for one blur pass, not two.
        let dragged: [(Double, CGFloat, CGFloat)] =
            dark ? [(0, 0, 0), (0.30, 14, 10)] : [(0, 0, 0), (0.14, 14, 10)]
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

    /// The card title. A terminal node that still has its automatic title
    /// ("Terminal", "Terminal Group 1") shows the name the user gave its pane;
    /// with no pane name and an agent running, the agent's task title, or its
    /// name ("Claude Code"), beside the agent's mark. A renamed node keeps
    /// its name (`TerminalNaming.resolvedGroupTitle`).
    private var displayTitle: String {
        if case .terminal = card.content, TerminalNaming.isAutomaticGroupName(card.title) {
            var agentTitle: String?
            if let cli = agentCLI {
                let controller = terminalPane.flatMap {
                    session.terminal.terminalController(for: $0.id)
                }
                agentTitle = TerminalSessionPresentation.agentTitle(
                    reportedTitle: controller?.reportedTitle ?? terminalReportedTitle,
                    provider: cli, shellName: controller?.shellDisplayName)
            }
            return TerminalNaming.resolvedGroupTitle(
                storedName: card.title, paneUserName: terminalPane?.explicitUserName?.rawValue,
                agentTitle: agentTitle)
        }
        return CanvasCardPresentation.displayTitle(title: card.title, content: card.content)
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

    /// A card already focused and open (its content has keyboard focus)
    /// counts as "looked at" the moment its reply turns `doneUnread` —
    /// there is no separate focus event to clear it, unlike a card that
    /// gets focused afterward (`WorkspaceTerminalController.clearAttention`
    /// covers that path).
    private func markReadIfAlreadyLookingAt(_ status: AgentCardStatus?, contentFocused: Bool) {
        guard status == .doneUnread, contentFocused,
            case .terminal(let groupID) = card.content,
            let pane = session.terminal.terminalGroup(groupID)?.panes.first,
            let controller = session.terminal.terminalController(for: pane.id)
        else { return }
        AgentActivityStore.shared.markReplyRead(for: controller)
    }

    /// The header pill's relative-time suffix, or `nil` to hide it: no
    /// underlying session date (`.stopped`, or every non-agent state), or
    /// the card's on-screen header width is under
    /// `minimumAgentElapsedWidth` — the suffix collapses before the title
    /// has to truncate.
    private func agentElapsedLabel(for status: AgentCardStatus, scale: Double) -> String? {
        guard let date = commands.agentCardStatusDate,
            card.rect.width * scale >= Self.minimumAgentElapsedWidth
        else { return nil }
        return AgentCardElapsed.label(since: date, now: AgentActivityStore.shared.now)
    }

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
        var nextSnappedX = false
        var nextSnappedY = false
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
            nextSnappedX = snap.snappedX
            nextSnappedY = snap.snappedY
            interaction.show(guides: snap.guides)
        } else {
            interaction.show(guides: [])
        }
        // Written only on a change: a state write per frame is work too.
        if snappedX != nextSnappedX { snappedX = nextSnappedX }
        if snappedY != nextSnappedY { snappedY = nextSnappedY }
        // One batch, so the frame refit sees the whole group moved at once.
        // Live only: nothing is stored, saved or undoable until release.
        var rects: [CanvasCardID: CanvasRect] = [:]
        for (id, origin) in moveOrigins {
            var rect = origin
            rect.x = min(50_000, max(-50_000, origin.x + dx))
            rect.y = min(50_000, max(-50_000, origin.y + dy))
            rects[id] = rect
        }
        board.showLiveRects(rects)
    }

    private func finishMove() {
        // Off a guide the card lands on the 8 pt grid; on a guide it stays exact.
        // One commit for the whole drag: one undo step, one save.
        var rects: [CanvasCardID: CanvasRect] = [:]
        for card in board.cards where moveOrigins[card.id] != nil {
            var rect = board.liveGeometry.rect(for: card.id) ?? card.rect
            if !snappedX { rect.x = (rect.x / 8).rounded() * 8 }
            if !snappedY { rect.y = (rect.y / 8).rounded() * 8 }
            rects[card.id] = rect
        }
        board.commitLiveRects(rects)
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
        board.showLiveRects([card.id: outcome.rect])
        if outcome.reachedMinimum, !resizeHapticPlayed {
            resizeHapticPlayed = true
            RafuHaptics.alignment(channel: "resize")
        }
    }

    private func resizeEnded() {
        if let rect = board.shownRect(of: card.id) {
            board.commitLiveRects([card.id: rect])
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

extension View {
    /// Takes exactly the size the parent proposes, whatever the content asks
    /// for. `.frame(maxWidth: .infinity, maxHeight: .infinity)` alone is not
    /// enough: with no minimum, a flexible frame reports the larger of the
    /// proposal and its child, so an inflexible child (40 fixed-height
    /// excerpt lines, a centred button block) makes the frame taller than
    /// the card. The board's placement frame then centred that taller card
    /// on its rect, so its top border drew above the stored rect while edges
    /// and handles stayed on it. `minWidth: 0, minHeight: 0` caps the frame
    /// at the proposal; the content overflows from `alignment` instead.
    func canvasCardFill(alignment: Alignment = .topLeading) -> some View {
        frame(
            minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
            alignment: alignment)
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
