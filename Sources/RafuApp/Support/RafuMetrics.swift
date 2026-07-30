import CoreGraphics

/// Geometry and rhythm constants for the flat, layered workbench (UI plan
/// U0). These are product-identity values — deliberately code-side, not
/// theme-JSON, so shape stays consistent across every theme while color stays
/// the theme's to own. Corner styles are always `.continuous`.
nonisolated enum RafuMetrics {
    // Existing overlay/control radii.
    /// Panels, overlays, embedded content cards (command palette, peek,
    /// code blocks, composer).
    static let radiusPanel: CGFloat = 12
    /// Buttons, segments, small interactive controls.
    static let radiusControl: CGFloat = 7
    /// Filled form inputs and search/palette fields.
    static let radiusField: CGFloat = 8
    /// Capsule chips/badges/kbd hints.
    static let radiusChip: CGFloat = 999

    // Compact semantic workbench tier (ADR 0022). These values describe
    // structure, not theme color, and deliberately leave radiusPanel intact.
    static let workbenchInset: CGFloat = 4
    static let editorGroupGapTarget: CGFloat = 4
    static let radiusWorkbenchDeck: CGFloat = 6
    static let radiusEditorGroup: CGFloat = 5
    static let radiusAttachedTab: CGFloat = 4
    static let radiusDenseSelection: CGFloat = 4
    static let radiusDenseCard: CGFloat = 6
    static let radiusWorkbenchField: CGFloat = 5
    static let radiusTransientPopover: CGFloat = 8
    static let utilityBodyInset: CGFloat = 8
    static let settingsSectionInset: CGFloat = 14
    static let settingsRowMinHeight: CGFloat = 36
    static let settingsSectionGap: CGFloat = 28
    static let terminalBorderWidth: CGFloat = 1
    static let focusedTerminalBorderWidth: CGFloat = 2

    // Spacing grid.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    /// Custom-sheet outer padding (Stash/Worktree/File-creation/Quit/Trust/
    /// Install-consent sheets).
    static let sheetPadding: CGFloat = 22

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
