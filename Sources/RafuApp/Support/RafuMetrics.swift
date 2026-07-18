import CoreGraphics

/// Geometry and rhythm constants for the flat, layered workbench (UI plan
/// U0). These are product-identity values — deliberately code-side, not
/// theme-JSON, so shape stays consistent across every theme while color stays
/// the theme's to own. Corner styles are always `.continuous`.
enum RafuMetrics {
    // Corner radii, one scale across the app.
    /// Panels, overlays, embedded content cards (command palette, peek,
    /// code blocks, composer).
    static let radiusPanel: CGFloat = 12
    /// Buttons, segments, small interactive controls.
    static let radiusControl: CGFloat = 7
    /// Filled form inputs and search/palette fields.
    static let radiusField: CGFloat = 8
    /// Capsule chips/badges/kbd hints.
    static let radiusChip: CGFloat = 999

    // Spacing grid.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20

    // Vertical rhythm.
    /// Standard list/tree/command row height.
    static let rowHeight: CGFloat = 27
    /// Section header row height (leading glyph + title + trailing action).
    static let sectionHeaderHeight: CGFloat = 34
    /// Slim status bar height.
    static let statusBarHeight: CGFloat = 24
    /// Editor tab strip height.
    static let tabBarHeight: CGFloat = 28

    /// Hairline width for tonal-step dividers and control borders. A single
    /// device pixel is drawn at the layer level; 1pt is the SwiftUI stroke.
    static let hairline: CGFloat = 1
}
