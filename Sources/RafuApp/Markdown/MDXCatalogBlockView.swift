import JSONRenderCore
import JSONRenderStandardCatalog
import JSONRenderSwiftUI
import SwiftUI

/// The theme every MDX block renders with. Until the Rafu theme mapping
/// lands, the package's native theme stands in; this is the one place to
/// change it.
enum MDXCatalogTheme {
    static func current(_ palette: RafuThemePalette) -> JSONRenderTheme {
        .native
    }
}

/// Draws one bridged MDX block through `JSONRenderView` with `RafuCatalog.rafu`.
/// The `Spec` was built off the main actor with the block (`MDXBlockBuilder`);
/// this view only holds it. A block with no valid spec (a bridge error, caught
/// by tests) draws as the plain fallback block.
struct MDXCatalogBlockView: View {
    let block: MDXBlock
    let baseURL: URL

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if let spec = block.catalogSpec {
            JSONRenderView(spec: spec, catalog: .rafu)
                .jsonRenderTheme(MDXCatalogTheme.current(theme.palette))
                .jrCardStyle(MDXCardStyle())
                .environment(\.rafuDocumentBaseURL, baseURL)
                // A document may show any local image, as the preview always did.
                .environment(\.jrLocalImageRoots, [URL(filePath: "/")])
        } else {
            MDXFallbackBlock(block: block, baseURL: baseURL)
        }
    }
}

/// Draws the standard `Card` the way an MDX `Phase` always looked: a framed
/// header with a symbol, the title, and the status as a chip.
nonisolated struct MDXCardStyle: JRCardStyle {
    @MainActor
    func makeBody(configuration: JRCardStyleConfiguration) -> some View {
        RafuDocumentFrame(showsHeader: configuration.title != nil) {
            if let title = configuration.title {
                RafuDocumentHeader(
                    systemImage: "square.stack", title: title, badge: configuration.description)
            }
        } content: {
            if configuration.hasContent {
                VStack(alignment: .leading, spacing: 12) {
                    configuration.content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
