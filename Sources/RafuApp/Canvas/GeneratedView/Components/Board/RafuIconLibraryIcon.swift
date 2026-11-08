import JSONRenderClient
import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// `IconLibraryIcon`: an icon from the user's imported icon packs.
@JRComponent(
    "IconLibraryIcon",
    description:
        "An icon from Rafu's icon library: pack and icon ids (see icon_search); size sm, md or lg."
)
nonisolated struct RafuIconLibraryIcon: View {
    @JRProp(description: "The icon pack id.") var pack: String
    @JRProp(description: "The icon id in the pack.") var icon: String
    @JRProp(oneOf: ["sm", "md", "lg"]) var size: String?

    @Environment(\.jsonRenderTheme) private var theme

    var body: some View {
        let side: CGFloat =
            switch size {
            case "sm": 16
            case "lg": 48
            default: 28
            }
        let value = CanvasServiceIcon(packID: pack, iconID: icon, label: "")
        Group {
            if (try? value.validate()) != nil {
                CanvasServiceIconImage(icon: value)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(theme.color.textMuted)
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel(Text("\(icon) icon"))
    }
}
