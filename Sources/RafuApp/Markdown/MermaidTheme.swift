import BeautifulMermaid
import CoreGraphics

/// A `Sendable`, value-type snapshot of the seven `DiagramTheme` color slots
/// (plus point size and transparency), expressed as hex strings so it can
/// cross actor boundaries freely. `MermaidRenderService` (the only other
/// file allowed to `import BeautifulMermaid`, per ADR 0020's two-file
/// confinement rule) constructs the actual `DiagramTheme` from this spec
/// inside its actor isolation domain — `DiagramTheme` itself is
/// `@unchecked Sendable` upstream and is never shared across actors.
///
/// `Hashable` so the render-service cache key and `.task(id:)` can include it
/// without a manual `Equatable` conformance.
nonisolated struct MermaidThemeSpec: Sendable, Hashable {
    let background: String
    let foreground: String
    let line: String
    let accent: String
    let muted: String
    let surface: String
    let border: String
    let pointSize: CGFloat
    let transparent: Bool

    /// Slot choices, deliberately (ADR 0020 theme mapping table):
    /// - `line`/`accent` both use `textSecondary` — edges and arrowheads are
    ///   structure, not meaning; the theme accent stays reserved for meaning
    ///   per the AGENTS.md "reserve color for meaning" rule.
    /// - `surface` uses `ui.selection`, not `elevatedBackground` — the
    ///   diagram card background is already `elevatedBackground`
    ///   (`MermaidDiagramView.swift`), so nodes painted in that same color
    ///   would be invisible. This is a deliberate deviation from the spike's
    ///   `RafuMermaidTheme`, which mapped `surface` to `elevatedBackground`.
    /// - `muted`/`border` fall back to `textSecondary`/`borderSubtle` because
    ///   `RafuTheme.UIColors.textMuted`/`borderStrong` are optional tokens,
    ///   mirroring the fallback `RafuThemePalette` already applies.
    init(theme: RafuTheme) {
        background = theme.ui.elevatedBackground
        foreground = theme.ui.textPrimary
        line = theme.ui.textSecondary
        accent = theme.ui.textSecondary
        muted = theme.ui.textMuted ?? theme.ui.textSecondary
        surface = theme.ui.selection
        border = theme.ui.borderStrong ?? theme.ui.borderSubtle
        pointSize = 13
        transparent = true
    }
}

/// Bridges `MermaidThemeSpec` onto `BeautifulMermaid.DiagramTheme`. Confined
/// (with `MermaidRenderService.swift`) to the two files ADR 0020 permits to
/// `import BeautifulMermaid` — no package type may appear in
/// `MarkdownModels.swift`, `MermaidDiagramView.swift`, or any test signature.
nonisolated enum RafuMermaidTheme {
    static func diagramTheme(_ spec: MermaidThemeSpec) -> DiagramTheme {
        DiagramTheme(
            background: BMColor(hex: spec.background),
            foreground: BMColor(hex: spec.foreground),
            line: BMColor(hex: spec.line),
            accent: BMColor(hex: spec.accent),
            muted: BMColor(hex: spec.muted),
            surface: BMColor(hex: spec.surface),
            border: BMColor(hex: spec.border),
            font: BMFont.systemFont(ofSize: spec.pointSize),
            lineWidth: 1.5,
            cornerRadius: 6,
            // Let the Markdown preview's own card background show through
            // instead of painting an opaque block inside the document flow.
            transparent: spec.transparent
        )
    }
}
