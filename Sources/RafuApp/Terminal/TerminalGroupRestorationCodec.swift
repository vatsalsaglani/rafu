import Foundation

/// Typed validation errors at the named-layout boundary. These errors contain
/// no workspace path, command, or process information.
nonisolated enum TerminalGroupPersistenceError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case duplicateID
    case missingFocusedPane
    case invalidTree
    case invalidFraction
    case invalidRelativePath
    case unknownSavedPaneKind
    case missingShellProfile
    case unapprovedShellProfile
    case missingStartingFolder
    case exceededBounds
    case nameConflict
    case savedLayoutNotFound
    case invalidSaveOperation
    case unreadableStoreFile
    case corruptStoreFile
    case encodedFileTooLarge
}

/// The result of revalidating an ordinary shell profile during inert restore.
/// A missing dependency does not cause substitution or process activity.
nonisolated enum TerminalGroupPaneRestoreValidation: Equatable, Sendable {
    case available
    case missingFolder
    case unapprovedShell
    case unavailableAgentTerminal
    case unavailableEnsemble
}

/// A decoded snapshot and per-pane recovery information for the later UI
/// layer. The codec never starts a session or resolves an executable.
nonisolated struct TerminalGroupDecodedSnapshot: Equatable, Sendable {
    let snapshot: TerminalGroupSnapshot
    let paneValidation: [TerminalPaneID: TerminalGroupPaneRestoreValidation]
}

/// The narrow conversion boundary between live group metadata and inert
/// records. Runtime identities and live state do not cross this boundary.
nonisolated struct TerminalGroupRestorationCodec: Sendable {
    private let validateProfile:
        @Sendable (TerminalPaneLaunchProfile) -> TerminalGroupPaneRestoreValidation

    init(
        validateProfile:
            @escaping @Sendable (TerminalPaneLaunchProfile) -> TerminalGroupPaneRestoreValidation =
            {
                _ in .available
            }
    ) {
        self.validateProfile = validateProfile
    }

    func savedRecord(
        from snapshot: TerminalGroupSnapshot,
        savedLayoutID: SavedTerminalGroupID? = nil
    ) throws -> SavedTerminalGroupRecord {
        var paneIDs: [TerminalPaneID: SavedTerminalPaneID] = [:]
        for paneID in snapshot.root.paneIDs {
            guard paneIDs[paneID] == nil else { throw TerminalGroupPersistenceError.duplicateID }
            paneIDs[paneID] = SavedTerminalPaneID()
        }

        func convert(_ node: TerminalGroupNode) throws -> SavedTerminalGroupNode {
            switch node {
            case .pane(let paneID):
                guard let savedPaneID = paneIDs[paneID] else {
                    throw TerminalGroupPersistenceError.invalidTree
                }
                return .pane(savedPaneID)
            case .split(_, let axis, let fraction, let first, let second):
                guard fraction.isFinite,
                    (TerminalGroupSnapshot
                        .minimumSplitFraction...TerminalGroupSnapshot.maximumSplitFraction)
                        .contains(fraction)
                else { throw TerminalGroupPersistenceError.invalidFraction }
                return .split(
                    id: SavedTerminalGroupSplitID(), axis: axis, fraction: fraction,
                    first: try convert(first), second: try convert(second))
            }
        }

        let records = try snapshot.panes.map { pane in
            guard let savedPaneID = paneIDs[pane.id] else {
                throw TerminalGroupPersistenceError.invalidTree
            }
            let kind: SavedTerminalPaneKind
            let profile: TerminalPaneLaunchProfile?
            switch pane.runtimeKind {
            case .ordinaryShell:
                guard let launchProfile = pane.launchProfile else {
                    throw TerminalGroupPersistenceError.missingShellProfile
                }
                kind = .ordinaryShell
                profile = launchProfile
            case .directAgentTerminal, .unavailableAgentTerminal:
                kind = .unavailableAgentTerminal
                profile = nil
            case .ensembleRole, .ensembleCoordinator, .unavailableEnsemble:
                kind = .unavailableEnsemble
                profile = nil
            }
            return try SavedTerminalPaneRecord(
                id: savedPaneID,
                explicitUserName: pane.explicitUserName,
                themeColor: pane.themeColor,
                kind: kind,
                launchProfile: profile)
        }
        guard let focusedPaneID = paneIDs[snapshot.focusedPaneID] else {
            throw TerminalGroupPersistenceError.missingFocusedPane
        }
        return try SavedTerminalGroupRecord(
            id: savedLayoutID ?? snapshot.savedLayoutID ?? SavedTerminalGroupID(),
            name: snapshot.name,
            root: try convert(snapshot.root),
            focusedPaneID: focusedPaneID,
            panes: records)
    }

    func openNamedLayout(_ record: SavedTerminalGroupRecord) throws -> TerminalGroupDecodedSnapshot
    {
        var paneIDs: [SavedTerminalPaneID: TerminalPaneID] = [:]
        for paneID in record.root.paneIDs {
            guard paneIDs[paneID] == nil else { throw TerminalGroupPersistenceError.duplicateID }
            paneIDs[paneID] = TerminalPaneID()
        }
        let root = try freshRuntimeTree(from: record.root, paneIDs: paneIDs)
        guard let focusedPaneID = paneIDs[record.focusedPaneID] else {
            throw TerminalGroupPersistenceError.missingFocusedPane
        }
        let decodedPanes = try decodeSavedPanes(record.panes, paneIDs: paneIDs)
        let snapshot = try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: record.name, root: root, focusedPaneID: focusedPaneID,
            savedLayoutID: record.id, panes: decodedPanes.panes,
            retainedPaneCount: decodedPanes.panes.count)
        return TerminalGroupDecodedSnapshot(
            snapshot: snapshot, paneValidation: decodedPanes.validation)
    }

    /// Open-tab restoration has intentionally different identity semantics:
    /// its runtime identities are retained for that one restored tab.
    func restoreOpenInstance(
        _ record: TerminalGroupOpenTabRestorationRecord
    ) throws -> TerminalGroupDecodedSnapshot {
        let paneIDs = Dictionary(uniqueKeysWithValues: record.panes.map { ($0.id, $0.id) })
        guard paneIDs.count == record.panes.count else {
            throw TerminalGroupPersistenceError.duplicateID
        }
        let decodedPanes = try decodeOpenPanes(record.panes)
        let snapshot = try TerminalGroupSnapshot(
            id: record.groupID, name: record.name, root: record.root,
            focusedPaneID: record.focusedPaneID, savedLayoutID: record.savedLayoutID,
            panes: decodedPanes.panes, retainedPaneCount: decodedPanes.panes.count)
        return TerminalGroupDecodedSnapshot(
            snapshot: snapshot, paneValidation: decodedPanes.validation)
    }

    private func freshRuntimeTree(
        from node: SavedTerminalGroupNode,
        paneIDs: [SavedTerminalPaneID: TerminalPaneID]
    ) throws -> TerminalGroupNode {
        switch node {
        case .pane(let savedPaneID):
            guard let paneID = paneIDs[savedPaneID] else {
                throw TerminalGroupPersistenceError.invalidTree
            }
            return .pane(paneID)
        case .split(_, let axis, let fraction, let first, let second):
            guard fraction.isFinite,
                (TerminalGroupSnapshot
                    .minimumSplitFraction...TerminalGroupSnapshot.maximumSplitFraction)
                    .contains(fraction)
            else { throw TerminalGroupPersistenceError.invalidFraction }
            return .split(
                id: TerminalGroupSplitID(), axis: axis, fraction: fraction,
                first: try freshRuntimeTree(from: first, paneIDs: paneIDs),
                second: try freshRuntimeTree(from: second, paneIDs: paneIDs))
        }
    }

    private func decodeSavedPanes(
        _ records: [SavedTerminalPaneRecord],
        paneIDs: [SavedTerminalPaneID: TerminalPaneID]
    ) throws -> (
        panes: [TerminalPaneSnapshot],
        validation: [TerminalPaneID: TerminalGroupPaneRestoreValidation]
    ) {
        var results: [TerminalPaneSnapshot] = []
        var validation: [TerminalPaneID: TerminalGroupPaneRestoreValidation] = [:]
        for record in records {
            guard let paneID = paneIDs[record.id] else {
                throw TerminalGroupPersistenceError.invalidTree
            }
            let restored = try restoredPane(
                id: paneID, explicitUserName: record.explicitUserName,
                themeColor: record.themeColor,
                kind: record.kind, launchProfile: record.launchProfile)
            results.append(restored.pane)
            validation[paneID] = restored.validation
        }
        return (results, validation)
    }

    private func decodeOpenPanes(
        _ records: [TerminalGroupOpenPaneRestorationRecord]
    ) throws -> (
        panes: [TerminalPaneSnapshot],
        validation: [TerminalPaneID: TerminalGroupPaneRestoreValidation]
    ) {
        var results: [TerminalPaneSnapshot] = []
        var validation: [TerminalPaneID: TerminalGroupPaneRestoreValidation] = [:]
        for record in records {
            let restored = try restoredPane(
                id: record.id, explicitUserName: record.explicitUserName,
                themeColor: record.themeColor,
                kind: record.kind, launchProfile: record.launchProfile)
            results.append(restored.pane)
            validation[record.id] = restored.validation
        }
        return (results, validation)
    }

    private func restoredPane(
        id: TerminalPaneID,
        explicitUserName: TerminalPaneName?,
        themeColor: TerminalPaneThemeColor?,
        kind: SavedTerminalPaneKind,
        launchProfile: TerminalPaneLaunchProfile?
    ) throws -> (pane: TerminalPaneSnapshot, validation: TerminalGroupPaneRestoreValidation) {
        switch kind {
        case .ordinaryShell:
            guard let launchProfile else { throw TerminalGroupPersistenceError.missingShellProfile }
            let validation = validateProfile(launchProfile)
            return (
                try TerminalPaneSnapshot(
                    id: id, sessionID: nil, explicitUserName: explicitUserName, reportedTitle: nil,
                    runtimeKind: .ordinaryShell, themeColor: themeColor, status: .stopped,
                    launchProfile: launchProfile,
                    startAvailability: validation == .available ? .available : .unavailable),
                validation
            )
        case .unavailableAgentTerminal:
            return (
                try TerminalPaneSnapshot(
                    id: id, sessionID: nil, explicitUserName: explicitUserName, reportedTitle: nil,
                    runtimeKind: .unavailableAgentTerminal, themeColor: themeColor,
                    status: .unavailable,
                    launchProfile: nil, startAvailability: .unavailable),
                .unavailableAgentTerminal
            )
        case .unavailableEnsemble:
            return (
                try TerminalPaneSnapshot(
                    id: id, sessionID: nil, explicitUserName: explicitUserName, reportedTitle: nil,
                    runtimeKind: .unavailableEnsemble, themeColor: themeColor, status: .unavailable,
                    launchProfile: nil, startAvailability: .unavailable),
                .unavailableEnsemble
            )
        }
    }
}
