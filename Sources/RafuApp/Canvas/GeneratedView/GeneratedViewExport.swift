import JSONRenderCore
import JSONRenderSwiftUI
import SwiftUI

/// A generated view drawn for an export (PNG, PDF, GIF frames). It renders
/// the spec with a fresh model seeded from the saved state (or the spec's own
/// seed); controls show their resting look. `ImageRenderer` draws it inside
/// the export scene, so there is no live store, no action, and no task.
struct GeneratedViewExportFace: View {
    let view: CanvasGeneratedView
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let jsonTheme = GeneratedViewThemeCache.theme(for: theme)
        Group {
            if let model = Self.renderModel(for: view) {
                JSONRenderView(model: model)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                CanvasDiagramSummaryText(text: "This view cannot be shown", lines: 2)
            }
        }
        .background(jsonTheme.color.surface)
        .jsonRenderTheme(jsonTheme)
    }

    /// `RenderModel` reads its first state from the spec, so the saved state
    /// (when it applies) replaces the spec's seed before the model is built.
    static func renderModel(for view: CanvasGeneratedView) -> RenderModel? {
        guard var spec = try? Spec.decode(Data(view.specJSON.utf8)).spec else { return nil }
        if let saved = GeneratedViewStatePersistence.applicableState(
            view.state, specVersion: GeneratedViewStatePersistence.specVersion(of: spec),
            catalogVersion: RafuCatalog.version)
        {
            spec.state = saved
        }
        return RenderModel(spec: spec, catalog: RafuCatalog.rafu)
    }
}
