import SwiftUI

/// Which window edge holds the Activity Rail and the sidebar. On the trailing
/// edge the order is deck, sidebar, rail, so the sidebar opens toward the
/// leading side. A per-user preference shared by every window; it is not part
/// of workspace restoration.
nonisolated enum WorkbenchSidebarEdge: String, Sendable, CaseIterable {
    case leading
    case trailing

    /// The edge a reader falls back to for a missing or unknown stored value.
    static let standard: WorkbenchSidebarEdge = .leading

    /// Reads a stored raw value. Anything unknown means the standard edge, so
    /// a value from a newer build never leaves the rail without a place.
    static func resolve(raw: String?) -> WorkbenchSidebarEdge {
        raw.flatMap(WorkbenchSidebarEdge.init(rawValue:)) ?? standard
    }

    var opposite: WorkbenchSidebarEdge {
        self == .leading ? .trailing : .leading
    }

    /// The View menu and command palette title of the move command: it names
    /// the edge the sidebar goes to, not the one it is on.
    var moveCommandTitle: String {
        self == .leading ? "Move Sidebar to Right" : "Move Sidebar to Left"
    }

    /// Where the rail and sidebar sit, as a SwiftUI alignment for overlays
    /// that follow the seam (the split handle).
    var seamOverlayAlignment: Alignment {
        self == .leading ? .topLeading : .topTrailing
    }

    var frameAlignment: Alignment {
        self == .leading ? .leading : .trailing
    }

    /// The signed horizontal offset of the seam's hit area from its overlay
    /// alignment edge. `distance` is measured from the window edge that holds
    /// the rail, toward the deck, so the same number is a positive offset on
    /// the leading edge and a negative one on the trailing edge.
    func seamOffset(distance: CGFloat) -> CGFloat {
        self == .leading ? distance : -distance
    }
}

/// The saved workbench layout choices that are per user, not per workspace.
nonisolated enum WorkbenchLayoutPreferences {
    static let sidebarEdgeKey = "workbench.sidebarEdge"

    static func sidebarEdge(in defaults: UserDefaults = .standard) -> WorkbenchSidebarEdge {
        WorkbenchSidebarEdge.resolve(raw: defaults.string(forKey: sidebarEdgeKey))
    }

    /// Moves the rail and sidebar to the other edge and returns the new edge.
    @discardableResult
    static func toggleSidebarEdge(in defaults: UserDefaults = .standard) -> WorkbenchSidebarEdge {
        let next = sidebarEdge(in: defaults).opposite
        defaults.set(next.rawValue, forKey: sidebarEdgeKey)
        return next
    }
}

/// The two shortcuts this feature adds, in one place so the menu, the palette,
/// the VoiceOver announcement and the decision record agree.
nonisolated enum WorkbenchLayoutShortcuts {
    /// ⌥⌘B: move the sidebar to the other edge (⌘B toggles it).
    static let moveSidebarLabel = "⌥⌘B"
    /// ⌃⌘Z: Zen mode.
    static let zenModeLabel = "⌃⌘Z"

    static func zenAnnouncement(isOn: Bool) -> String {
        isOn
            ? "Zen mode on. Press \(zenModeLabel) to leave."
            : "Zen mode off."
    }

    static func zenCommandTitle(isOn: Bool) -> String {
        isOn ? "Exit Zen Mode" : "Enter Zen Mode"
    }
}
