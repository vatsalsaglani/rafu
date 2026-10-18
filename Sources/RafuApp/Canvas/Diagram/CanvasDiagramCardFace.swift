import AppKit
import SwiftUI

/// The face of a `.frame` or `.serviceIcon` card. The card shell owns the
/// move gesture, selection ring, resize and ports; this view only draws.
/// A frame face also keeps its members following it and keeps itself behind
/// them in the stack.
struct CanvasDiagramCardFace: View {
    let card: CanvasCard
    let board: CanvasBoardState

    var body: some View {
        if let frame = card.content.diagramFrame {
            CanvasFrameFaceView(title: card.title, style: frame.style)
                .modifier(CanvasFrameFollower(frameID: card.id, board: board))
        } else if let icon = card.content.diagramServiceIcon {
            CanvasServiceIconFaceView(icon: icon, title: card.title)
        }
    }
}

/// Members follow a frame that moved on its own (keyboard move, Align, an
/// agent edit), and a frame that an edit raised goes back behind its members.
private struct CanvasFrameFollower: ViewModifier {
    let frameID: CanvasCardID
    let board: CanvasBoardState

    func body(content: Content) -> some View {
        let nodes = CanvasFrameLayout.nodes(board.cards)
        let state = CanvasFrameLayout.followState(frameID: frameID, in: nodes)
        content
            .onChange(of: state) { old, new in
                guard let old, let new else { return }
                board.applyFrameFollow(CanvasFrameLayout.followMoves(from: old, to: new))
            }
            .onChange(of: nodes.map(\.id)) { _, _ in board.restackFramesIfNeeded() }
            .onAppear { board.restackFramesIfNeeded() }
    }
}

extension CanvasFrameStyle {
    func color(_ palette: RafuThemePalette) -> Color {
        switch self {
        case .neutral: palette.textSecondary
        case .blue: palette.info
        case .green: palette.success
        case .orange: palette.warning
        }
    }
}

/// A titled, rounded region with a subtle tint.
struct CanvasFrameFaceView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let style: CanvasFrameStyle

    var body: some View {
        let tint = style.color(theme.palette)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(tint.opacity(theme.isDark ? 0.10 : 0.07)))
        .overlay(
            shape.strokeBorder(
                tint.opacity(contrast == .increased ? 0.9 : 0.35),
                style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame \(title)")
    }
}

/// An icon with its label below, on light chrome.
struct CanvasServiceIconFaceView: View {
    @Environment(\.rafuTheme) private var theme
    let icon: CanvasServiceIcon
    let title: String
    var library = CanvasIconPackLibrary.shared

    var body: some View {
        VStack(spacing: 6) {
            CanvasServiceIconImage(icon: icon, library: library)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.cardBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let pack = library.pack(id: icon.packID) else { return title }
        return "\(title), \(pack.name) icon"
    }
}

/// The vendor image (SVG or PNG) or the SF Symbol of a pack entry.
struct CanvasServiceIconImage: View {
    @Environment(\.rafuTheme) private var theme
    let icon: CanvasServiceIcon
    var library = CanvasIconPackLibrary.shared

    var body: some View {
        if let image = library.image(for: icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .accessibilityHidden(true)
        } else {
            Image(systemName: library.symbol(for: icon))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fontWeight(.regular)
                .foregroundStyle(theme.palette.textSecondary)
                .padding(6)
                .accessibilityHidden(true)
        }
    }
}
