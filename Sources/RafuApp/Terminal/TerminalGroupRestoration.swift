import CryptoKit
import Foundation

// MARK: - Safe saved-layout records

/// An opaque, deterministic identity for one standardized workspace root.
/// The raw workspace path is used only to derive the digest and is never kept
/// by this value or emitted by its Codable representation.
nonisolated struct TerminalGroupWorkspaceKey: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("sha256:"), rawValue.count == 71 else { return nil }
        let digest = rawValue.dropFirst("sha256:".count)
        guard digest.allSatisfy(\.isHexDigit) else { return nil }
        self.rawValue = rawValue.lowercased()
    }

    init(standardizedRoot: URL) {
        let root = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(root.utf8))
        rawValue = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let key = TerminalGroupWorkspaceKey(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid Terminal Group workspace key"
            )
        }
        self = key
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum SavedTerminalPaneKind: String, Codable, Hashable, Sendable {
    case ordinaryShell
    case unavailableAgentTerminal
    case unavailableEnsemble

    var unavailableMessage: String? {
        switch self {
        case .ordinaryShell: nil
        case .unavailableAgentTerminal: "Agent Terminal profiles are not saved in this version."
        case .unavailableEnsemble: "Ensemble terminal profiles are not saved in this version."
        }
    }
}

nonisolated indirect enum SavedTerminalGroupNode: Codable, Equatable, Sendable {
    case pane(SavedTerminalPaneID)
    case split(
        id: SavedTerminalGroupSplitID,
        axis: TerminalGroupSplitAxis,
        fraction: Double,
        first: SavedTerminalGroupNode,
        second: SavedTerminalGroupNode
    )

    var paneIDs: [SavedTerminalPaneID] {
        switch self {
        case .pane(let paneID): [paneID]
        case .split(_, _, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    var splitIDs: [SavedTerminalGroupSplitID] {
        switch self {
        case .pane: []
        case .split(let id, _, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    func normalizedFractions() -> SavedTerminalGroupNode {
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

nonisolated struct SavedTerminalPaneRecord: Codable, Equatable, Sendable {
    let id: SavedTerminalPaneID
    let explicitUserName: TerminalPaneName?
    let themeColor: TerminalPaneThemeColor?
    let kind: SavedTerminalPaneKind
    let launchProfile: TerminalPaneLaunchProfile?

    init(
        id: SavedTerminalPaneID,
        explicitUserName: TerminalPaneName?,
        themeColor: TerminalPaneThemeColor?,
        kind: SavedTerminalPaneKind,
        launchProfile: TerminalPaneLaunchProfile?
    ) throws {
        guard (kind == .ordinaryShell) == (launchProfile != nil) else {
            throw TerminalGroupRestorationError.invalidSavedPaneKind(id)
        }
        self.id = id
        self.explicitUserName = explicitUserName
        self.themeColor = themeColor
        self.kind = kind
        self.launchProfile = launchProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case explicitUserName
        case themeColor
        case kind
        case launchProfile
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(SavedTerminalPaneID.self, forKey: .id),
            explicitUserName: container.decodeIfPresent(
                TerminalPaneName.self, forKey: .explicitUserName),
            themeColor: container.decodeIfPresent(TerminalPaneThemeColor.self, forKey: .themeColor),
            kind: container.decode(SavedTerminalPaneKind.self, forKey: .kind),
            launchProfile: container.decodeIfPresent(
                TerminalPaneLaunchProfile.self, forKey: .launchProfile)
        )
    }
}

nonisolated struct SavedTerminalGroupRecord: Codable, Equatable, Sendable {
    let id: SavedTerminalGroupID
    let name: TerminalGroupName
    let root: SavedTerminalGroupNode
    let focusedPaneID: SavedTerminalPaneID
    let panes: [SavedTerminalPaneRecord]

    init(
        id: SavedTerminalGroupID,
        name: TerminalGroupName,
        root: SavedTerminalGroupNode,
        focusedPaneID: SavedTerminalPaneID,
        panes: [SavedTerminalPaneRecord]
    ) throws {
        let normalizedRoot = root.normalizedFractions()
        try Self.validate(root: normalizedRoot, focusedPaneID: focusedPaneID, panes: panes)
        self.id = id
        self.name = name
        self.root = normalizedRoot
        self.focusedPaneID = focusedPaneID
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case root
        case focusedPaneID
        case panes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(SavedTerminalGroupID.self, forKey: .id),
            name: container.decode(TerminalGroupName.self, forKey: .name),
            root: container.decode(SavedTerminalGroupNode.self, forKey: .root),
            focusedPaneID: container.decode(SavedTerminalPaneID.self, forKey: .focusedPaneID),
            panes: container.decode([SavedTerminalPaneRecord].self, forKey: .panes)
        )
    }

    private static func validate(
        root: SavedTerminalGroupNode,
        focusedPaneID: SavedTerminalPaneID,
        panes: [SavedTerminalPaneRecord]
    ) throws {
        let paneIDs = root.paneIDs
        guard !paneIDs.isEmpty, paneIDs.count <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupRestorationError.invalidSavedGroup
        }
        guard Set(paneIDs).count == paneIDs.count, Set(root.splitIDs).count == root.splitIDs.count
        else {
            throw TerminalGroupRestorationError.invalidSavedGroup
        }
        guard Set(panes.map(\.id)) == Set(paneIDs), panes.count == paneIDs.count else {
            throw TerminalGroupRestorationError.invalidSavedGroup
        }
        guard paneIDs.contains(focusedPaneID) else {
            throw TerminalGroupRestorationError.invalidSavedGroup
        }
    }
}

/// The saved-layout library persisted by TG-22. Its keyed records are reusable
/// templates, so they contain only saved-record identities.
nonisolated struct TerminalGroupSavedLayoutEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumSavedLayouts = 128

    let schemaVersion: Int
    let workspaceKey: TerminalGroupWorkspaceKey
    let groups: [SavedTerminalGroupID: SavedTerminalGroupRecord]

    init(
        workspaceKey: TerminalGroupWorkspaceKey,
        groups: [SavedTerminalGroupID: SavedTerminalGroupRecord]
    ) throws {
        guard groups.count <= Self.maximumSavedLayouts,
            groups.allSatisfy({ $0.key == $0.value.id })
        else { throw TerminalGroupRestorationError.invalidSavedGroup }
        schemaVersion = Self.currentSchemaVersion
        self.workspaceKey = workspaceKey
        self.groups = groups
    }

    init(
        schemaVersion: Int,
        workspaceKey: TerminalGroupWorkspaceKey,
        groups: [SavedTerminalGroupID: SavedTerminalGroupRecord]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TerminalGroupRestorationError.unsupportedSavedLayoutSchema(schemaVersion)
        }
        try self.init(workspaceKey: workspaceKey, groups: groups)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workspaceKey
        case groups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            workspaceKey: container.decode(TerminalGroupWorkspaceKey.self, forKey: .workspaceKey),
            groups: container.decode(
                [SavedTerminalGroupID: SavedTerminalGroupRecord].self, forKey: .groups)
        )
    }
}

// MARK: - Inert window restoration records

nonisolated struct TerminalGroupOpenPaneRestorationRecord: Codable, Equatable, Sendable {
    let id: TerminalPaneID
    let explicitUserName: TerminalPaneName?
    let themeColor: TerminalPaneThemeColor?
    let kind: SavedTerminalPaneKind
    let launchProfile: TerminalPaneLaunchProfile?

    init(
        id: TerminalPaneID,
        explicitUserName: TerminalPaneName?,
        themeColor: TerminalPaneThemeColor?,
        kind: SavedTerminalPaneKind,
        launchProfile: TerminalPaneLaunchProfile?
    ) throws {
        guard (kind == .ordinaryShell) == (launchProfile != nil) else {
            throw TerminalGroupRestorationError.invalidOpenPane(id)
        }
        self.id = id
        self.explicitUserName = explicitUserName
        self.themeColor = themeColor
        self.kind = kind
        self.launchProfile = launchProfile
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case explicitUserName
        case themeColor
        case kind
        case launchProfile
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(TerminalPaneID.self, forKey: .id),
            explicitUserName: container.decodeIfPresent(
                TerminalPaneName.self, forKey: .explicitUserName),
            themeColor: container.decodeIfPresent(TerminalPaneThemeColor.self, forKey: .themeColor),
            kind: container.decode(SavedTerminalPaneKind.self, forKey: .kind),
            launchProfile: container.decodeIfPresent(
                TerminalPaneLaunchProfile.self, forKey: .launchProfile)
        )
    }
}

/// One already-unique open Terminal Group tab. Unlike a named layout, this is
/// allowed to retain runtime group, pane, and split identities for one window
/// restoration only. It never contains a session, controller, process spec,
/// or launch request.
nonisolated struct TerminalGroupOpenTabRestorationRecord: Codable, Equatable, Sendable {
    let groupID: TerminalGroupID
    let name: TerminalGroupName
    let root: TerminalGroupNode
    let focusedPaneID: TerminalPaneID
    let savedLayoutID: SavedTerminalGroupID?
    let panes: [TerminalGroupOpenPaneRestorationRecord]

    init(
        groupID: TerminalGroupID,
        name: TerminalGroupName,
        root: TerminalGroupNode,
        focusedPaneID: TerminalPaneID,
        savedLayoutID: SavedTerminalGroupID?,
        panes: [TerminalGroupOpenPaneRestorationRecord]
    ) throws {
        let normalizedRoot = root.normalizedFractions()
        try Self.validate(root: normalizedRoot, focusedPaneID: focusedPaneID, panes: panes)
        self.groupID = groupID
        self.name = name
        self.root = normalizedRoot
        self.focusedPaneID = focusedPaneID
        self.savedLayoutID = savedLayoutID
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey {
        case groupID
        case name
        case root
        case focusedPaneID
        case savedLayoutID
        case panes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            groupID: container.decode(TerminalGroupID.self, forKey: .groupID),
            name: container.decode(TerminalGroupName.self, forKey: .name),
            root: container.decode(TerminalGroupNode.self, forKey: .root),
            focusedPaneID: container.decode(TerminalPaneID.self, forKey: .focusedPaneID),
            savedLayoutID: container.decodeIfPresent(
                SavedTerminalGroupID.self, forKey: .savedLayoutID),
            panes: container.decode([TerminalGroupOpenPaneRestorationRecord].self, forKey: .panes)
        )
    }

    private static func validate(
        root: TerminalGroupNode,
        focusedPaneID: TerminalPaneID,
        panes: [TerminalGroupOpenPaneRestorationRecord]
    ) throws {
        let paneIDs = root.paneIDs
        guard !paneIDs.isEmpty, paneIDs.count <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupRestorationError.invalidOpenTab
        }
        guard Set(paneIDs).count == paneIDs.count, Set(root.splitIDs).count == root.splitIDs.count
        else {
            throw TerminalGroupRestorationError.invalidOpenTab
        }
        guard Set(panes.map(\.id)) == Set(paneIDs), panes.count == paneIDs.count else {
            throw TerminalGroupRestorationError.invalidOpenTab
        }
        guard paneIDs.contains(focusedPaneID) else {
            throw TerminalGroupRestorationError.invalidOpenTab
        }
    }
}

nonisolated enum TerminalGroupRestorationDiagnostic: Equatable, Sendable {
    case missingTerminalGroupField
    case malformedTerminalGroupField
    case unsupportedTerminalGroupSchema(Int)
    case malformedTerminalGroupRecord
}

/// The optional field embedded in `RestorableWorkspace`. The decoder tolerates
/// bad sibling records so a future or damaged Terminal Group record cannot
/// erase file tabs, editor groups, or the rest of the workspace payload.
nonisolated struct TerminalGroupWorkspaceRestoration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumOpenGroups = 24
    static let maximumDiagnostics = 16

    let schemaVersion: Int
    let openGroups: [TerminalGroupOpenTabRestorationRecord]
    let diagnostics: [TerminalGroupRestorationDiagnostic]

    init(openGroups: [TerminalGroupOpenTabRestorationRecord]) throws {
        guard openGroups.count <= Self.maximumOpenGroups else {
            throw TerminalGroupRestorationError.tooManyOpenGroups(openGroups.count)
        }
        guard Set(openGroups.map(\.groupID)).count == openGroups.count else {
            throw TerminalGroupRestorationError.duplicateOpenGroup
        }
        let retainedPaneCount = openGroups.reduce(into: 0) { $0 += $1.panes.count }
        try TerminalGroupSnapshot.validateRetainedPaneCount(retainedPaneCount)
        schemaVersion = Self.currentSchemaVersion
        self.openGroups = openGroups
        diagnostics = []
    }

    private init(
        schemaVersion: Int,
        openGroups: [TerminalGroupOpenTabRestorationRecord],
        diagnostics: [TerminalGroupRestorationDiagnostic]
    ) {
        self.schemaVersion = schemaVersion
        self.openGroups = openGroups
        self.diagnostics = Array(diagnostics.prefix(Self.maximumDiagnostics))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case openGroups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TerminalGroupRestorationError.unsupportedWorkspaceSchema(schemaVersion)
        }

        var records = try container.nestedUnkeyedContainer(forKey: .openGroups)
        var openGroups: [TerminalGroupOpenTabRestorationRecord] = []
        var diagnostics: [TerminalGroupRestorationDiagnostic] = []
        while !records.isAtEnd {
            let recordDecoder = try records.superDecoder()
            do {
                let record = try TerminalGroupOpenTabRestorationRecord(from: recordDecoder)
                guard openGroups.count < Self.maximumOpenGroups else {
                    throw TerminalGroupRestorationError.tooManyOpenGroups(openGroups.count + 1)
                }
                openGroups.append(record)
            } catch {
                diagnostics.append(.malformedTerminalGroupRecord)
            }
        }
        guard Set(openGroups.map(\.groupID)).count == openGroups.count else {
            throw TerminalGroupRestorationError.duplicateOpenGroup
        }
        let retainedPaneCount = openGroups.reduce(into: 0) { $0 += $1.panes.count }
        try TerminalGroupSnapshot.validateRetainedPaneCount(retainedPaneCount)
        self.init(schemaVersion: schemaVersion, openGroups: openGroups, diagnostics: diagnostics)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(openGroups, forKey: .openGroups)
    }
}

nonisolated enum TerminalGroupRestorationError: Error, Equatable, Sendable {
    case unsupportedSavedLayoutSchema(Int)
    case unsupportedWorkspaceSchema(Int)
    case invalidSavedGroup
    case invalidSavedPaneKind(SavedTerminalPaneID)
    case invalidOpenTab
    case invalidOpenPane(TerminalPaneID)
    case tooManyOpenGroups(Int)
    case duplicateOpenGroup
}

// MARK: - Pure template instantiation

nonisolated struct TerminalGroupSavedLayoutInstantiation: Equatable, Sendable {
    let groupID: TerminalGroupID
    let name: TerminalGroupName
    let root: TerminalGroupNode
    let focusedPaneID: TerminalPaneID
    let savedLayoutID: SavedTerminalGroupID
    let panes: [TerminalGroupOpenPaneRestorationRecord]

    init(savedGroup: SavedTerminalGroupRecord) throws {
        var paneIDs: [SavedTerminalPaneID: TerminalPaneID] = [:]
        for savedPaneID in savedGroup.root.paneIDs {
            paneIDs[savedPaneID] = TerminalPaneID()
        }

        func rekey(_ node: SavedTerminalGroupNode) -> TerminalGroupNode {
            switch node {
            case .pane(let savedPaneID):
                .pane(paneIDs[savedPaneID]!)
            case .split(_, let axis, let fraction, let first, let second):
                .split(
                    id: TerminalGroupSplitID(),
                    axis: axis,
                    fraction: TerminalGroupSnapshot.normalizedFraction(fraction),
                    first: rekey(first),
                    second: rekey(second)
                )
            }
        }

        let panes = try savedGroup.panes.map { pane in
            try TerminalGroupOpenPaneRestorationRecord(
                id: paneIDs[pane.id]!,
                explicitUserName: pane.explicitUserName,
                themeColor: pane.themeColor,
                kind: pane.kind,
                launchProfile: pane.launchProfile
            )
        }
        groupID = TerminalGroupID()
        name = savedGroup.name
        root = rekey(savedGroup.root)
        focusedPaneID = paneIDs[savedGroup.focusedPaneID]!
        savedLayoutID = savedGroup.id
        self.panes = panes
    }
}

// MARK: - TG-22 storage seam

nonisolated struct TerminalGroupSavedLayoutStoreChange: Equatable, Sendable {
    let workspaceKey: TerminalGroupWorkspaceKey
    let revision: UInt64
}

/// TG-22 provides the Application Support actor. Its implementation must
/// register a subscriber before returning this bounded newest-one stream and
/// yield the current revision immediately, which closes the initial
/// list/subscription race without exposing a saved record on the stream.
nonisolated protocol TerminalGroupSavedLayoutStoring: Sendable {
    func loadSavedLayouts(
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async throws -> TerminalGroupSavedLayoutEnvelope
    func saveSavedLayouts(_ envelope: TerminalGroupSavedLayoutEnvelope) async throws
    func deleteSavedLayout(
        _ id: SavedTerminalGroupID,
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async throws
    func listSavedLayouts(
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async throws -> [SavedTerminalGroupRecord]
    func changes(
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async -> AsyncStream<TerminalGroupSavedLayoutStoreChange>
}
