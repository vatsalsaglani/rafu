import Foundation
import RafuCore

nonisolated struct TerminalGroupSavedLayoutStoreFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedByteCount = 256 * 1_024

    let schemaVersion: Int
    /// SHA-256 workspace digests are JSON object keys. The file never stores
    /// a raw workspace root.
    var workspaces: [String: TerminalGroupSavedLayoutEnvelope]

    init(workspaces: [TerminalGroupWorkspaceKey: TerminalGroupSavedLayoutEnvelope]) {
        schemaVersion = Self.currentSchemaVersion
        self.workspaces = Dictionary(
            uniqueKeysWithValues: workspaces.map { ($0.key.rawValue, $0.value) })
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TerminalGroupPersistenceError.unsupportedSchema(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        let workspaces = try container.decode(
            [String: TerminalGroupSavedLayoutEnvelope].self, forKey: .workspaces)
        guard
            workspaces.allSatisfy({ key, value in
                TerminalGroupWorkspaceKey(rawValue: key) == value.workspaceKey
            })
        else {
            throw TerminalGroupPersistenceError.corruptStoreFile
        }
        self.workspaces = workspaces
    }
}

/// The sole Application Support authority for named saved layouts for one app
/// identity and injected base directory. This actor owns all read-modify-write
/// sequences and the newest-one workspace revision streams.
actor TerminalGroupSavedLayoutStore: TerminalGroupSavedLayoutStoring {
    private let identity: RafuAppIdentity
    private let baseDirectory: URL
    private var revisions: [TerminalGroupWorkspaceKey: UInt64] = [:]
    private var continuations:
        [TerminalGroupWorkspaceKey: [UUID: AsyncStream<TerminalGroupSavedLayoutStoreChange>
            .Continuation]] = [:]

    init(
        identity: RafuAppIdentity = .current,
        baseDirectory: URL = RafuAppIdentity.defaultApplicationSupportBaseDirectory
    ) {
        self.identity = identity
        self.baseDirectory = baseDirectory
    }

    /// Window owners obtain the process-wide authority through this factory.
    /// Tests can still construct an isolated actor with a temporary root.
    static func shared(
        identity: RafuAppIdentity = .current,
        baseDirectory: URL = RafuAppIdentity.defaultApplicationSupportBaseDirectory
    ) async -> TerminalGroupSavedLayoutStore {
        await TerminalGroupSavedLayoutStoreRegistry.shared.store(
            identity: identity, baseDirectory: baseDirectory)
    }

    private var storeDirectory: URL {
        identity.applicationSupportRoot(baseDirectory: baseDirectory)
    }
    private var fileURL: URL { storeDirectory.appending(path: "terminal-group-layouts.json") }

    func loadSavedLayouts(
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async throws -> TerminalGroupSavedLayoutEnvelope {
        let file = try loadFile()
        return try file.workspaces[workspaceKey.rawValue]
            ?? TerminalGroupSavedLayoutEnvelope(workspaceKey: workspaceKey, groups: [:])
    }

    func listSavedLayouts(
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async throws -> [SavedTerminalGroupRecord] {
        let envelope = try await loadSavedLayouts(for: workspaceKey)
        return envelope.groups.values.sorted {
            let order = $0.name.rawValue.compare(
                $1.name.rawValue, options: [.caseInsensitive, .diacriticInsensitive])
            if order == .orderedSame {
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            return order == .orderedAscending
        }
    }

    func saveSavedLayout(
        _ request: TerminalGroupSavedLayoutSaveRequest
    ) async throws -> TerminalGroupSavedLayoutSaveResult {
        try Task.checkCancellation()
        var file = try loadFile()
        let envelope =
            try file.workspaces[request.workspaceKey.rawValue]
            ?? TerminalGroupSavedLayoutEnvelope(workspaceKey: request.workspaceKey, groups: [:])
        var groups = envelope.groups
        var group = request.group
        let disposition: TerminalGroupSavedLayoutSaveDisposition
        switch request.operation {
        case .firstSave:
            guard groups.count < TerminalGroupSavedLayoutEnvelope.maximumSavedLayouts
            else {
                throw TerminalGroupPersistenceError.exceededBounds
            }
            group = try copied(group, withID: SavedTerminalGroupID())
            disposition = .created
        case .saveAs:
            guard groups.count < TerminalGroupSavedLayoutEnvelope.maximumSavedLayouts
            else {
                throw TerminalGroupPersistenceError.exceededBounds
            }
            group = try copied(group, withID: SavedTerminalGroupID())
            disposition = .created
        case .save(let existingID):
            guard existingID == group.id, groups[existingID] != nil else {
                throw TerminalGroupPersistenceError.savedLayoutNotFound
            }
            disposition = .updated
        }
        let conflict = groups.values.contains {
            $0.id != group.id && namesMatch($0.name, group.name)
        }
        guard !conflict else { throw TerminalGroupPersistenceError.nameConflict }
        groups[group.id] = group
        file.workspaces[request.workspaceKey.rawValue] = try TerminalGroupSavedLayoutEnvelope(
            workspaceKey: request.workspaceKey, groups: groups)
        try Task.checkCancellation()
        try write(file)
        emitChange(for: request.workspaceKey)
        return TerminalGroupSavedLayoutSaveResult(savedLayoutID: group.id, disposition: disposition)
    }

    func deleteSavedLayout(
        _ request: TerminalGroupSavedLayoutDeleteRequest
    ) async throws -> TerminalGroupSavedLayoutDeleteResult {
        try Task.checkCancellation()
        var file = try loadFile()
        guard let envelope = file.workspaces[request.workspaceKey.rawValue] else {
            throw TerminalGroupPersistenceError.savedLayoutNotFound
        }
        var groups = envelope.groups
        guard groups.removeValue(forKey: request.savedLayoutID) != nil else {
            throw TerminalGroupPersistenceError.savedLayoutNotFound
        }
        file.workspaces[request.workspaceKey.rawValue] = try TerminalGroupSavedLayoutEnvelope(
            workspaceKey: request.workspaceKey, groups: groups)
        try Task.checkCancellation()
        try write(file)
        emitChange(for: request.workspaceKey)
        return TerminalGroupSavedLayoutDeleteResult(removedSavedLayoutID: request.savedLayoutID)
    }

    func changes(
        for workspaceKey: TerminalGroupWorkspaceKey
    ) async -> AsyncStream<TerminalGroupSavedLayoutStoreChange> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<TerminalGroupSavedLayoutStoreChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        var workspaceContinuations = continuations[workspaceKey] ?? [:]
        workspaceContinuations[subscriptionID] = continuation
        continuations[workspaceKey] = workspaceContinuations
        continuation.yield(
            TerminalGroupSavedLayoutStoreChange(
                workspaceKey: workspaceKey, revision: revisions[workspaceKey, default: 0]))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(subscriptionID, for: workspaceKey) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID, for workspaceKey: TerminalGroupWorkspaceKey) {
        continuations[workspaceKey]?.removeValue(forKey: id)
        if continuations[workspaceKey]?.isEmpty == true {
            continuations.removeValue(forKey: workspaceKey)
        }
    }

    private func emitChange(for workspaceKey: TerminalGroupWorkspaceKey) {
        let revision = revisions[workspaceKey, default: 0] &+ 1
        revisions[workspaceKey] = revision
        let change = TerminalGroupSavedLayoutStoreChange(
            workspaceKey: workspaceKey, revision: revision)
        guard let workspaceContinuations = continuations[workspaceKey] else { return }
        for continuation in workspaceContinuations.values { continuation.yield(change) }
    }

    private func loadFile() throws -> TerminalGroupSavedLayoutStoreFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TerminalGroupSavedLayoutStoreFile(workspaces: [:])
        }
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw TerminalGroupPersistenceError.unreadableStoreFile
            }
            guard size.intValue <= TerminalGroupSavedLayoutStoreFile.maximumEncodedByteCount else {
                throw TerminalGroupPersistenceError.encodedFileTooLarge
            }
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch let error as TerminalGroupPersistenceError {
            throw error
        } catch {
            throw TerminalGroupPersistenceError.unreadableStoreFile
        }
        guard data.count <= TerminalGroupSavedLayoutStoreFile.maximumEncodedByteCount else {
            throw TerminalGroupPersistenceError.encodedFileTooLarge
        }
        do {
            try TerminalGroupSavedLayoutRawInspector.validate(data)
            return try JSONDecoder().decode(TerminalGroupSavedLayoutStoreFile.self, from: data)
        } catch let error as TerminalGroupPersistenceError {
            throw error
        } catch TerminalGroupRestorationError.unsupportedSavedLayoutSchema(let schemaVersion) {
            throw TerminalGroupPersistenceError.unsupportedSchema(schemaVersion)
        } catch {
            throw TerminalGroupPersistenceError.corruptStoreFile
        }
    }

    private func write(_ file: TerminalGroupSavedLayoutStoreFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        guard data.count <= TerminalGroupSavedLayoutStoreFile.maximumEncodedByteCount else {
            throw TerminalGroupPersistenceError.encodedFileTooLarge
        }
        do {
            try FileManager.default.createDirectory(
                at: storeDirectory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw TerminalGroupPersistenceError.unreadableStoreFile
        }
    }

    private func copied(
        _ group: SavedTerminalGroupRecord, withID id: SavedTerminalGroupID
    ) throws -> SavedTerminalGroupRecord {
        try SavedTerminalGroupRecord(
            id: id, name: group.name, root: group.root,
            focusedPaneID: group.focusedPaneID, panes: group.panes)
    }

    private func namesMatch(_ lhs: TerminalGroupName, _ rhs: TerminalGroupName) -> Bool {
        lhs.rawValue.compare(rhs.rawValue, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
    }
}

/// Performs a bounded, schema-specific raw check before Codable normalizes a
/// malformed record. This preserves typed validation errors for the UI and
/// prevents a future decoder default from changing the safe file contract.
private nonisolated enum TerminalGroupSavedLayoutRawInspector {
    private static let fileKeys: Set<String> = ["schemaVersion", "workspaces"]
    private static let envelopeKeys: Set<String> = ["schemaVersion", "workspaceKey", "groups"]
    private static let groupKeys: Set<String> = ["id", "name", "root", "focusedPaneID", "panes"]
    private static let paneKeys: Set<String> = [
        "id", "explicitUserName", "themeColor", "kind", "launchProfile",
    ]
    private static let profileKeys: Set<String> = ["shell", "startingFolder"]

    static func validate(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TerminalGroupPersistenceError.corruptStoreFile
        }
        guard let file = object as? [String: Any], Set(file.keys) == fileKeys else {
            throw TerminalGroupPersistenceError.corruptStoreFile
        }
        guard let schema = file["schemaVersion"] as? Int else {
            throw TerminalGroupPersistenceError.corruptStoreFile
        }
        guard schema == TerminalGroupSavedLayoutStoreFile.currentSchemaVersion else {
            throw TerminalGroupPersistenceError.unsupportedSchema(schema)
        }
        guard let workspaces = file["workspaces"] as? [String: Any] else {
            throw TerminalGroupPersistenceError.corruptStoreFile
        }
        for (workspaceDigest, rawEnvelope) in workspaces {
            guard let workspaceKey = TerminalGroupWorkspaceKey(rawValue: workspaceDigest),
                let envelope = rawEnvelope as? [String: Any], Set(envelope.keys) == envelopeKeys,
                let envelopeSchema = envelope["schemaVersion"] as? Int,
                let encodedKey = envelope["workspaceKey"] as? String,
                TerminalGroupWorkspaceKey(rawValue: encodedKey) == workspaceKey
            else { throw TerminalGroupPersistenceError.corruptStoreFile }
            guard envelopeSchema == TerminalGroupSavedLayoutEnvelope.currentSchemaVersion else {
                throw TerminalGroupPersistenceError.unsupportedSchema(envelopeSchema)
            }
            let groups = try groups(in: envelope["groups"])
            guard groups.count <= TerminalGroupSavedLayoutEnvelope.maximumSavedLayouts else {
                throw TerminalGroupPersistenceError.exceededBounds
            }
            for (mapKey, rawGroup) in groups {
                guard try validateGroup(rawGroup) == mapKey else {
                    throw TerminalGroupPersistenceError.invalidTree
                }
            }
        }
    }

    private static func groups(in rawGroups: Any?) throws -> [(String, Any)] {
        if let groups = rawGroups as? [String: Any] { return Array(groups) }
        guard let entries = rawGroups as? [Any], entries.count.isMultiple(of: 2) else {
            throw TerminalGroupPersistenceError.invalidTree
        }
        var keys = Set<String>()
        return try stride(from: 0, to: entries.count, by: 2).map { index in
            guard let key = idString(entries[index]) else {
                throw TerminalGroupPersistenceError.invalidTree
            }
            guard keys.insert(key).inserted else {
                throw TerminalGroupPersistenceError.duplicateID
            }
            return (key, entries[index + 1])
        }
    }

    private static func validateGroup(_ rawGroup: Any) throws -> String {
        guard let group = rawGroup as? [String: Any], Set(group.keys) == groupKeys,
            let groupID = idString(group["id"]), UUID(uuidString: groupID) != nil
        else { throw TerminalGroupPersistenceError.invalidTree }
        guard let name = group["name"] as? String else {
            throw TerminalGroupPersistenceError.invalidTree
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw TerminalGroupPersistenceError.invalidTree }
        guard trimmedName.unicodeScalars.count <= TerminalGroupName.maximumUnicodeScalarCount else {
            throw TerminalGroupPersistenceError.exceededBounds
        }
        guard let focusedPaneID = idString(group["focusedPaneID"]) else {
            throw TerminalGroupPersistenceError.missingFocusedPane
        }
        guard let rawPanes = group["panes"] as? [Any] else {
            throw TerminalGroupPersistenceError.invalidTree
        }
        guard rawPanes.count <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupPersistenceError.exceededBounds
        }
        var paneIDs: [String] = []
        for rawPane in rawPanes {
            paneIDs.append(try validatePane(rawPane))
        }
        guard Set(paneIDs).count == paneIDs.count else {
            throw TerminalGroupPersistenceError.duplicateID
        }
        var splitIDs: Set<String> = []
        let rootPaneIDs = try treePaneIDs(group["root"], splitIDs: &splitIDs)
        guard Set(rootPaneIDs).count == rootPaneIDs.count else {
            throw TerminalGroupPersistenceError.duplicateID
        }
        guard Set(rootPaneIDs) == Set(paneIDs), rootPaneIDs.count == paneIDs.count else {
            throw TerminalGroupPersistenceError.invalidTree
        }
        guard paneIDs.contains(focusedPaneID) else {
            throw TerminalGroupPersistenceError.missingFocusedPane
        }
        return groupID
    }

    private static func validatePane(_ rawPane: Any) throws -> String {
        guard let pane = rawPane as? [String: Any], Set(pane.keys).isSubset(of: paneKeys),
            let id = idString(pane["id"]), UUID(uuidString: id) != nil,
            let kind = pane["kind"] as? String
        else { throw TerminalGroupPersistenceError.invalidTree }
        if let explicitUserName = pane["explicitUserName"] as? String {
            let trimmedName = explicitUserName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw TerminalGroupPersistenceError.invalidTree }
            guard trimmedName.unicodeScalars.count <= TerminalPaneName.maximumUnicodeScalarCount
            else {
                throw TerminalGroupPersistenceError.exceededBounds
            }
        }
        guard let savedKind = SavedTerminalPaneKind(rawValue: kind) else {
            throw TerminalGroupPersistenceError.unknownSavedPaneKind
        }
        let profile = pane["launchProfile"]
        switch savedKind {
        case .ordinaryShell:
            guard let profile, !(profile is NSNull) else {
                throw TerminalGroupPersistenceError.missingShellProfile
            }
            try validateProfile(profile)
        case .unavailableAgentTerminal, .unavailableEnsemble:
            guard profile == nil || profile is NSNull else {
                throw TerminalGroupPersistenceError.unknownSavedPaneKind
            }
        }
        return id
    }

    private static func validateProfile(_ rawProfile: Any) throws {
        guard let profile = rawProfile as? [String: Any],
            Set(profile.keys).isSubset(of: profileKeys)
        else {
            throw TerminalGroupPersistenceError.missingShellProfile
        }
        guard let rawShell = profile["shell"], !(rawShell is NSNull) else {
            throw TerminalGroupPersistenceError.missingShellProfile
        }
        guard let shell = rawShell as? String,
            shell == "preferred" || TerminalPaneShellChoice(approvedShellPath: shell) != nil
        else { throw TerminalGroupPersistenceError.unapprovedShellProfile }
        guard let folder = profile["startingFolder"] as? String else {
            throw TerminalGroupPersistenceError.missingStartingFolder
        }
        guard folder.utf8.count <= TerminalWorkspaceRelativePath.maximumUTF8Length else {
            throw TerminalGroupPersistenceError.exceededBounds
        }
        guard TerminalWorkspaceRelativePath(folder) != nil else {
            throw TerminalGroupPersistenceError.invalidRelativePath
        }
    }

    private static func treePaneIDs(
        _ rawNode: Any?, splitIDs: inout Set<String>
    ) throws -> [String] {
        guard let node = rawNode as? [String: Any], node.count == 1 else {
            throw TerminalGroupPersistenceError.invalidTree
        }
        if let rawPane = node["pane"] {
            if let paneID = idString(rawPane) { return [paneID] }
            if let container = rawPane as? [String: Any], let paneID = idString(container["_0"]) {
                return [paneID]
            }
            throw TerminalGroupPersistenceError.invalidTree
        }
        guard let rawSplit = node["split"] as? [String: Any] else {
            throw TerminalGroupPersistenceError.invalidTree
        }
        let split = rawSplit["_0"] as? [String: Any] ?? rawSplit
        guard let splitID = idString(split["id"]), UUID(uuidString: splitID) != nil,
            splitIDs.insert(splitID).inserted
        else { throw TerminalGroupPersistenceError.duplicateID }
        guard let axis = split["axis"] as? String,
            TerminalGroupSplitAxis(rawValue: axis) != nil
        else { throw TerminalGroupPersistenceError.invalidTree }
        guard let fraction = split["fraction"] as? Double, fraction.isFinite,
            (TerminalGroupSnapshot.minimumSplitFraction...TerminalGroupSnapshot.maximumSplitFraction)
                .contains(fraction)
        else { throw TerminalGroupPersistenceError.invalidFraction }
        let first = try treePaneIDs(split["first"], splitIDs: &splitIDs)
        let second = try treePaneIDs(split["second"], splitIDs: &splitIDs)
        return first + second
    }

    private static func idString(_ rawID: Any?) -> String? {
        if let id = rawID as? String { return id }
        return (rawID as? [String: Any])?["rawValue"] as? String
    }
}

private nonisolated struct TerminalGroupSavedLayoutStoreRegistryKey: Hashable, Sendable {
    let identity: RafuAppIdentity
    let standardizedBasePath: String
}

private actor TerminalGroupSavedLayoutStoreRegistry {
    static let shared = TerminalGroupSavedLayoutStoreRegistry()
    private var stores: [TerminalGroupSavedLayoutStoreRegistryKey: TerminalGroupSavedLayoutStore] =
        [:]

    func store(identity: RafuAppIdentity, baseDirectory: URL) -> TerminalGroupSavedLayoutStore {
        let key = TerminalGroupSavedLayoutStoreRegistryKey(
            identity: identity,
            standardizedBasePath: baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path)
        if let existing = stores[key] { return existing }
        let store = TerminalGroupSavedLayoutStore(identity: identity, baseDirectory: baseDirectory)
        stores[key] = store
        return store
    }
}
