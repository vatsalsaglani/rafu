import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `CardLink`: a chip that focuses another card on the same Ensemble.
@JRComponent(
    "CardLink", description: "A chip that focuses another card on this Ensemble (id or title).")
nonisolated struct RafuCardLink: View {
    @JRProp(description: "The card's id or exact title.") var node: String
    @JRProp(description: "Optional text; default is the card's title.") var label: String?

    @Environment(\.generatedViewBoardContext) private var board
    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let target = board?.card(node)
        let shown = label ?? target?.title ?? node
        if let board, target != nil {
            Button {
                board.focusNode(node)
            } label: {
                RafuChipLabel(symbol: "rectangle.on.rectangle", text: shown, theme: theme)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Go to \(shown)"))
            .accessibilityAddTraits(.isLink)
        } else {
            RafuChipLabel(symbol: "rectangle.on.rectangle", text: shown, theme: theme)
                .opacity(0.6)
                .accessibilityLabel(Text("\(shown), not on this Ensemble"))
        }
    }
}
