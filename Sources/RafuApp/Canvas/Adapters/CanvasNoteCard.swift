import AppKit
import MarkdownUI
import SwiftUI

/// The body of a note card (review 7.8): rendered Markdown in Read mode, the
/// TextKit editor in Edit mode, and smaller faces when the board is zoomed out.
///
/// Inputs match the old `CanvasNoteEditor` call plus the board scale. The buffer
/// is owned by `CanvasBoardResources`, exactly as before; this view only reads
/// it when entering Read mode and never keeps the live text in observable state.
///
/// W6a: hide this view's inline pencil, Format bar, and focus stroke by passing
/// `showsInlineChrome: false` once the header shows them. Drive Edit mode with
/// `CanvasNoteModel` (see `WorkspaceSession.canvasNoteModel(boardID:card:)`) and
/// show `CanvasNoteFormatBar(model:availableWidth:)` in the header.
struct CanvasNoteCard: View {
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    let presentationID: UUID?
    let isCurrentPresentation: Bool
    /// The board scale. Below 50% Edit mode asks the board to zoom to the card.
    var scale: Double = 1
    var showsInlineChrome = true

    var body: some View {
        if let buffer = session.canvasResources[board.id]?.note(for: card) {
            CanvasNoteSurface(
                card: card, board: board, session: session, buffer: buffer,
                presentationID: presentationID, isCurrentPresentation: isCurrentPresentation,
                scale: scale, showsInlineChrome: showsInlineChrome)
        } else {
            Color.clear
        }
    }
}

private struct CanvasNoteSurface: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    let buffer: CanvasNoteBuffer
    let presentationID: UUID?
    let isCurrentPresentation: Bool
    let scale: Double
    let showsInlineChrome: Bool
    /// Parsed once when Read mode appears or the text changes; not per keystroke.
    @State private var blocks: [CanvasNoteMarkdown.Block]?
    @FocusState private var readFocused: Bool

    private var model: CanvasNoteModel { buffer.model }
    private var isActive: Bool { board.contentIsActive && board.focusedCardID == card.id }

    var body: some View {
        VStack(spacing: 0) {
            if model.isEditing, showsInlineChrome {
                CanvasNoteFormatBar(
                    model: model, availableWidth: card.rect.width, showsEditingLabel: true)
                Divider()
            }
            ZStack {
                if model.isEditing {
                    CanvasNoteEditor(
                        card: card, board: board, session: session,
                        presentationID: presentationID,
                        isCurrentPresentation: isCurrentPresentation
                    )
                    .transition(.opacity)
                } else {
                    readContent
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : RafuMotion.noteModeSwap, value: model.mode)
        }
        .overlay {
            if showsInlineChrome, isActive {
                Rectangle().strokeBorder(theme.palette.focusRing, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .focusedSceneValue(\.canvasNoteEditing, model.isEditing ? model : nil)
        .onAppear {
            bind()
            refreshBlocks()
            if isActive, !model.isEditing { readFocused = true }
        }
        .onChange(of: model.readRevision) { _, _ in refreshBlocks() }
        .onChange(of: isActive) { _, active in
            if !active, model.isEditing { model.endEditing() }
            if active, !model.isEditing { readFocused = true }
        }
        .onChange(of: scale) { _, newScale in
            if model.isEditing, !CanvasNoteZoom.canEdit(atScale: newScale) { model.endEditing() }
        }
    }

    // MARK: Read mode

    @ViewBuilder
    private var readContent: some View {
        let face = CanvasNoteZoom.face(forScale: scale)
        switch face {
        case .full, .collapsedCode:
            if let blocks {
                readView(blocks, collapsesCode: face == .collapsedCode)
            } else {
                Color.clear
            }
        case .summary, .titleOnly:
            CanvasNoteSummaryFace(
                title: model.derivedTitle ?? card.title, excerpt: model.excerpt,
                progress: model.progressText, scale: scale, titleOnly: face == .titleOnly
            )
            .contentShape(.rect)
            .onTapGesture { board.selection = [card.id] }
        }
    }

    private func readView(_ blocks: [CanvasNoteMarkdown.Block], collapsesCode: Bool)
        -> some View
    {
        CanvasNoteReadView(
            blocks: blocks, collapsesCode: collapsesCode,
            baseURL: CanvasNoteLink.baseURL(for: session.rootURL),
            imageRoot: session.rootURL,
            isActive: isActive, showsInlineChrome: showsInlineChrome,
            anchor: model.exitAnchor,
            consumeAnchor: { model.consumeExitAnchor() },
            toggleTask: toggleTask, openLink: openLink,
            edit: { line, offset in model.beginEditing(atLine: line, anchorOffset: offset) },
            activate: { if !isActive { board.focus(card.id) } },
            copyMarkdown: copyMarkdown
        )
        .focusable()
        .focused($readFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleReadKey(press) }
    }

    private func handleReadKey(_ press: KeyPress) -> KeyPress.Result {
        let blocked: EventModifiers = [.command, .control, .option]
        if press.key == .return, press.modifiers.isDisjoint(with: blocked) {
            return model.beginEditing() ? .handled : .ignored
        }
        if press.key == "z", press.modifiers.contains(.command),
            !press.modifiers.contains(.option)
        {
            let redo = press.modifiers.contains(.shift)
            guard redo ? buffer.canRedo : buffer.canUndo else { return .ignored }
            if redo { buffer.redo() } else { buffer.undo() }
            model.invalidateReadView()
            return .handled
        }
        if buffer.isEmpty, press.modifiers.isDisjoint(with: blocked),
            Self.isTypedText(press.characters)
        {
            if model.beginEditing() { buffer.insertInitialText(press.characters) }
            return .handled
        }
        return .ignored
    }

    private static func isTypedText(_ characters: String) -> Bool {
        !characters.isEmpty
            && characters.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
            }
    }

    private func toggleTask(_ index: Int) {
        if !isActive { board.focus(card.id) }
        guard buffer.toggleTask(at: index) else { return }
        model.invalidateReadView()
    }

    private func openLink(_ url: URL) {
        switch CanvasNoteLink.classify(url, root: session.rootURL) {
        case .workspaceFile(let path): session.openCanvasFile(path)
        case .external(let target): NSWorkspace.shared.open(target)
        case .ignored: NSSound.beep()
        }
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buffer.markdown, forType: .string)
    }

    private func refreshBlocks() {
        blocks = CanvasNoteMarkdown.blocks(in: buffer.markdown)
    }

    /// Connects the model to this board so hooks work without the view.
    private func bind() {
        let id = card.id
        model.scale = { [weak board] in board?.viewport.scale ?? 1 }
        model.focusCard = { [weak board] in board?.focus(id) }
        model.zoomToCard = { [weak board] in
            guard let board, board.visibleSize.width > 0, board.visibleSize.height > 0,
                let target = board.cards.first(where: { $0.id == id })
            else { return }
            board.setViewport(
                CanvasNoteZoom.viewport(centering: target.rect, in: board.visibleSize))
        }
    }
}

// MARK: Read view

private let noteViewportSpaceName = "canvasNoteViewport"

private struct CanvasNoteReadView: View {
    @Environment(\.rafuTheme) private var theme
    let blocks: [CanvasNoteMarkdown.Block]
    let collapsesCode: Bool
    let baseURL: URL?
    let imageRoot: URL?
    let isActive: Bool
    let showsInlineChrome: Bool
    let anchor: CanvasNoteModel.ExitAnchor?
    let consumeAnchor: () -> Void
    let toggleTask: (Int) -> Void
    let openLink: (URL) -> Void
    let edit: (Int?, CGFloat?) -> Void
    let activate: () -> Void
    let copyMarkdown: () -> Void
    @State private var isHovering = false

    private struct Row: Identifiable {
        let block: CanvasNoteMarkdown.Block
        let gap: CGFloat
        var id: Int { block.id }
    }

    private var rows: [Row] {
        var previous: CanvasNoteMarkdown.Block?
        return blocks.map { block in
            defer { previous = block }
            return Row(block: block, gap: Self.gap(before: block, after: previous))
        }
    }

    /// 12 pt above a heading, 6 pt below it, 8 pt between other blocks.
    static func gap(
        before block: CanvasNoteMarkdown.Block, after previous: CanvasNoteMarkdown.Block?
    )
        -> CGFloat
    {
        guard let previous else { return 0 }
        if case .heading = block.kind { return 12 }
        if case .heading = previous.kind { return 6 }
        return 8
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if blocks.isEmpty {
                    placeholder
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            CanvasNoteBlockView(
                                block: row.block,
                                text: collapsesCode
                                    ? CanvasNoteMarkdown.text(
                                        of: row.block,
                                        collapsingCodeTo: CanvasNoteZoom.collapsedCodeLines)
                                    : row.block.text,
                                baseURL: baseURL, imageRoot: imageRoot,
                                toggleTask: toggleTask, edit: edit
                            )
                            .equatable()
                            .padding(.top, row.gap)
                            .id(row.id)
                        }
                    }
                    .frame(maxWidth: 540, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .textSelection(.enabled)
                }
            }
            .onAppear { scrollToAnchor(proxy) }
            .onChange(of: blocks) { _, _ in scrollToAnchor(proxy) }
        }
        .coordinateSpace(.named(noteViewportSpaceName))
        .background(theme.palette.editorBackground)
        .environment(
            \.openURL,
            OpenURLAction { url in
                MainActor.assumeIsolated { openLink(url) }
                return .handled
            }
        )
        .overlay(alignment: .topTrailing) {
            if showsInlineChrome {
                Button {
                    edit(nil, nil)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 12))
                .help("Edit Note")
                .accessibilityLabel("Edit note")
                .opacity(isHovering || isActive ? 1 : 0)
                .animation(isHovering ? RafuMotion.hoverIn : RafuMotion.hoverOut, value: isHovering)
                .padding(6)
            }
        }
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .contextMenu {
            Button("Edit Note") { edit(nil, nil) }
            Button("Copy Note as Markdown", action: copyMarkdown)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Empty note")
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(theme.palette.textMuted)
            Text("Press Return or start typing.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .contentShape(.rect)
        .onTapGesture(count: 2) { edit(nil, nil) }
    }

    /// After Edit mode, brings the block with the caret back to where the caret was.
    private func scrollToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor, !blocks.isEmpty else { return }
        let target = blocks.last { $0.startLine <= anchor.line } ?? blocks[0]
        let point = UnitPoint(x: 0, y: anchor.fraction)
        consumeAnchor()
        Task {
            await Task.yield()
            proxy.scrollTo(target.id, anchor: point)
        }
    }
}

/// One top-level block through the shared MarkdownUI boundary. Equatable so a
/// task toggle re-renders only the block that changed.
private struct CanvasNoteBlockView: View, Equatable {
    let block: CanvasNoteMarkdown.Block
    let text: String
    let baseURL: URL?
    let imageRoot: URL?
    let toggleTask: (Int) -> Void
    let edit: (Int?, CGFloat?) -> Void
    @State private var frames = CanvasNoteTaskFrames()

    static func == (left: CanvasNoteBlockView, right: CanvasNoteBlockView) -> Bool {
        left.block == right.block && left.text == right.text && left.baseURL == right.baseURL
            && left.imageRoot == right.imageRoot
    }

    var body: some View {
        rendered
            .markdownImageProvider(CanvasNoteImageProvider(root: imageRoot))
            .rafuNoteMarkdownStyling()
            .environment(
                \.canvasNoteTasks,
                block.taskCount > 0
                    ? CanvasNoteTaskContext(
                        frames: frames, firstTaskIndex: block.firstTaskIndex,
                        toggle: { toggleTask($0) })
                    : nil
            )
            .canvasNoteBlockSpace()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .simultaneousGesture(
                SpatialTapGesture(count: 2, coordinateSpace: .named(noteViewportSpaceName))
                    .onEnded { edit(block.startLine, $0.location.y) }
            )
    }

    @ViewBuilder
    private var rendered: some View {
        if let baseURL {
            Markdown(text, baseURL: baseURL, imageBaseURL: baseURL)
        } else {
            Markdown(text)
        }
    }
}

/// Images in a note come from workspace paths only. Remote and outside-workspace
/// images show a placeholder and nothing is fetched.
struct CanvasNoteImageProvider: MarkdownUI.ImageProvider {
    let root: URL?

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, case .workspaceFile = CanvasNoteLink.classify(url, root: root) {
            LocalFileImageProvider().makeImage(url: url)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Image not shown")
        }
    }
}

// MARK: Zoomed-out faces

/// 25% to 50%: title, the first paragraph clipped to two lines, task count.
/// Below 25%: the title alone. Sizes keep text at least 11 (title) and 9 (body)
/// screen points, because the card is drawn scaled.
private struct CanvasNoteSummaryFace: View {
    @Environment(\.rafuTheme) private var theme
    let title: String
    let excerpt: String?
    let progress: String?
    let scale: Double
    let titleOnly: Bool

    var body: some View {
        let titleSize = CanvasNoteZoom.fontSize(screenPoints: 11, scale: scale, floor: 15)
        let bodySize = CanvasNoteZoom.fontSize(screenPoints: 9, scale: scale, floor: 12)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold, design: .serif))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(titleOnly ? 3 : 2)
            if !titleOnly {
                if let excerpt {
                    Text(excerpt)
                        .font(.system(size: bodySize, design: .serif))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
                if let progress {
                    Text("\(progress) tasks")
                        .font(.system(size: bodySize))
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(theme.palette.editorBackground)
        .accessibilityElement(children: .combine)
    }
}
