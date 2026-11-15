import Foundation

/// The Terminals panel as a native `List` (direction A, "Quiet list"): the
/// flat, visible row order, the per-window group expansion, the keyboard map,
/// and how the list selection follows the current terminal. Pure data, so the
/// view only binds it and every rule is headless-testable.
///
/// Groups are drawn as flat rows with their own chevron, not as a system
/// `DisclosureGroup`: one default-style group would make SwiftUI back the
/// whole `List` with an `NSOutlineView` (see
/// `docs/references/list-custom-disclosure-group-style.md`), and a selected
/// row under a collapsed system group draws a phantom highlight (the Files
/// tree comment in `WorkspaceSidebarView`). A collapsed group simply emits no
/// pane rows, and a pane selection moves to its group first.
nonisolated enum TerminalsPanelListModel {
    /// One row of the list, in visual order. The selection tag is `id`; it
    /// comes from the terminal's identity only, so a rename or a status
    /// change never changes it.
    enum Row: Identifiable, Equatable, Sendable {
        /// A Terminal Group. `isDisclosable` is true when it has more than one
        /// pane; a one-pane group shows no pane rows and no chevron.
        case group(
            TerminalsPanelModel.TerminalGroupRow,
            panes: [TerminalsPanelModel.TerminalPaneRow],
            isDisclosable: Bool,
            isExpanded: Bool)
        case pane(TerminalsPanelModel.TerminalPaneRow)
        case legacy(TerminalSessionRow, isCurrent: Bool)

        var id: String {
            switch self {
            case .group(let row, _, _, _): TerminalsPanelListModel.groupRowID(row.id)
            case .pane(let row): TerminalsPanelListModel.paneRowID(row.id)
            case .legacy(let row, _): TerminalsPanelListModel.legacyRowID(row.id)
            }
        }
    }

    // MARK: Identity

    /// Selection tags, built from the raw UUID only. The prefix keeps a group,
    /// a pane, a session, and a saved layout apart in one `String` selection.
    static func groupRowID(_ id: TerminalGroupID) -> String { "group-\(id.rawValue.uuidString)" }
    static func paneRowID(_ id: TerminalPaneID) -> String { "pane-\(id.rawValue.uuidString)" }
    static func legacyRowID(_ id: UUID) -> String { "legacy-\(id.uuidString)" }
    static func savedRowID(_ id: SavedTerminalGroupID) -> String {
        "saved-\(id.rawValue.uuidString)"
    }
    /// The Saved Terminal Groups header row. It is selectable, so the
    /// keyboard can open and close the section.
    static let savedHeaderRowID = "saved-header"

    static func isSavedLayoutRowID(_ id: String) -> Bool {
        id.hasPrefix("saved-") && id != savedHeaderRowID
    }

    // MARK: Visible rows

    /// The flat list in visual order. Each group is followed by its pane rows
    /// when it has more than one pane and is expanded.
    static func visibleRows(
        _ rows: [TerminalsPanelModel.HierarchyRow],
        collapsedGroupIDs: Set<TerminalGroupID>
    ) -> [Row] {
        var panesByGroup: [TerminalGroupID: [TerminalsPanelModel.TerminalPaneRow]] = [:]
        for case .pane(let pane) in rows { panesByGroup[pane.groupID, default: []].append(pane) }
        var result: [Row] = []
        for row in rows {
            switch row {
            case .group(let group):
                let panes = panesByGroup[group.id] ?? []
                let isDisclosable = panes.count > 1
                let isExpanded = isDisclosable && !collapsedGroupIDs.contains(group.id)
                result.append(
                    .group(
                        group, panes: panes, isDisclosable: isDisclosable, isExpanded: isExpanded))
                if isExpanded { result += panes.map(Row.pane) }
            case .pane:
                // Emitted after its group above.
                continue
            case .legacy(let legacy, let isCurrent):
                result.append(.legacy(legacy, isCurrent: isCurrent))
            }
        }
        return result
    }

    // MARK: Expansion (per window)

    /// The `@SceneStorage` key for the collapsed groups. Groups default to
    /// expanded, so only the collapsed ones are stored.
    static let expansionStorageKey = "terminals.groups.collapsed"

    /// Decodes the stored value: UUID strings joined by commas. Unknown or
    /// malformed parts are dropped.
    static func collapsedGroupIDs(fromStored raw: String) -> Set<TerminalGroupID> {
        Set(
            raw.split(separator: ",").compactMap { part in
                UUID(uuidString: String(part)).map { TerminalGroupID(rawValue: $0) }
            })
    }

    /// Encodes the collapsed set in a stable (sorted) order, so the same set
    /// always writes the same string.
    static func storedValue(collapsedGroupIDs: Set<TerminalGroupID>) -> String {
        collapsedGroupIDs.map(\.rawValue.uuidString).sorted().joined(separator: ",")
    }

    /// The collapsed set after a toggle, pruned to groups that still exist so
    /// the stored string does not grow with closed groups.
    static func toggled(
        _ groupID: TerminalGroupID,
        expand: Bool,
        in collapsed: Set<TerminalGroupID>,
        liveGroupIDs: Set<TerminalGroupID>
    ) -> Set<TerminalGroupID> {
        var next = collapsed.intersection(liveGroupIDs)
        if expand { next.remove(groupID) } else { next.insert(groupID) }
        return next
    }

    // MARK: Keyboard

    enum Key: Equatable, Sendable {
        case returnKey
        case space
        case leftArrow
        case rightArrow
    }

    enum KeyAction: Equatable, Sendable {
        /// Open or focus the row: reveal a group or session, reveal and focus
        /// a pane, open a saved layout.
        case open(String)
        case expand(TerminalGroupID)
        case collapse(TerminalGroupID)
        /// Move the selection (Left on a pane goes to its group; Right on an
        /// expanded group goes to its first pane).
        case select(String)
        /// Open or close the Saved Terminal Groups section.
        case setSavedExpanded(Bool)
        case none
    }

    /// Return and Space open the selected row. Left and Right open and close a
    /// group, and move between a group and its panes, as in a Finder outline.
    /// On the Saved Terminal Groups header, Return and Space toggle the
    /// section and Left and Right close and open it. Up and Down are the
    /// `List`'s own. With no selection nothing happens.
    static func action(
        for key: Key, selection: String?, rows: [Row], isSavedExpanded: Bool = false
    ) -> KeyAction {
        guard let selection else { return .none }
        if selection == savedHeaderRowID {
            switch key {
            case .returnKey, .space: return .setSavedExpanded(!isSavedExpanded)
            case .leftArrow: return isSavedExpanded ? .setSavedExpanded(false) : .none
            case .rightArrow: return isSavedExpanded ? .none : .setSavedExpanded(true)
            }
        }
        let row = rows.first { $0.id == selection }
        switch key {
        case .returnKey, .space:
            // A saved-layout row is not in `rows`; it still opens.
            return row == nil && !isSavedLayoutRowID(selection) ? .none : .open(selection)
        case .leftArrow:
            switch row {
            case .group(let group, _, true, true): return .collapse(group.id)
            case .pane(let pane): return .select(groupRowID(pane.groupID))
            default: return .none
            }
        case .rightArrow:
            switch row {
            case .group(let group, _, true, false): return .expand(group.id)
            case .group(_, let panes, true, true):
                return panes.first.map { .select(paneRowID($0.id)) } ?? .none
            default: return .none
            }
        }
    }

    // MARK: Selection

    /// The row of the terminal shown in the editor, if any.
    static func currentRowID(_ rows: [Row]) -> String? {
        for row in rows {
            switch row {
            case .group(let group, _, _, _) where group.isCurrent: return row.id
            case .legacy(_, true): return row.id
            default: continue
            }
        }
        return nil
    }

    /// The selection after the current terminal changes: it follows the
    /// current row, but a selected pane of the current group stays selected
    /// (a click on a pane reveals its group and must not jump to it). With no
    /// current row the selection is kept.
    static func selectionFollowingCurrent(
        _ currentRowID: String?, selection: String?, rows: [Row]
    ) -> String? {
        guard let currentRowID else { return selection }
        if let selection,
            case .pane(let pane)? = rows.first(where: { $0.id == selection }),
            groupRowID(pane.groupID) == currentRowID
        {
            return selection
        }
        return currentRowID
    }

    /// The selection after a group collapses: a selected pane of that group
    /// moves to the group row, so no hidden row stays selected.
    static func selectionAfterCollapsing(
        _ groupID: TerminalGroupID, paneIDs: [TerminalPaneID], selection: String?
    ) -> String? {
        guard let selection, paneIDs.contains(where: { paneRowID($0) == selection }) else {
            return selection
        }
        return groupRowID(groupID)
    }
}
