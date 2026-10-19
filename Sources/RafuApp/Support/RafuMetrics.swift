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

    // Compact semantic workbench tier (ADR 0022, amended by the frame+card
    // redesign). These values describe structure, not theme color, and
    // deliberately leave radiusPanel intact.
    /// 10 pt (design polish round 2, up from 8) so the stronger deck shadow's
    /// radius + y-offset still fits inside the frame gutter.
    static let workbenchInset: CGFloat = 10
    static let editorGroupGapTarget: CGFloat = 4
    static let radiusWorkbenchDeck: CGFloat = 12
    static let radiusEditorGroup: CGFloat = 5
    /// Soft shadow cast by the raised workbench deck onto the frame beneath
    /// it (frame + card redesign, phase 1). Radius + vertical offset stay
    /// inside `workbenchInset` so the deck lane's gutter never clips the
    /// shadow. Window redesign phase 4 adds the second, lighter shadow this
    /// comment deferred: the selected tab card below reuses
    /// `WorkbenchDeckShadowStyle`'s theme-aware color with its own, smaller
    /// radius/offset. Design polish round 2 raised the deck's reach from
    /// 6 + 2 to 7 + 3 so the card visibly lifts off the darker Indigo frame;
    /// 7 + 3 = 10 is the most the 10 pt inset holds.
    static let deckShadowRadius: CGFloat = 7
    static let deckShadowY: CGFloat = 3
    /// Window redesign phase 4: tabs are detached rounded cards, not attached
    /// caps.
    static let radiusWorkbenchTab: CGFloat = 10
    static let tabShadowRadius: CGFloat = 3
    static let tabShadowY: CGFloat = 1
    /// Tab title size: 12.5 pt, semibold when selected and medium otherwise,
    /// for every tab kind (set once in `AttachedWorkbenchTab`).
    static let tabLabelFontSize: CGFloat = 12.5
    /// Breathing room above/below the floating tab card, each side, inside
    /// its shelf.
    static let tabShelfBreathingRoom: CGFloat = 5
    /// Shelf floor: a 28 pt tab plus `tabShelfBreathingRoom` on both sides.
    static let tabShelfHeight: CGFloat = 38
    /// The breadcrumb row under the tab shelf. With the crumb button's own
    /// 6 pt inset, the 12 pt padding puts the first crumb's text in line
    /// with the first tab card's content (strip margin 8 + tab padding 8).
    static let breadcrumbHeight: CGFloat = 26
    static let breadcrumbHorizontalPadding: CGFloat = 12
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
