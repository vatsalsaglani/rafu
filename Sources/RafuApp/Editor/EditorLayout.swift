import Foundation

nonisolated struct EditorGroupID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct EditorSplitID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct EditorTabID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum EditorTabResource: Codable, Equatable, Sendable {
    case file(URL)
    case restorable(kind: String, key: String, title: String)
    /// A terminal tab (issue #4): presented with the same tab chrome as a
    /// file, but backed by a live `WorkspaceTerminalController` looked up by
    /// `sessionID` rather than an `EditorDocument`. Never restorable — see
    /// `isRestorable`.
    case terminal(sessionID: UUID)

    /// Whether this resource is meaningful across a relaunch. Only an
    /// on-disk file tab is: a terminal tab's `sessionID` references a shell
    /// process that no longer exists once the app restarts (ADR 0004 —
    /// sessions are lazy and per-window, never persisted), and the
    /// speculative `.restorable` kind has no restoration path implemented
    /// yet either. `WorkspaceSession.restoreEditorLayout` drops any tab
    /// whose resource answers `false` here.
    var isRestorable: Bool {
        if case .file = self { return true }
        return false
    }
}

nonisolated struct EditorTabState: Codable, Equatable, Identifiable, Sendable {
    let id: EditorTabID
    var resource: EditorTabResource
    var isPinned: Bool

    init(
        id: EditorTabID = EditorTabID(),
        resource: EditorTabResource,
        isPinned: Bool = false
    ) {
        self.id = id
        self.resource = resource
        self.isPinned = isPinned
    }
}

nonisolated struct EditorGroupState: Codable, Equatable, Identifiable, Sendable {
    let id: EditorGroupID
    var tabs: [EditorTabState]
    var selectedTabID: EditorTabID?

    init(
        id: EditorGroupID = EditorGroupID(),
        tabs: [EditorTabState] = [],
        selectedTabID: EditorTabID? = nil
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedTabID =
            selectedTabID.flatMap { selected in
                tabs.contains(where: { $0.id == selected }) ? selected : nil
            } ?? tabs.first?.id
    }

    mutating func insert(_ tab: EditorTabState, at requestedIndex: Int? = nil) {
        if let existingIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: existingIndex)
        }
        let index = min(max(requestedIndex ?? tabs.endIndex, tabs.startIndex), tabs.endIndex)
        tabs.insert(tab, at: index)
        selectedTabID = tab.id
    }

    @discardableResult
    mutating func remove(_ tabID: EditorTabID) -> EditorTabState? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let removed = tabs.remove(at: index)
        if selectedTabID == tabID {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        return removed
    }
}

nonisolated enum EditorSplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

nonisolated enum EditorSplitEdge: String, Codable, Sendable {
    case leading
    case trailing
    case top
    case bottom

    var axis: EditorSplitAxis {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        }
    }

    var placesNewGroupFirst: Bool {
        self == .leading || self == .top
    }
}

nonisolated indirect enum EditorLayoutNode: Codable, Equatable, Sendable {
    case group(EditorGroupState)
    case split(
        id: EditorSplitID,
        axis: EditorSplitAxis,
        fraction: Double,
        first: EditorLayoutNode,
        second: EditorLayoutNode
    )

    var groupIDs: [EditorGroupID] {
        switch self {
        case .group(let group): [group.id]
        case .split(_, _, _, let first, let second): first.groupIDs + second.groupIDs
        }
    }

    func group(id: EditorGroupID) -> EditorGroupState? {
        switch self {
        case .group(let group): group.id == id ? group : nil
        case .split(_, _, _, let first, let second): first.group(id: id) ?? second.group(id: id)
        }
    }

    func group(containing tabID: EditorTabID) -> EditorGroupState? {
        switch self {
        case .group(let group): group.tabs.contains(where: { $0.id == tabID }) ? group : nil
        case .split(_, _, _, let first, let second):
            first.group(containing: tabID) ?? second.group(containing: tabID)
        }
    }

    fileprivate mutating func updateGroup(
        id: EditorGroupID,
        _ update: (inout EditorGroupState) -> Void
    ) -> Bool {
        switch self {
        case .group(var group):
            guard group.id == id else { return false }
            update(&group)
            self = .group(group)
            return true
        case .split(let splitID, let axis, let fraction, var first, var second):
            if first.updateGroup(id: id, update) {
                self = .split(
                    id: splitID, axis: axis, fraction: fraction, first: first, second: second)
                return true
            }
            if second.updateGroup(id: id, update) {
                self = .split(
                    id: splitID, axis: axis, fraction: fraction, first: first, second: second)
                return true
            }
            return false
        }
    }

    fileprivate mutating func replaceGroup(
        id groupID: EditorGroupID,
        with replacement: EditorLayoutNode
    ) -> Bool {
        switch self {
        case .group(let group):
            guard group.id == groupID else { return false }
            self = replacement
            return true
        case .split(let splitID, let axis, let fraction, var first, var second):
            if first.replaceGroup(id: groupID, with: replacement) {
                self = .split(
                    id: splitID, axis: axis, fraction: fraction, first: first, second: second)
                return true
            }
            if second.replaceGroup(id: groupID, with: replacement) {
                self = .split(
                    id: splitID, axis: axis, fraction: fraction, first: first, second: second)
                return true
            }
            return false
        }
    }

    fileprivate mutating func removeTab(_ tabID: EditorTabID) -> (
        tab: EditorTabState, groupID: EditorGroupID
    )? {
        switch self {
        case .group(var group):
            guard let tab = group.remove(tabID) else { return nil }
            let groupID = group.id
            self = .group(group)
            return (tab, groupID)
        case .split(let id, let axis, let fraction, var first, var second):
            if let result = first.removeTab(tabID) {
                self = .split(
                    id: id, axis: axis, fraction: fraction, first: first, second: second)
                return result
            }
            if let result = second.removeTab(tabID) {
                self = .split(
                    id: id, axis: axis, fraction: fraction, first: first, second: second)
                return result
            }
            return nil
        }
    }

    fileprivate mutating func collapseEmptyGroups() {
        switch self {
        case .group:
            return
        case .split(let id, let axis, let fraction, var first, var second):
            first.collapseEmptyGroups()
            second.collapseEmptyGroups()

            if first.isEmptyLeaf {
                self = second
            } else if second.isEmptyLeaf {
                self = first
            } else {
                self = .split(
                    id: id, axis: axis, fraction: fraction, first: first, second: second)
            }
        }
    }

    private var isEmptyLeaf: Bool {
        if case .group(let group) = self { return group.tabs.isEmpty }
        return false
    }
}

nonisolated struct EditorLayoutState: Codable, Equatable, Sendable {
    private(set) var root: EditorLayoutNode
    private(set) var focusedGroupID: EditorGroupID

    init(root: EditorLayoutNode? = nil, focusedGroupID: EditorGroupID? = nil) {
        let initialGroup = EditorGroupState()
        let resolvedRoot = root ?? .group(initialGroup)
        self.root = resolvedRoot
        self.focusedGroupID =
            focusedGroupID.flatMap { requested in
                resolvedRoot.groupIDs.contains(requested) ? requested : nil
            } ?? resolvedRoot.groupIDs.first ?? initialGroup.id
    }

    var groupIDs: [EditorGroupID] { root.groupIDs }

    func group(id: EditorGroupID) -> EditorGroupState? {
        root.group(id: id)
    }

    func group(containing tabID: EditorTabID) -> EditorGroupState? {
        root.group(containing: tabID)
    }

    func tab(matching resource: EditorTabResource) -> EditorTabState? {
        for groupID in groupIDs {
            if let tab = group(id: groupID)?.tabs.first(where: { $0.resource == resource }) {
                return tab
            }
        }
        return nil
    }

    mutating func focus(_ groupID: EditorGroupID) {
        guard root.group(id: groupID) != nil else { return }
        focusedGroupID = groupID
    }

    mutating func select(_ tabID: EditorTabID, in groupID: EditorGroupID) {
        guard root.group(id: groupID)?.tabs.contains(where: { $0.id == tabID }) == true else {
            return
        }
        _ = root.updateGroup(id: groupID) { $0.selectedTabID = tabID }
        focusedGroupID = groupID
    }

    mutating func updateResource(for tabID: EditorTabID, to resource: EditorTabResource) {
        guard let groupID = root.group(containing: tabID)?.id else { return }
        _ = root.updateGroup(id: groupID) { group in
            guard let index = group.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            group.tabs[index].resource = resource
        }
    }

    @discardableResult
    mutating func split(
        group groupID: EditorGroupID,
        at edge: EditorSplitEdge,
        moving tabID: EditorTabID? = nil,
        fraction: Double = 0.5
    ) -> EditorGroupID? {
        guard root.group(id: groupID) != nil else { return nil }

        var movedTab: EditorTabState?
        var sourceGroupID: EditorGroupID?
        if let tabID {
            guard let removed = root.removeTab(tabID) else { return nil }
            movedTab = removed.tab
            sourceGroupID = removed.groupID
        }

        guard let updatedTarget = root.group(id: groupID) else {
            restore(movedTab, to: sourceGroupID)
            return nil
        }

        let newGroup = EditorGroupState(tabs: movedTab.map { [$0] } ?? [])
        let oldNode = EditorLayoutNode.group(updatedTarget)
        let newNode = EditorLayoutNode.group(newGroup)
        let boundedFraction = min(max(fraction, 0.1), 0.9)
        let first = edge.placesNewGroupFirst ? newNode : oldNode
        let second = edge.placesNewGroupFirst ? oldNode : newNode
        let replacement = EditorLayoutNode.split(
            id: EditorSplitID(),
            axis: edge.axis,
            fraction: boundedFraction,
            first: first,
            second: second
        )

        guard root.replaceGroup(id: groupID, with: replacement) else {
            restore(movedTab, to: sourceGroupID)
            return nil
        }
        focusedGroupID = newGroup.id
        return newGroup.id
    }

    @discardableResult
    mutating func moveTab(
        _ tabID: EditorTabID,
        to destinationGroupID: EditorGroupID,
        at index: Int? = nil
    ) -> Bool {
        guard root.group(id: destinationGroupID) != nil,
            let removed = root.removeTab(tabID)
        else { return false }

        guard root.updateGroup(id: destinationGroupID, { $0.insert(removed.tab, at: index) }) else {
            restore(removed.tab, to: removed.groupID)
            return false
        }
        root.collapseEmptyGroups()
        focusedGroupID =
            root.group(id: destinationGroupID) != nil
            ? destinationGroupID : root.groupIDs.first ?? focusedGroupID
        return true
    }

    @discardableResult
    mutating func closeTab(_ tabID: EditorTabID) -> EditorTabState? {
        guard let removed = root.removeTab(tabID) else { return nil }
        root.collapseEmptyGroups()
        if root.group(id: focusedGroupID) == nil {
            focusedGroupID = root.groupIDs.first ?? removed.groupID
        }
        return removed.tab
    }

    mutating func collapseEmptyGroups() {
        root.collapseEmptyGroups()
        if root.group(id: focusedGroupID) == nil, let first = root.groupIDs.first {
            focusedGroupID = first
        }
    }

    mutating func insert(_ tab: EditorTabState, in groupID: EditorGroupID, at index: Int? = nil) {
        guard root.group(id: groupID) != nil else { return }
        let previous = root.removeTab(tab.id)
        guard root.updateGroup(id: groupID, { $0.insert(tab, at: index) }) else {
            restore(previous?.tab, to: previous?.groupID)
            return
        }
        root.collapseEmptyGroups()
        focusedGroupID = groupID
    }

    private mutating func restore(_ tab: EditorTabState?, to groupID: EditorGroupID?) {
        guard let tab, let groupID else { return }
        _ = root.updateGroup(id: groupID) { $0.insert(tab) }
    }
}

nonisolated struct EditorLayoutRestoration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let layout: EditorLayoutState

    init(layout: EditorLayoutState) {
        schemaVersion = Self.currentSchemaVersion
        self.layout = layout
    }

    init(schemaVersion: Int, layout: EditorLayoutState) {
        self.schemaVersion = schemaVersion
        self.layout = layout
    }

    func restoredLayout() throws -> EditorLayoutState {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw EditorLayoutRestorationError.unsupportedSchema(schemaVersion)
        }
        guard !layout.groupIDs.isEmpty else {
            throw EditorLayoutRestorationError.missingEditorGroup
        }
        return layout
    }
}

nonisolated enum EditorLayoutRestorationError: LocalizedError, Equatable {
    case missingEditorGroup
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .missingEditorGroup: "The saved editor layout does not contain an editor group."
        case .unsupportedSchema(let version):
            "Editor layout schema version \(version) is not supported."
        }
    }
}
