import Foundation

/// The direction used by Ctrl-Tab and the switcher's Left/Right keys.
///
/// This is a pure value so the wraparound behavior can be tested without
/// constructing a window or installing an AppKit event monitor.
nonisolated enum EditorTabSwitcherDirection: Equatable, Sendable {
    case backward
    case forward

    var offset: Int {
        switch self {
        case .backward: -1
        case .forward: 1
        }
    }
}

/// A window-local destination in the Ctrl-Tab switcher.
///
/// Terminal sessions use their session id rather than their editor-tab id.
/// That lets the same destination select a presented terminal tab or reveal a
/// parked session without duplicating it in the switcher.
nonisolated enum EditorTabSwitcherDestination: Hashable, Sendable {
    case editorTab(tabID: EditorTabID, groupID: EditorGroupID)
    case terminal(sessionID: UUID)
    /// Additive identity only. TG-30 creates candidates and activation
    /// behavior; TG-10 must not select a group or start a process.
    case terminalGroup(groupID: TerminalGroupID)
}

nonisolated struct EditorTabSwitcherCandidate: Equatable, Identifiable, Sendable {
    let destination: EditorTabSwitcherDestination

    var id: EditorTabSwitcherDestination { destination }
}

/// Pure textual presentation for one compound Terminal Group candidate.
/// Keeping this outside the overlay makes the group-only switcher contract
/// testable without constructing a SwiftUI view or mounting a terminal.
nonisolated struct EditorTerminalGroupSwitcherPresentation: Equatable, Sendable {
    let title: String
    let detail: String

    init(name: String, paneCount: Int, focusedPaneName: String, attentionCount: Int, isParked: Bool)
    {
        title = name
        let placement = isParked ? "Parked" : "Terminal Group"
        let attention = attentionCount == 0 ? "" : " · \(attentionCount) need attention"
        detail = "\(placement) · \(paneCount) panes · Focused: \(focusedPaneName)\(attention)"
    }
}

/// Ephemeral selection state for the window's Ctrl-Tab overlay.
///
/// Selection is only previewed here. The editor layout is changed once, when
/// Control is released (or Return/a candidate click commits), so holding
/// Control and browsing with Left/Right never churns hibernation or workspace
/// persistence.
nonisolated struct EditorTabSwitcherState: Equatable, Sendable {
    let candidates: [EditorTabSwitcherCandidate]
    private(set) var selectedIndex: Int

    init?(
        candidates: [EditorTabSwitcherCandidate],
        current: EditorTabSwitcherDestination?,
        direction: EditorTabSwitcherDirection
    ) {
        guard candidates.count > 1 else { return nil }
        self.candidates = candidates

        let currentIndex = current.flatMap { destination in
            candidates.firstIndex(where: { $0.destination == destination })
        }
        let baseIndex =
            currentIndex
            ?? (direction == .forward ? -1 : 0)
        selectedIndex = Self.wrappedIndex(
            baseIndex + direction.offset,
            count: candidates.count
        )
    }

    var selectedCandidate: EditorTabSwitcherCandidate {
        candidates[selectedIndex]
    }

    mutating func move(_ direction: EditorTabSwitcherDirection) {
        selectedIndex = Self.wrappedIndex(
            selectedIndex + direction.offset,
            count: candidates.count
        )
    }

    mutating func select(_ destination: EditorTabSwitcherDestination) {
        guard let index = candidates.firstIndex(where: { $0.destination == destination }) else {
            return
        }
        selectedIndex = index
    }

    private static func wrappedIndex(_ index: Int, count: Int) -> Int {
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }
}
