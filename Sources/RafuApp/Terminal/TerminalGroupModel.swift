import Foundation

// MARK: - Runtime and saved identities

nonisolated struct TerminalGroupID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct TerminalPaneID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct TerminalGroupSplitID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct SavedTerminalGroupID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct SavedTerminalPaneID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated struct SavedTerminalGroupSplitID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// This identity exists only while a window-scoped manager holds capacity for
/// a validated multi-start request. It cannot enter a saved record or a
/// restoration snapshot.
nonisolated struct TerminalGroupCapacityReservationID: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

// MARK: - Bounded text and paths

nonisolated struct TerminalGroupName: RawRepresentable, Codable, Hashable, Sendable {
    static let maximumUnicodeScalarCount = 80

    let rawValue: String

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.unicodeScalars.count <= Self.maximumUnicodeScalarCount
        else {
            return nil
        }
        rawValue = normalized
    }

    init?(rawValue: String) {
        self.init(rawValue)
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let name = TerminalGroupName(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid Terminal Group name"
            )
        }
        self = name
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct TerminalPaneName: RawRepresentable, Codable, Hashable, Sendable {
    static let maximumUnicodeScalarCount = 80

    let rawValue: String

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.unicodeScalars.count <= Self.maximumUnicodeScalarCount
        else {
            return nil
        }
        rawValue = normalized
    }

    init?(rawValue: String) {
        self.init(rawValue)
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let name = TerminalPaneName(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid Terminal pane name"
            )
        }
        self = name
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A bounded, live-only OSC title. It is distinct from `TerminalPaneName` so
/// persistence code cannot use a reported title as an explicit user name.
nonisolated struct TerminalReportedTitle: RawRepresentable, Hashable, Sendable {
    static let maximumUTF8Length = 160

    let rawValue: String

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= Self.maximumUTF8Length else {
            return nil
        }
        rawValue = normalized
    }

    init?(rawValue: String) {
        self.init(rawValue)
    }
}

/// A normalized path below the workspace root. It never represents an
/// observed live working directory and cannot contain an absolute path or a
/// traversal component.
nonisolated struct TerminalWorkspaceRelativePath: RawRepresentable, Codable, Hashable, Sendable {
    static let root = TerminalWorkspaceRelativePath(unchecked: ".")
    static let maximumUTF8Length = 1_024

    let rawValue: String

    init?(_ value: String) {
        guard value.utf8.count <= Self.maximumUTF8Length, !value.utf8.contains(0) else {
            return nil
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !value.hasPrefix("/"), !components.contains(where: { $0 == ".." }) else { return nil }
        let normalized = components.filter { $0 != "." }.joined(separator: "/")
        self = normalized.isEmpty ? .root : TerminalWorkspaceRelativePath(unchecked: normalized)
    }

    init?(rawValue: String) {
        self.init(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let path = TerminalWorkspaceRelativePath(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid workspace-relative terminal path"
            )
        }
        self = path
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Tree vocabulary

nonisolated enum TerminalGroupSplitPlacement: String, Codable, Hashable, Sendable {
    case right
    case down

    var axis: TerminalGroupSplitAxis {
        switch self {
        case .right: .columns
        case .down: .rows
        }
    }
}

nonisolated enum TerminalPaneFocusDirection: String, Codable, Hashable, Sendable {
    case left
    case right
    case up
    case down
}

nonisolated enum TerminalGroupSplitAxis: String, Codable, Hashable, Sendable {
    case columns
    case rows
}

nonisolated indirect enum TerminalGroupNode: Codable, Equatable, Sendable {
    case pane(TerminalPaneID)
    case split(
        id: TerminalGroupSplitID,
        axis: TerminalGroupSplitAxis,
        fraction: Double,
        first: TerminalGroupNode,
        second: TerminalGroupNode
    )

    var paneIDs: [TerminalPaneID] {
        switch self {
        case .pane(let paneID): [paneID]
        case .split(_, _, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    var splitIDs: [TerminalGroupSplitID] {
        switch self {
        case .pane: []
        case .split(let id, _, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    func normalizedFractions() -> TerminalGroupNode {
        switch self {
        case .pane:
            self
        case .split(let id, let axis, let fraction, let first, let second):
            .split(
                id: id,
                axis: axis,
                fraction: TerminalGroupSnapshot.normalizedFraction(fraction),
                first: first.normalizedFractions(),
                second: second.normalizedFractions()
            )
        }
    }
}

// MARK: - Pane state and snapshots

nonisolated enum TerminalPaneRuntimeKind: Equatable, Sendable {
    case ordinaryShell
    case directAgentTerminal(provider: ConductorCLIID)
    case ensembleRole
    case ensembleCoordinator
    case unavailableAgentTerminal
    case unavailableEnsemble
}

nonisolated enum TerminalPaneStatus: Equatable, Sendable {
    case idle
    case live
    case exited
    case stopped
    case unavailable
}

nonisolated enum TerminalPaneStartAvailability: Equatable, Sendable {
    case available
    case unavailable
    case notRestartable
}

nonisolated enum TerminalPaneThemeColor: String, Codable, Hashable, Sendable {
    case accent
    case info
    case success
    case warning
    case error
    case muted
}

nonisolated enum TerminalPaneShellChoice: Codable, Equatable, Hashable, Sendable {
    case preferredShell
    case approvedShellPath(String)

    init?(approvedShellPath: String) {
        guard
            approvedShellPath.utf8.count <= 1_024,
            approvedShellPath.hasPrefix("/"),
            !approvedShellPath.utf8.contains(0)
        else { return nil }
        self = .approvedShellPath(approvedShellPath)
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "preferred" {
            self = .preferredShell
        } else if let shell = TerminalPaneShellChoice(approvedShellPath: value) {
            self = shell
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid approved terminal shell path"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .preferredShell:
            try container.encode("preferred")
        case .approvedShellPath(let path):
            try container.encode(path)
        }
    }
}

/// The safe, ordinary-shell-only portion of a future start. The runtime must
/// still resolve the shell and revalidate this folder before it starts a
/// process.
nonisolated struct TerminalPaneLaunchProfile: Codable, Equatable, Hashable, Sendable {
    let shell: TerminalPaneShellChoice
    let startingFolder: TerminalWorkspaceRelativePath
}

/// Runtime-only launch input. Saved and restoration records must use
/// `TerminalPaneLaunchProfile`, never this type or `TerminalProcessSpec`.
nonisolated enum TerminalPaneLaunchRequest: Equatable, Sendable {
    case ordinaryShell(profile: TerminalPaneLaunchProfile)
    case process(spec: TerminalProcessSpec, kind: TerminalPaneRuntimeKind)
}

nonisolated struct TerminalPaneSnapshot: Equatable, Sendable {
    let id: TerminalPaneID
    let sessionID: UUID?
    let explicitUserName: TerminalPaneName?
    let reportedTitle: TerminalReportedTitle?
    let runtimeKind: TerminalPaneRuntimeKind
    let themeColor: TerminalPaneThemeColor?
    let status: TerminalPaneStatus
    let launchProfile: TerminalPaneLaunchProfile?
    let startAvailability: TerminalPaneStartAvailability

    init(
        id: TerminalPaneID,
        sessionID: UUID?,
        explicitUserName: TerminalPaneName?,
        reportedTitle: TerminalReportedTitle?,
        runtimeKind: TerminalPaneRuntimeKind,
        themeColor: TerminalPaneThemeColor?,
        status: TerminalPaneStatus,
        launchProfile: TerminalPaneLaunchProfile?,
        startAvailability: TerminalPaneStartAvailability
    ) throws {
        switch runtimeKind {
        case .unavailableAgentTerminal, .unavailableEnsemble:
            if sessionID != nil {
                throw TerminalPaneSnapshotError.unavailablePaneHasLiveSession(id)
            }
            guard status == .unavailable else {
                throw TerminalPaneSnapshotError.unavailablePaneHasInvalidStatus(id, status)
            }
            if launchProfile != nil {
                throw TerminalPaneSnapshotError.unavailablePaneHasLaunchProfile(id)
            }
            guard startAvailability == .unavailable else {
                throw TerminalPaneSnapshotError.unavailablePaneHasInvalidStartAvailability(
                    id,
                    startAvailability
                )
            }
        case .ordinaryShell, .directAgentTerminal, .ensembleRole, .ensembleCoordinator:
            break
        }

        self.id = id
        self.sessionID = sessionID
        self.explicitUserName = explicitUserName
        self.reportedTitle = reportedTitle
        self.runtimeKind = runtimeKind
        self.themeColor = themeColor
        self.status = status
        self.launchProfile = launchProfile
        self.startAvailability = startAvailability
    }
}

nonisolated enum TerminalPaneSnapshotError: Error, Equatable, Sendable {
    case unavailablePaneHasLiveSession(TerminalPaneID)
    case unavailablePaneHasInvalidStatus(TerminalPaneID, TerminalPaneStatus)
    case unavailablePaneHasLaunchProfile(TerminalPaneID)
    case unavailablePaneHasInvalidStartAvailability(
        TerminalPaneID,
        TerminalPaneStartAvailability
    )
}

nonisolated enum TerminalGroupSnapshotError: Error, Equatable, Sendable {
    case emptyGroup
    case tooManyPanes(Int)
    case retainedPaneLimitExceeded(Int)
    case duplicatePane(TerminalPaneID)
    case duplicateSplit(TerminalGroupSplitID)
    case missingPaneSnapshot(TerminalPaneID)
    case paneSnapshotOutsideTree(TerminalPaneID)
    case focusedPaneMissing(TerminalPaneID)
    case duplicateSession(UUID)
}

/// The independent resource bounds for one workspace window. These values
/// describe retained metadata and live session capacity separately. They do
/// not carry process details or authorise a launch.
nonisolated enum TerminalGroupLimits: Sendable {
    static let maximumGroupsPerWindow = 20
    static let maximumPanesPerGroup = 10
    static let maximumRetainedPanesPerWindow = 200
    static let maximumLiveSessionsPerWindow = 200
    static let maximumSavedLayoutsPerWorkspace = 32
}

/// An immutable, bounded runtime projection. It deliberately has no Codable
/// conformance: runtime group, pane, split, and session identities are not
/// reusable saved-layout identities.
nonisolated struct TerminalGroupSnapshot: Equatable, Sendable {
    // Compatibility aliases for older callers. Capacity decisions use the
    // independent TerminalGroupLimits contract.
    static let maximumPanesPerGroup = TerminalGroupLimits.maximumPanesPerGroup
    static let maximumRetainedPanesPerWindow = TerminalGroupLimits.maximumRetainedPanesPerWindow
    static let defaultSplitFraction = 0.5
    static let minimumSplitFraction = 0.1
    static let maximumSplitFraction = 0.9

    let id: TerminalGroupID
    let name: TerminalGroupName
    let root: TerminalGroupNode
    let focusedPaneID: TerminalPaneID
    let savedLayoutID: SavedTerminalGroupID?
    let panes: [TerminalPaneSnapshot]

    init(
        id: TerminalGroupID,
        name: TerminalGroupName,
        root: TerminalGroupNode,
        focusedPaneID: TerminalPaneID,
        savedLayoutID: SavedTerminalGroupID?,
        panes: [TerminalPaneSnapshot],
        retainedPaneCount: Int
    ) throws {
        let normalizedRoot = root.normalizedFractions()
        try Self.validate(
            root: normalizedRoot,
            focusedPaneID: focusedPaneID,
            panes: panes,
            retainedPaneCount: retainedPaneCount
        )
        self.id = id
        self.name = name
        self.root = normalizedRoot
        self.focusedPaneID = focusedPaneID
        self.savedLayoutID = savedLayoutID
        self.panes = panes
    }

    static func normalizedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSplitFraction }
        return min(max(value, minimumSplitFraction), maximumSplitFraction)
    }

    static func validateRetainedPaneCount(_ count: Int) throws {
        guard (0...maximumRetainedPanesPerWindow).contains(count) else {
            throw TerminalGroupSnapshotError.retainedPaneLimitExceeded(count)
        }
    }

    private static func validate(
        root: TerminalGroupNode,
        focusedPaneID: TerminalPaneID,
        panes: [TerminalPaneSnapshot],
        retainedPaneCount: Int
    ) throws {
        let treePaneIDs = root.paneIDs
        guard !treePaneIDs.isEmpty else { throw TerminalGroupSnapshotError.emptyGroup }
        guard treePaneIDs.count <= maximumPanesPerGroup else {
            throw TerminalGroupSnapshotError.tooManyPanes(treePaneIDs.count)
        }
        try validateRetainedPaneCount(retainedPaneCount)

        var seenPanes = Set<TerminalPaneID>()
        for paneID in treePaneIDs where !seenPanes.insert(paneID).inserted {
            throw TerminalGroupSnapshotError.duplicatePane(paneID)
        }
        var seenSplits = Set<TerminalGroupSplitID>()
        for splitID in root.splitIDs where !seenSplits.insert(splitID).inserted {
            throw TerminalGroupSnapshotError.duplicateSplit(splitID)
        }
        guard seenPanes.contains(focusedPaneID) else {
            throw TerminalGroupSnapshotError.focusedPaneMissing(focusedPaneID)
        }

        var snapshots = Set<TerminalPaneID>()
        var sessions = Set<UUID>()
        for pane in panes {
            guard seenPanes.contains(pane.id) else {
                throw TerminalGroupSnapshotError.paneSnapshotOutsideTree(pane.id)
            }
            guard snapshots.insert(pane.id).inserted else {
                throw TerminalGroupSnapshotError.duplicatePane(pane.id)
            }
            if let sessionID = pane.sessionID, !sessions.insert(sessionID).inserted {
                throw TerminalGroupSnapshotError.duplicateSession(sessionID)
            }
        }
        for paneID in seenPanes where !snapshots.contains(paneID) {
            throw TerminalGroupSnapshotError.missingPaneSnapshot(paneID)
        }
    }
}

// MARK: - Capacity and close validation

nonisolated enum TerminalGroupCapacityError: Error, Equatable, Sendable {
    case groupLimitExceeded(current: Int, requested: Int)
    case groupPaneLimitExceeded(current: Int, requested: Int)
    case retainedPaneLimitExceeded(current: Int, requested: Int)
    case liveSessionLimitExceeded(current: Int, requested: Int)
    case invalidReservationCount(Int)
    case staleReservation(TerminalGroupCapacityReservationID)
}

nonisolated struct TerminalGroupCapacityReservation: Equatable, Sendable {
    let id: TerminalGroupCapacityReservationID
    let generation: UInt64
    let reservedLiveSessionCount: Int

    init?(
        id: TerminalGroupCapacityReservationID = TerminalGroupCapacityReservationID(),
        generation: UInt64,
        reservedLiveSessionCount: Int
    ) {
        guard generation > 0,
            (1...TerminalGroupLimits.maximumPanesPerGroup).contains(reservedLiveSessionCount)
        else { return nil }
        self.id = id
        self.generation = generation
        self.reservedLiveSessionCount = reservedLiveSessionCount
    }
}

/// TG-20 implements this window-scoped seam on the Terminal Group aggregate.
/// A reservation is manager-owned, generation-checked, and single-use. It
/// holds capacity only; it cannot carry a process specification or credential.
@MainActor
protocol TerminalGroupCapacityReserving: Sendable {
    func reserveLiveSessionCapacity(
        _ requestedLiveSessionCount: Int
    ) throws -> TerminalGroupCapacityReservation
    func consumeLiveSessionCapacity(
        _ reservation: TerminalGroupCapacityReservation
    ) throws
    func cancelLiveSessionCapacity(
        _ reservation: TerminalGroupCapacityReservation
    ) throws
}

nonisolated enum TerminalGroupCloseTarget: Equatable, Sendable {
    case pane(TerminalPaneID)
    case group(TerminalGroupID)
}

nonisolated struct TerminalGroupCloseToken: Equatable, Sendable {
    let target: TerminalGroupCloseTarget
    let affectedSessionIDs: [UUID]
    let liveProcessCount: Int
    let generation: UInt64

    init?(
        target: TerminalGroupCloseTarget,
        affectedSessionIDs: [UUID],
        liveProcessCount: Int,
        generation: UInt64
    ) {
        guard generation > 0,
            liveProcessCount >= 0,
            liveProcessCount <= affectedSessionIDs.count,
            affectedSessionIDs.count <= TerminalGroupLimits.maximumPanesPerGroup,
            Set(affectedSessionIDs).count == affectedSessionIDs.count
        else { return nil }
        self.target = target
        self.affectedSessionIDs = affectedSessionIDs
        self.liveProcessCount = liveProcessCount
        self.generation = generation
    }
}

nonisolated enum TerminalGroupValidationError: Error, Equatable, Sendable {
    case groupNotFound(TerminalGroupID)
    case paneNotFound(TerminalPaneID)
    case splitNotFound(TerminalGroupSplitID)
    case invalidName
    case invalidStartingFolder
    case invalidDividerFraction
    case unsupportedPaneStart
    case unsupportedPaneMetadata
    case staleCloseToken
    case savedLayoutNotFound(SavedTerminalGroupID)
}

// MARK: - Commands and effects

nonisolated enum TerminalGroupCommand: Equatable, Sendable {
    case createGroup(name: TerminalGroupName?)
    case splitFocusedPane(groupID: TerminalGroupID, placement: TerminalGroupSplitPlacement)
    case focusPane(groupID: TerminalGroupID, paneID: TerminalPaneID)
    case focusDirection(groupID: TerminalGroupID, direction: TerminalPaneFocusDirection)
    case renameGroup(groupID: TerminalGroupID, name: TerminalGroupName)
    case setPaneName(paneID: TerminalPaneID, name: TerminalPaneName?)
    case setPaneThemeColor(paneID: TerminalPaneID, color: TerminalPaneThemeColor?)
    case commitSavedLayout(
        groupID: TerminalGroupID,
        savedLayoutID: SavedTerminalGroupID,
        name: TerminalGroupName
    )
    case detachDeletedSavedLayout(SavedTerminalGroupID)
    case setPaneStartingFolder(paneID: TerminalPaneID, folder: TerminalWorkspaceRelativePath)
    case setDividerFraction(splitID: TerminalGroupSplitID, fraction: Double)
    case parkGroup(TerminalGroupID)
    case revealGroup(TerminalGroupID)
    case prepareClose(TerminalGroupCloseTarget)
    case finalizeClose(TerminalGroupCloseToken)
    case restartExitedShellPane(TerminalPaneID)
    case insertStoppedSavedGroup(SavedTerminalGroupID)
    case startPane(TerminalPaneID)
    case startAllRestartablePanes(TerminalGroupID)
}

nonisolated enum TerminalGroupEffect: Equatable, Sendable {
    case insertEditorTab(groupID: TerminalGroupID)
    case removeEditorTab(groupID: TerminalGroupID)
    case selectEditorTab(groupID: TerminalGroupID)
    case cleanupProcesses(sessionIDs: [UUID])
    case persistSavedLayout(SavedTerminalGroupID)
    case persistWorkspaceRestoration
    case requestCloseConfirmation(TerminalGroupCloseToken)
    case capacityError(TerminalGroupCapacityError)
    case validationError(TerminalGroupValidationError)
    case paneMetadataChanged(paneID: TerminalPaneID)
}
