import SwiftUI

/// The first moves of an empty board (UX Round A, O1/S3): three dashed
/// seeds on the board — Note, Terminal and Drop — at the size and place of
/// the card each one makes (`CanvasSeedLayout`), and one caption below. It
/// replaces the old text tip panel. A seed is a real button, so Full
/// Keyboard Access and VoiceOver reach it; N and T still work from the keys.
struct CanvasSeedLayer: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    let interaction: CanvasInteractionState

    var body: some View {
        let viewport = board.viewport
        let seeds = CanvasSeedLayout.seeds(visible: board.visibleSize, viewport: viewport)
        let frames = seeds.map { seed in
            CGRect(
                x: seed.rect.x * viewport.scale + viewport.x,
                y: seed.rect.y * viewport.scale + viewport.y,
                width: seed.rect.width * viewport.scale,
                height: seed.rect.height * viewport.scale)
        }
        let union = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(seeds, frames)), id: \.0.id) { seed, frame in
                CanvasSeedButton(kind: seed.id, size: frame.size) {
                    activate(seed, frame: frame)
                }
                .offset(x: frame.minX, y: frame.minY)
            }
            if !frames.isEmpty {
                Text("Double-click the board for more")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize()
                    .frame(width: 320)
                    .offset(x: union.midX - 160, y: union.maxY + 14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Empty Ensemble")
    }

    private func activate(_ seed: CanvasSeed, frame: CGRect) {
        let centre = CGPoint(
            x: seed.rect.x + seed.rect.width / 2, y: seed.rect.y + seed.rect.height / 2)
        switch seed.id {
        case .note:
            CanvasAddKind.note.perform(on: board, session: session, center: centre)
        case .terminal:
            CanvasAddKind.terminal.perform(on: board, session: session, center: centre)
        case .drop:
            // The same palette as a double-click on the board.
            interaction.addPopoverBoardPoint = centre
            interaction.addPopoverAnchor = CGPoint(x: frame.midX, y: frame.midY)
        }
    }
}

/// One dashed seed. Solid under Increase Contrast; filled on hover.
private struct CanvasSeedButton: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let kind: CanvasSeed.Kind
    let size: CGSize
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // Zoomed far out, a seed shows its title only.
            let compact = size.height < 110
            VStack(spacing: 8) {
                if !compact {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(theme.palette.textSecondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let key, !compact {
                    RafuKeyHint(key)
                }
            }
            .padding(12)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.palette.hover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        theme.palette.borderStrong,
                        style: StrokeStyle(
                            lineWidth: 1, dash: contrast == .increased ? [] : [6, 4]))
            )
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var symbol: String {
        switch kind {
        case .note: "note.text"
        case .terminal: "terminal"
        case .drop: "arrow.down.doc"
        }
    }

    private var title: String {
        switch kind {
        case .note: "Note"
        case .terminal: "Terminal"
        case .drop: "Drop files or a chat"
        }
    }

    private var key: String? {
        switch kind {
        case .note: "N"
        case .terminal: "T"
        case .drop: nil
        }
    }

    private var help: String {
        switch kind {
        case .note: "Add a note (N)"
        case .terminal: "Add a stopped terminal (T)"
        case .drop: "Drop files or a History chat here, or click to add a card"
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .note: "Add Note"
        case .terminal: "Add Terminal"
        case .drop: "Add a card"
        }
    }

    private var accessibilityHint: String {
        switch kind {
        case .note: "Shortcut N"
        case .terminal: "Shortcut T"
        case .drop: "Opens the Add palette"
        }
    }
}
