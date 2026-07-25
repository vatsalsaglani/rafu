import SwiftUI

struct MermaidDiagramView: View {
    let result: MermaidParseResult

    var body: some View {
        switch result {
        case .diagram(let diagram):
            MermaidRasterDiagramView(diagram: diagram)
        case .unsupported(let type, let raw):
            MermaidUnsupportedView(type: type, raw: raw, reason: nil)
        case .malformed(let type, let raw, let reason):
            MermaidUnsupportedView(type: type, raw: raw, reason: reason)
        }
    }
}

/// The badge-chrome card every successfully rendered (or still-rendering)
/// diagram sits in. Kept as a free function rather than a method so the
/// failure branch of `MermaidRasterDiagramView` can render
/// `MermaidUnsupportedView` OUTSIDE this chrome, matching how `.unsupported`
/// and `.malformed` render at the top level.
@ViewBuilder
private func mermaidDiagramCard<Content: View>(
    theme: RafuTheme, @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Label("Native Mermaid preview", systemImage: "point.3.connected.trianglepath.dotted")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(rafuHex: theme.ui.accent))
            .help("Rendered natively from a bounded Mermaid subset — not mermaid.js")
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
        Color(rafuHex: theme.ui.elevatedBackground),
        in: .rect(cornerRadius: 12)
    )
    .overlay {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color(rafuHex: theme.ui.borderSubtle))
    }
}

/// `.task(id:)` key for `MermaidRasterDiagramView`: a raster must be
/// recomputed when the (normalised) source changes, when the resolved theme
/// changes (light/dark toggle, user theme switch), or when the display's
/// backing scale changes (e.g. a window drags between a Retina and a
/// non-Retina display) — but never on every view re-body, since `Equatable`
/// short-circuits `.task(id:)` to a no-op when the key is unchanged.
private struct MermaidRasterKey: Equatable {
    let source: String
    let theme: MermaidThemeSpec
    let scale: CGFloat
}

/// Renders one Mermaid diagram via `MermaidRenderService`: an off-main actor
/// that owns BeautifulMermaid's parse/layout/rasterise pipeline (ADR 0020).
/// No `BeautifulMermaid` type appears here — only the actor's `Sendable`
/// `Raster` value and `Failure` enum cross back, per the two-file
/// confinement rule (`MermaidTheme.swift`, `MermaidRenderService.swift` are
/// the only files allowed to `import BeautifulMermaid`).
///
/// State machine: pending (no raster, no failure) shows a minimal
/// zero-reflow placeholder inside the badge chrome; success shows the raster
/// inside the badge chrome; failure shows `MermaidUnsupportedView` with a
/// Rafu-authored reason, entirely OUTSIDE the badge chrome — matching how a
/// `.unsupported`/`.malformed` diagram renders. Never a blank box, never a
/// silently wrong diagram.
struct MermaidRasterDiagramView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    let diagram: MermaidDiagram

    @State private var raster: MermaidRenderService.Raster?
    @State private var failureReason: String?

    var body: some View {
        Group {
            if let failureReason {
                MermaidUnsupportedView(
                    type: diagram.declaredType, raw: diagram.raw, reason: failureReason)
            } else {
                mermaidDiagramCard(theme: theme) {
                    if let raster {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Image(decorative: raster.image, scale: raster.scale)
                                .resizable()
                                .interpolation(.high)
                                .frame(
                                    width: raster.pointSize.width,
                                    height: raster.pointSize.height)
                        }
                        .frame(height: raster.pointSize.height)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(raster.accessibilityLabel)
                    } else {
                        // Placeholder while the off-main render lands; a fixed
                        // minimal height avoids a reflow jump once it resolves.
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
        .task(
            id: MermaidRasterKey(
                source: diagram.source, theme: MermaidThemeSpec(theme: theme), scale: displayScale)
        ) {
            let spec = MermaidThemeSpec(theme: theme)
            do {
                let result = try await MermaidRenderService.shared.raster(
                    for: diagram, theme: spec, scale: displayScale)
                raster = result
                failureReason = nil
            } catch is CancellationError {
                // A newer `.task(id:)` superseded this one; leave state alone.
            } catch let failure as MermaidRenderService.Failure {
                raster = nil
                failureReason = MermaidRenderService.reason(for: failure)
            } catch {
                raster = nil
                failureReason = "this diagram could not be rendered"
            }
        }
    }
}

struct MermaidUnsupportedView: View {
    @Environment(\.rafuTheme) private var theme
    let type: String
    let raw: String
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(noticeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(rafuHex: theme.ui.warning ?? theme.ui.textSecondary))
            Text(raw)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color(rafuHex: theme.ui.textPrimary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(rafuHex: theme.ui.elevatedBackground),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(rafuHex: theme.ui.borderSubtle))
        }
    }

    private var noticeText: String {
        if let reason {
            return "diagram type not supported in native preview — \(reason)"
        }
        return "diagram type not supported in native preview"
    }
}
