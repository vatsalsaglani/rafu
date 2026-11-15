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
    /// The frame gutter round the deck card, per edge (`WorkbenchDeckLane`).
    /// History: 8 → 10 (round 2) → 12 on every side (round 4) → per edge
    /// 6/6/8/12 (window gap tightening, 2026-11-15) → the values below
    /// (window gap tightening 2, same day: the user still saw the old gaps).
    /// The deck shadow (radius 8, y 4) decides each edge:
    /// - top 2: the shadow reaches `radius - y` = 4 above the card, so 2 pt
    ///   of it spills under the titlebar row. The row is drawn before the
    ///   workbench row, so the spill paints over it and is not cut; it stays
    ///   below the row's 20 pt search field.
    /// - leading 8 beside an open sidebar: the shadow reaches `radius` = 8
    ///   sideways, and the opaque sidebar is drawn above the deck. The split
    ///   handle takes no layout width; it is an overlay on the seam.
    /// - beside a collapsed sidebar: `deckGapCollapsedRail` instead (below).
    /// - trailing 8: the shadow reaches `radius` = 8 sideways, and the window
    ///   edge would clip anything past it;
    /// - bottom 12: the shadow reaches `radius + y` = 12 below the card,
    ///   where the opaque status bar would cut it.
    static let deckInsetTop: CGFloat = 2
    static let deckInsetLeading: CGFloat = 8
    static let deckInsetTrailing: CGFloat = 8
    static let deckInsetBottom: CGFloat = 12
    /// Rail icon trailing edge → deck card while the sidebar is collapsed
    /// (was 13: the rail's 3 pt deck side plus the handle's 10 pt). The
    /// rail paints no fill of its own (the workbench row does), so the deck
    /// shadow shows under the rail's empty strip instead of being cut.
    static let deckGapCollapsedRail: CGFloat = 5
    static let editorGroupGapTarget: CGFloat = 4
    static let radiusWorkbenchDeck: CGFloat = 12
    static let radiusEditorGroup: CGFloat = 5
    /// Soft shadow cast by the raised workbench deck onto the frame beneath
    /// it (frame + card redesign, phase 1). Its reach on each edge stays
    /// inside that edge's `deckInset*` gutter (see there), so nothing clips
    /// or cuts the shadow. Window redesign phase 4 adds the second, lighter shadow this
    /// comment deferred: the selected tab card below reuses
    /// `WorkbenchDeckShadowStyle`'s theme-aware color with its own, smaller
    /// radius/offset. Design polish round 2 raised the deck's reach from
    /// 6 + 2 to 7 + 3 so the card visibly lifts off the darker Indigo frame;
    /// round 4 raised it again to 8 + 4 (with the inset 10 → 12) so the card
    /// reads clearly raised; 8 + 4 = 12 is the most the 12 pt bottom inset
    /// holds.
    static let deckShadowRadius: CGFloat = 8
    static let deckShadowY: CGFloat = 4
    /// Window redesign phase 4: tabs are detached rounded cards, not attached
    /// caps.
    static let radiusWorkbenchTab: CGFloat = 10
    /// Design polish round 3: 3 → 4, so the selected tab lifts off the
    /// Khadi shelf. Radius + `tabShadowY` stays within
    /// `tabShelfBreathingRoom`, so the shelf never clips it.
    static let tabShadowRadius: CGFloat = 4
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
    /// Every navigator panel header (Files, Search, Source Control,
    /// Terminals, History) puts its title's centre this far below the
    /// sidebar pane's top: the deck card's top inset plus half its tab shelf,
    /// which is where the editor tab labels' centre sits. Applied only
    /// through `View.rafuNavigatorHeaderPlacement(rowHeight:)` (ADR 0031
    /// §g, round 5), so the headers cannot drift apart again.
    static let navigatorHeaderTitleCenterY: CGFloat = deckInsetTop + tabShelfHeight / 2

    /// The space above a navigator header row of `rowHeight` that puts the
    /// row's centre on `navigatorHeaderTitleCenterY`.
    static func navigatorHeaderTopInset(rowHeight: CGFloat) -> CGFloat {
        max(0, navigatorHeaderTitleCenterY - rowHeight / 2)
    }
    static let breadcrumbHorizontalPadding: CGFloat = 12
    static let radiusDenseSelection: CGFloat = 4
    static let radiusDenseCard: CGFloat = 6
    static let radiusWorkbenchField: CGFloat = 5
    static let radiusTransientPopover: CGFloat = 8
    static let utilityBodyInset: CGFloat = 8
    /// The sidebar's one text left edge: every navigator panel header title,
    /// secondary row and list row starts this far from the pane edge (the
    /// Files tree's own inset).
    static let sidebarTextInset: CGFloat = 10
    /// The one navigator panel header row (Files, Search, Source Control,
    /// Terminals, History): a 24 pt row with no fill, whose centre
    /// `rafuNavigatorHeaderPlacement(rowHeight:)` puts on the tab-label line.
    static let navigatorHeaderRowHeight: CGFloat = 24
    /// Space between a navigator panel header and the first content row.
    /// Space, not a hairline or a fill, separates the two.
    static let navigatorHeaderBottomSpacing: CGFloat = 8
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
