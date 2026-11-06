import SwiftUI

/// The 56 × 36 pt outline of a saved board in an Open Ensemble row (UX
/// Round C, P1): one filled rect per card on a quiet frame. An empty board
/// shows the empty frame. Decorative: the row's title and caption carry
/// the meaning. No shadow.
struct CanvasBoardSilhouetteView: View {
    let silhouette: CanvasBoardSilhouette
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let ink = theme.palette.textSecondary
        Canvas { context, size in
            for rect in silhouette.rects(in: size) {
                let path = Path(rect)
                context.fill(path, with: .color(ink.opacity(0.35)))
                context.stroke(path, with: .color(ink), lineWidth: 0.5)
            }
        }
        .frame(
            width: CanvasBoardSilhouette.size.width, height: CanvasBoardSilhouette.size.height
        )
        .background(theme.palette.elevatedBackground, in: .rect(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    contrast == .increased ? theme.palette.borderStrong : theme.palette.borderSubtle
                )
        }
        .accessibilityHidden(true)
    }
}
