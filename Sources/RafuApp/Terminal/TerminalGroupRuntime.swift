import Foundation

/// The manager-only, already-validated input used to create a lazy terminal
/// controller and bind it to one pane. Constructing a controller is not a
/// process start: SwiftTerm still starts the child only when its view mounts.
nonisolated enum TerminalGroupControllerInstantiation: Sendable {
    case ordinaryShell(
        startingDirectory: String,
        shell: TerminalShell,
        profile: TerminalPaneLaunchProfile
    )
    case process(spec: TerminalProcessSpec, kind: TerminalPaneRuntimeKind)
}

/// The value-only part of the Terminal Group aggregate. It owns no terminal
/// view, controller, process, or persistence store. This keeps all group
/// mutations safe to test without mounting SwiftTerm or starting a shell.
nonisolated struct TerminalGroupRuntime: Sendable {
    private(set) var groups: [TerminalGroupID: TerminalGroupSnapshot] = [:]
    private(set) var parkedGroupIDs: [TerminalGroupID] = []
    private(set) var generation: UInt64 = 1
    private var nextDefaultNameNumber = 1

    var snapshots: [TerminalGroupSnapshot] {
        groups.values.sorted { lhs, rhs in
            let nameOrder = lhs.name.rawValue.localizedStandardCompare(rhs.name.rawValue)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
        }
    }

    func snapshot(groupID: TerminalGroupID) -> TerminalGroupSnapshot? {
        groups[groupID]
    }

    func groupID(containing paneID: TerminalPaneID) -> TerminalGroupID? {
        groups.first { $0.value.root.paneIDs.contains(paneID) }?.key
    }

    func groupAndPane(containing sessionID: UUID) -> (TerminalGroupID, TerminalPaneID)? {
        for (groupID, group) in groups {
            if let pane = group.panes.first(where: { $0.sessionID == sessionID }) {
                return (groupID, pane.id)
            }
        }
        return nil
    }

    var retainedPaneCount: Int { groups.values.reduce(into: 0) { $0 += $1.panes.count } }

    var liveSessionCount: Int {
        groups.values.reduce(into: 0) { result, group in
            result += group.panes.filter { $0.status == .live }.count
        }
    }

    /// Inserts one inert runtime instance of a saved layout. Saved identities
    /// are deliberately remapped so opening the same record twice cannot
    /// mirror a pane, split, or session. This path creates no controller.
    mutating func insertStoppedSavedGroup(_ record: SavedTerminalGroupRecord) throws
        -> TerminalGroupID
    {
        try requireRetainedCapacity(record.panes.count)
        var paneMap: [SavedTerminalPaneID: TerminalPaneID] = [:]
        var panes: [TerminalPaneSnapshot] = []
        for savedPane in record.panes {
            let paneID = TerminalPaneID()
            paneMap[savedPane.id] = paneID
            let snapshot: TerminalPaneSnapshot
            switch savedPane.kind {
            case .ordinaryShell:
                snapshot = try TerminalPaneSnapshot(
                    id: paneID, sessionID: nil, explicitUserName: savedPane.explicitUserName,
                    reportedTitle: nil, runtimeKind: .ordinaryShell,
                    themeColor: savedPane.themeColor,
                    status: .stopped, launchProfile: savedPane.launchProfile,
                    startAvailability: .available)
            case .unavailableAgentTerminal:
                snapshot = try TerminalPaneSnapshot(
                    id: paneID, sessionID: nil, explicitUserName: savedPane.explicitUserName,
                    reportedTitle: nil, runtimeKind: .unavailableAgentTerminal,
                    themeColor: savedPane.themeColor, status: .unavailable, launchProfile: nil,
                    startAvailability: .unavailable)
            case .unavailableEnsemble:
                snapshot = try TerminalPaneSnapshot(
                    id: paneID, sessionID: nil, explicitUserName: savedPane.explicitUserName,
                    reportedTitle: nil, runtimeKind: .unavailableEnsemble,
                    themeColor: savedPane.themeColor, status: .unavailable, launchProfile: nil,
                    startAvailability: .unavailable)
            }
            panes.append(snapshot)
        }
        let root = try runtimeNode(from: record.root, paneMap: paneMap)
        guard let focusedPaneID = paneMap[record.focusedPaneID] else {
            throw TerminalGroupValidationError.savedLayoutNotFound(record.id)
        }
        let groupID = TerminalGroupID()
        let snapshot = try TerminalGroupSnapshot(
            id: groupID, name: record.name, root: root, focusedPaneID: focusedPaneID,
            savedLayoutID: record.id, panes: panes,
            retainedPaneCount: retainedPaneCount + panes.count)
        return try insertInertSnapshot(snapshot).id
    }

    /// Inserts a TG-22-decoded inert instance without remapping its already
    /// re-keyed runtime identities. It accepts only zero-session stopped or
    /// unavailable panes and never constructs a controller or process.
    mutating func insertInertSnapshot(_ snapshot: TerminalGroupSnapshot) throws
        -> TerminalGroupSnapshot
    {
        try requireRetainedCapacity(snapshot.panes.count)
        let incomingPaneIDs = Set(snapshot.panes.map(\.id))
        let existingPaneIDs = Set(groups.values.flatMap { $0.panes.map(\.id) })
        let incomingSplitIDs = Set(snapshot.root.splitIDs)
        let existingSplitIDs = Set(groups.values.flatMap { $0.root.splitIDs })
        guard groups[snapshot.id] == nil,
            existingPaneIDs.isDisjoint(with: incomingPaneIDs),
            existingSplitIDs.isDisjoint(with: incomingSplitIDs),
            snapshot.panes.allSatisfy(isValidInertDecodedPane)
        else { throw TerminalGroupValidationError.unsupportedPaneStart }

        let inserted = try TerminalGroupSnapshot(
            id: snapshot.id, name: snapshot.name, root: snapshot.root,
            focusedPaneID: snapshot.focusedPaneID, savedLayoutID: snapshot.savedLayoutID,
            panes: snapshot.panes, retainedPaneCount: retainedPaneCount + snapshot.panes.count)
        groups[inserted.id] = inserted
        advanceGeneration()
        return inserted
    }

    private func isValidInertDecodedPane(_ pane: TerminalPaneSnapshot) -> Bool {
        guard pane.sessionID == nil, pane.reportedTitle == nil else { return false }
        switch pane.runtimeKind {
        case .ordinaryShell:
            guard pane.status == .stopped, pane.launchProfile != nil else { return false }
            return pane.startAvailability == .available || pane.startAvailability == .unavailable
        case .unavailableAgentTerminal, .unavailableEnsemble:
            // TG-10's `TerminalPaneSnapshot` initializer has already pinned
            // their unavailable status, nil profile, and unavailable start.
            return pane.status == .unavailable
        case .directAgentTerminal, .ensembleRole, .ensembleCoordinator:
            return false
        }
    }

    /// Adds a live pane only after the manager has constructed its controller
    /// and completed capacity/profile preflight. No process can start here.
    mutating func createLiveGroup(
        name: TerminalGroupName?,
        sessionID: UUID,
        pane: TerminalPaneSnapshot
    ) throws -> TerminalGroupID {
        try requireRetainedCapacity(1)
        try requireLiveCapacity(1)
        guard pane.sessionID == sessionID, pane.status == .live else {
            throw TerminalGroupValidationError.unsupportedPaneStart
        }
        guard groupID(containing: pane.id) == nil,
            groupAndPane(containing: sessionID) == nil
        else {
            throw TerminalGroupValidationError.unsupportedPaneStart
        }
        let groupID = TerminalGroupID()
        let groupName = name ?? defaultName()
        groups[groupID] = try TerminalGroupSnapshot(
            id: groupID, name: groupName, root: .pane(pane.id), focusedPaneID: pane.id,
            savedLayoutID: nil, panes: [pane], retainedPaneCount: retainedPaneCount + 1)
        if name == nil { nextDefaultNameNumber += 1 }
        advanceGeneration()
        return groupID
    }

    /// Adopts a manager-owned legacy controller into one new group. This is
    /// membership-only: the manager retains the controller and this reducer
    /// receives only its already-classified immutable pane projection.
    mutating func adoptUngroupedSession(
        sessionID: UUID,
        pane: TerminalPaneSnapshot
    ) throws -> TerminalGroupID {
        try requireRetainedCapacity(1)
        guard pane.sessionID == sessionID,
            pane.status == .live || pane.status == .exited,
            groupID(containing: pane.id) == nil,
            groupAndPane(containing: sessionID) == nil
        else { throw TerminalGroupValidationError.unsupportedPaneStart }
        if pane.status == .live { try requireLiveCapacity(1) }

        let groupID = TerminalGroupID()
        let groupName = defaultName()
        groups[groupID] = try TerminalGroupSnapshot(
            id: groupID, name: groupName, root: .pane(pane.id), focusedPaneID: pane.id,
            savedLayoutID: nil, panes: [pane], retainedPaneCount: retainedPaneCount + 1)
        nextDefaultNameNumber += 1
        advanceGeneration()
        return groupID
    }

    mutating func bindLazyController(
        sessionID: UUID,
        to paneID: TerminalPaneID
    ) throws {
        guard groupAndPane(containing: sessionID) == nil,
            let groupID = groupID(containing: paneID), let group = groups[groupID],
            let index = group.panes.firstIndex(where: { $0.id == paneID })
        else { throw TerminalGroupValidationError.unsupportedPaneStart }
        let pane = group.panes[index]
        guard pane.startAvailability == .available, pane.launchProfile != nil,
            pane.status == .stopped || pane.status == .exited
        else { throw TerminalGroupValidationError.unsupportedPaneStart }
        try requireLiveCapacity(1)
        var panes = group.panes
        panes[index] = try TerminalPaneSnapshot(
            id: pane.id, sessionID: sessionID, explicitUserName: pane.explicitUserName,
            reportedTitle: pane.reportedTitle, runtimeKind: pane.runtimeKind,
            themeColor: pane.themeColor, status: .live, launchProfile: pane.launchProfile,
            startAvailability: pane.startAvailability)
        groups[groupID] = try TerminalGroupSnapshot(
            id: group.id, name: group.name, root: group.root, focusedPaneID: group.focusedPaneID,
            savedLayoutID: group.savedLayoutID, panes: panes, retainedPaneCount: retainedPaneCount)
        advanceGeneration()
    }

    mutating func markSessionExited(_ sessionID: UUID) -> Bool {
        guard let (groupID, paneID) = groupAndPane(containing: sessionID),
            let group = groups[groupID],
            let index = group.panes.firstIndex(where: { $0.id == paneID })
        else { return false }
        let pane = group.panes[index]
        guard pane.status == .live else { return false }
        guard let exited = try? withStatus(pane, .exited) else { return false }
        var panes = group.panes
        panes[index] = exited
        guard
            let replacement = try? TerminalGroupSnapshot(
                id: group.id, name: group.name, root: group.root,
                focusedPaneID: group.focusedPaneID,
                savedLayoutID: group.savedLayoutID, panes: panes,
                retainedPaneCount: retainedPaneCount)
        else { return false }
        groups[groupID] = replacement
        advanceGeneration()
        return true
    }

    mutating func restartBoundController(sessionID: UUID, paneID: TerminalPaneID) throws {
        guard let groupID = groupID(containing: paneID), let group = groups[groupID],
            let index = group.panes.firstIndex(where: { $0.id == paneID })
        else { throw TerminalGroupValidationError.paneNotFound(paneID) }
        let pane = group.panes[index]
        guard pane.sessionID == sessionID, pane.status == .exited,
            pane.startAvailability == .available, pane.launchProfile != nil
        else { throw TerminalGroupValidationError.unsupportedPaneStart }
        try requireLiveCapacity(1)
        var panes = group.panes
        panes[index] = try withStatus(pane, .live)
        groups[groupID] = try TerminalGroupSnapshot(
            id: group.id, name: group.name, root: group.root,
            focusedPaneID: group.focusedPaneID, savedLayoutID: group.savedLayoutID,
            panes: panes, retainedPaneCount: retainedPaneCount)
        advanceGeneration()
    }

    /// UI text arrives as raw input, while the frozen command carries an
    /// already-valid value. Empty text intentionally restores the next
    /// bounded default name rather than leaving an invalid group name.
    mutating func renameGroup(_ groupID: TerminalGroupID, rawName: String) throws {
        let group = try requireGroup(groupID)
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: TerminalGroupName
        if trimmed.isEmpty {
            name = defaultName()
            nextDefaultNameNumber += 1
        } else if let parsed = TerminalGroupName(trimmed) {
            name = parsed
        } else {
            throw TerminalGroupValidationError.invalidName
        }
        groups[groupID] = try replacing(group, name: name)
        advanceGeneration()
    }

    mutating func perform(_ command: TerminalGroupCommand) throws -> TerminalGroupEffect {
        switch command {
        case .createGroup(let requestedName):
            try requireRetainedCapacity(1)
            let groupID = TerminalGroupID()
            let paneID = TerminalPaneID()
            let name = requestedName ?? defaultName()
            let pane = try stoppedShellPane(id: paneID)
            let group = try TerminalGroupSnapshot(
                id: groupID, name: name, root: .pane(paneID), focusedPaneID: paneID,
                savedLayoutID: nil, panes: [pane], retainedPaneCount: retainedPaneCount + 1)
            groups[groupID] = group
            if requestedName == nil { nextDefaultNameNumber += 1 }
            advanceGeneration()
            return .insertEditorTab(groupID: groupID)

        case .splitFocusedPane(let groupID, let placement):
            var group = try requireGroup(groupID)
            try requireGroupCapacity(group, requested: 1)
            try requireRetainedCapacity(1)
            let paneID = TerminalPaneID()
            let focused = try requirePane(group.focusedPaneID, in: group)
            let newPane = try splitPane(id: paneID, from: focused)
            let root = try inserting(
                paneID, after: group.focusedPaneID, placement: placement, in: group.root)
            group = try TerminalGroupSnapshot(
                id: group.id, name: group.name, root: root, focusedPaneID: paneID,
                savedLayoutID: group.savedLayoutID, panes: group.panes + [newPane],
                retainedPaneCount: retainedPaneCount + 1)
            groups[groupID] = group
            advanceGeneration()
            return .persistWorkspaceRestoration

        case .focusPane(let groupID, let paneID):
            var group = try requireGroup(groupID)
            _ = try requirePane(paneID, in: group)
            group = try replacing(group, focusedPaneID: paneID)
            groups[groupID] = group
            advanceGeneration()
            return .selectEditorTab(groupID: groupID)

        case .focusDirection(let groupID, let direction):
            var group = try requireGroup(groupID)
            guard let target = directionalTarget(in: group, direction: direction) else {
                return .selectEditorTab(groupID: groupID)
            }
            group = try replacing(group, focusedPaneID: target)
            groups[groupID] = group
            advanceGeneration()
            return .selectEditorTab(groupID: groupID)

        case .renameGroup(let groupID, let name):
            let group = try requireGroup(groupID)
            groups[groupID] = try replacing(group, name: name)
            advanceGeneration()
            return .persistWorkspaceRestoration

        case .commitSavedLayout(let groupID, let savedLayoutID, let name):
            let group = try requireGroup(groupID)
            groups[groupID] = try TerminalGroupSnapshot(
                id: group.id, name: name, root: group.root, focusedPaneID: group.focusedPaneID,
                savedLayoutID: savedLayoutID, panes: group.panes,
                retainedPaneCount: retainedPaneCount)
            advanceGeneration()
            return .persistSavedLayout(savedLayoutID)

        case .detachDeletedSavedLayout(let savedLayoutID):
            var changed = false
            for (groupID, group) in groups where group.savedLayoutID == savedLayoutID {
                groups[groupID] = try TerminalGroupSnapshot(
                    id: group.id, name: group.name, root: group.root,
                    focusedPaneID: group.focusedPaneID,
                    savedLayoutID: nil, panes: group.panes, retainedPaneCount: retainedPaneCount)
                changed = true
            }
            if changed { advanceGeneration() }
            return .persistWorkspaceRestoration

        case .setPaneStartingFolder(let paneID, let folder):
            guard let groupID = groupID(containing: paneID) else {
                throw TerminalGroupValidationError.paneNotFound(paneID)
            }
            let group = try requireGroup(groupID)
            var panes = group.panes
            guard let index = panes.firstIndex(where: { $0.id == paneID }) else {
                throw TerminalGroupValidationError.paneNotFound(paneID)
            }
            guard var profile = panes[index].launchProfile else {
                throw TerminalGroupValidationError.unsupportedPaneStart
            }
            profile = TerminalPaneLaunchProfile(shell: profile.shell, startingFolder: folder)
            panes[index] = try TerminalPaneSnapshot(
                id: panes[index].id, sessionID: panes[index].sessionID,
                explicitUserName: panes[index].explicitUserName,
                reportedTitle: panes[index].reportedTitle,
                runtimeKind: panes[index].runtimeKind, themeColor: panes[index].themeColor,
                status: panes[index].status, launchProfile: profile,
                startAvailability: panes[index].startAvailability)
            groups[groupID] = try TerminalGroupSnapshot(
                id: group.id, name: group.name, root: group.root,
                focusedPaneID: group.focusedPaneID,
                savedLayoutID: group.savedLayoutID, panes: panes,
                retainedPaneCount: retainedPaneCount)
            advanceGeneration()
            return .persistWorkspaceRestoration

        case .setDividerFraction(let splitID, let fraction):
            guard fraction.isFinite else {
                throw TerminalGroupValidationError.invalidDividerFraction
            }
            guard
                let groupID = groups.first(where: { $0.value.root.splitIDs.contains(splitID) })?
                    .key,
                let group = groups[groupID]
            else { throw TerminalGroupValidationError.splitNotFound(splitID) }
            let root = try replacingFraction(splitID, fraction: fraction, in: group.root)
            groups[groupID] = try TerminalGroupSnapshot(
                id: group.id, name: group.name, root: root, focusedPaneID: group.focusedPaneID,
                savedLayoutID: group.savedLayoutID, panes: group.panes,
                retainedPaneCount: retainedPaneCount)
            advanceGeneration()
            return .persistWorkspaceRestoration

        case .parkGroup(let groupID):
            _ = try requireGroup(groupID)
            parkedGroupIDs.removeAll { $0 == groupID }
            parkedGroupIDs.insert(groupID, at: 0)
            advanceGeneration()
            return .removeEditorTab(groupID: groupID)

        case .revealGroup(let groupID):
            _ = try requireGroup(groupID)
            parkedGroupIDs.removeAll { $0 == groupID }
            advanceGeneration()
            return .selectEditorTab(groupID: groupID)

        case .prepareClose(let target):
            let token = try closeToken(for: target)
            return .requestCloseConfirmation(token)

        case .finalizeClose(let token):
            guard token.generation == generation else {
                throw TerminalGroupValidationError.staleCloseToken
            }
            return try finalizeClose(token)

        case .restartExitedShellPane, .startPane, .startAllRestartablePanes:
            // A start needs a validated controller instantiation. The manager
            // performs that transaction through `startPane` or
            // `startAllRestartablePanes`; this pure command cannot create a
            // false live pane with no bound controller.
            throw TerminalGroupValidationError.unsupportedPaneStart

        case .insertStoppedSavedGroup(let savedLayoutID):
            throw TerminalGroupValidationError.savedLayoutNotFound(savedLayoutID)
        }
    }

    mutating func shutdown() {
        groups = [:]
        parkedGroupIDs = []
        nextDefaultNameNumber = 1
        advanceGeneration()
    }

    private mutating func finalizeClose(_ token: TerminalGroupCloseToken) throws
        -> TerminalGroupEffect
    {
        switch token.target {
        case .pane(let paneID):
            guard let groupID = groupID(containing: paneID), let group = groups[groupID] else {
                throw TerminalGroupValidationError.staleCloseToken
            }
            let remainingPanes = group.panes.filter { $0.id != paneID }
            if remainingPanes.isEmpty {
                groups[groupID] = nil
                parkedGroupIDs.removeAll { $0 == groupID }
                advanceGeneration()
                return .removeEditorTab(groupID: groupID)
            }
            guard let root = removing(paneID, from: group.root) else {
                throw TerminalGroupValidationError.staleCloseToken
            }
            let focused = group.focusedPaneID == paneID ? root.paneIDs[0] : group.focusedPaneID
            groups[groupID] = try TerminalGroupSnapshot(
                id: group.id, name: group.name, root: root, focusedPaneID: focused,
                savedLayoutID: group.savedLayoutID, panes: remainingPanes,
                retainedPaneCount: retainedPaneCount - 1)
            advanceGeneration()
            return .cleanupProcesses(sessionIDs: token.affectedSessionIDs)

        case .group(let groupID):
            guard groups[groupID] != nil else { throw TerminalGroupValidationError.staleCloseToken }
            groups[groupID] = nil
            parkedGroupIDs.removeAll { $0 == groupID }
            advanceGeneration()
            return .removeEditorTab(groupID: groupID)
        }
    }

    private func closeToken(for target: TerminalGroupCloseTarget) throws -> TerminalGroupCloseToken
    {
        let panes: [TerminalPaneSnapshot]
        switch target {
        case .pane(let paneID):
            guard let groupID = groupID(containing: paneID),
                let pane = groups[groupID]?.panes.first(where: { $0.id == paneID })
            else {
                throw TerminalGroupValidationError.paneNotFound(paneID)
            }
            panes = [pane]
        case .group(let groupID):
            let group = try requireGroup(groupID)
            panes = group.root.paneIDs.compactMap { paneID in group.panes.first { $0.id == paneID }
            }
        }
        let sessions = panes.compactMap(\.sessionID)
        guard
            let token = TerminalGroupCloseToken(
                target: target, affectedSessionIDs: sessions,
                liveProcessCount: panes.filter { $0.status == .live }.count, generation: generation)
        else { throw TerminalGroupValidationError.staleCloseToken }
        return token
    }

    private func defaultName() -> TerminalGroupName {
        // This literal is bounded and cannot fail. Keep the assertion near the
        // fallback so an invalid future format cannot create malformed state.
        TerminalGroupName("Terminal Group \(nextDefaultNameNumber)")!
    }

    private mutating func advanceGeneration() {
        generation &+= 1
        if generation == 0 { generation = 1 }
    }

    private func requireGroup(_ id: TerminalGroupID) throws -> TerminalGroupSnapshot {
        guard let group = groups[id] else { throw TerminalGroupValidationError.groupNotFound(id) }
        return group
    }

    private func requirePane(_ id: TerminalPaneID, in group: TerminalGroupSnapshot) throws
        -> TerminalPaneSnapshot
    {
        guard let pane = group.panes.first(where: { $0.id == id }) else {
            throw TerminalGroupValidationError.paneNotFound(id)
        }
        return pane
    }

    private func requireGroupCapacity(_ group: TerminalGroupSnapshot, requested: Int) throws {
        guard group.panes.count + requested <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupCapacityError.groupPaneLimitExceeded(
                current: group.panes.count, requested: requested)
        }
    }

    private func requireRetainedCapacity(_ requested: Int) throws {
        guard retainedPaneCount + requested <= TerminalGroupSnapshot.maximumRetainedPanesPerWindow
        else {
            throw TerminalGroupCapacityError.retainedPaneLimitExceeded(
                current: retainedPaneCount, requested: requested)
        }
    }

    private func requireLiveCapacity(_ requested: Int) throws {
        guard liveSessionCount + requested <= TerminalGroupSnapshot.maximumPanesPerGroup else {
            throw TerminalGroupCapacityError.liveSessionLimitExceeded(
                current: liveSessionCount, requested: requested)
        }
    }

    private func withStatus(_ pane: TerminalPaneSnapshot, _ status: TerminalPaneStatus) throws
        -> TerminalPaneSnapshot
    {
        try TerminalPaneSnapshot(
            id: pane.id, sessionID: pane.sessionID, explicitUserName: pane.explicitUserName,
            reportedTitle: pane.reportedTitle, runtimeKind: pane.runtimeKind,
            themeColor: pane.themeColor,
            status: status, launchProfile: pane.launchProfile,
            startAvailability: pane.startAvailability)
    }

    private func stoppedShellPane(id: TerminalPaneID) throws -> TerminalPaneSnapshot {
        try TerminalPaneSnapshot(
            id: id, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
            runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
            launchProfile: TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root),
            startAvailability: .available)
    }

    private func runtimeNode(
        from savedNode: SavedTerminalGroupNode,
        paneMap: [SavedTerminalPaneID: TerminalPaneID]
    ) throws -> TerminalGroupNode {
        switch savedNode {
        case .pane(let savedPaneID):
            guard let paneID = paneMap[savedPaneID] else {
                throw TerminalGroupValidationError.savedLayoutNotFound(SavedTerminalGroupID())
            }
            return .pane(paneID)
        case .split(_, let axis, let fraction, let first, let second):
            return .split(
                id: TerminalGroupSplitID(), axis: axis,
                fraction: TerminalGroupSnapshot.normalizedFraction(fraction),
                first: try runtimeNode(from: first, paneMap: paneMap),
                second: try runtimeNode(from: second, paneMap: paneMap))
        }
    }

    private func splitPane(id: TerminalPaneID, from source: TerminalPaneSnapshot) throws
        -> TerminalPaneSnapshot
    {
        let profile = source.startAvailability == .available ? source.launchProfile : nil
        return try TerminalPaneSnapshot(
            id: id, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
            runtimeKind: .ordinaryShell, themeColor: source.themeColor, status: .stopped,
            launchProfile: profile
                ?? TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root),
            startAvailability: .available)
    }

    private func replacing(
        _ group: TerminalGroupSnapshot,
        name: TerminalGroupName? = nil,
        focusedPaneID: TerminalPaneID? = nil
    ) throws -> TerminalGroupSnapshot {
        try TerminalGroupSnapshot(
            id: group.id, name: name ?? group.name, root: group.root,
            focusedPaneID: focusedPaneID ?? group.focusedPaneID,
            savedLayoutID: group.savedLayoutID, panes: group.panes,
            retainedPaneCount: retainedPaneCount)
    }

    private func inserting(
        _ newPaneID: TerminalPaneID, after existingPaneID: TerminalPaneID,
        placement: TerminalGroupSplitPlacement, in node: TerminalGroupNode
    ) throws -> TerminalGroupNode {
        switch node {
        case .pane(let paneID):
            guard paneID == existingPaneID else { return node }
            return .split(
                id: TerminalGroupSplitID(), axis: placement.axis,
                fraction: TerminalGroupSnapshot.defaultSplitFraction,
                first: .pane(paneID), second: .pane(newPaneID))
        case .split(let id, let axis, let fraction, let first, let second):
            if first.paneIDs.contains(existingPaneID) {
                return .split(
                    id: id, axis: axis, fraction: fraction,
                    first: try inserting(
                        newPaneID, after: existingPaneID, placement: placement, in: first),
                    second: second)
            }
            if second.paneIDs.contains(existingPaneID) {
                return .split(
                    id: id, axis: axis, fraction: fraction, first: first,
                    second: try inserting(
                        newPaneID, after: existingPaneID, placement: placement, in: second))
            }
            return node
        }
    }

    private func removing(_ paneID: TerminalPaneID, from node: TerminalGroupNode)
        -> TerminalGroupNode?
    {
        switch node {
        case .pane(let id): return id == paneID ? nil : node
        case .split(let id, let axis, let fraction, let first, let second):
            let reducedFirst = removing(paneID, from: first)
            let reducedSecond = removing(paneID, from: second)
            switch (reducedFirst, reducedSecond) {
            case (nil, nil): return nil
            case (let surviving?, nil), (nil, let surviving?): return surviving
            case (let survivingFirst?, let survivingSecond?):
                return .split(
                    id: id, axis: axis, fraction: fraction, first: survivingFirst,
                    second: survivingSecond)
            }
        }
    }

    private func replacingFraction(
        _ splitID: TerminalGroupSplitID, fraction: Double, in node: TerminalGroupNode
    ) throws -> TerminalGroupNode {
        switch node {
        case .pane: return node
        case .split(let id, let axis, let current, let first, let second):
            if id == splitID {
                return .split(
                    id: id, axis: axis,
                    fraction: TerminalGroupSnapshot.normalizedFraction(fraction), first: first,
                    second: second)
            }
            return .split(
                id: id, axis: axis, fraction: current,
                first: try replacingFraction(splitID, fraction: fraction, in: first),
                second: try replacingFraction(splitID, fraction: fraction, in: second))
        }
    }

    private struct NormalizedRect {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var midX: Double { x + width / 2 }
        var midY: Double { y + height / 2 }
    }

    private func directionalTarget(
        in group: TerminalGroupSnapshot, direction: TerminalPaneFocusDirection
    ) -> TerminalPaneID? {
        var frames: [(TerminalPaneID, NormalizedRect)] = []
        appendFrames(
            for: group.root, rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1), into: &frames)
        guard let source = frames.first(where: { $0.0 == group.focusedPaneID }) else { return nil }
        let candidates = frames.enumerated().compactMap {
            index, candidate -> (Int, TerminalPaneID, Double, Double)? in
            guard candidate.0 != source.0 else { return nil }
            let dx = candidate.1.midX - source.1.midX
            let dy = candidate.1.midY - source.1.midY
            let inHalfPlane: Bool
            let primary: Double
            let cross: Double
            switch direction {
            case .left:
                inHalfPlane = dx < 0
                primary = -dx
                cross = abs(dy)
            case .right:
                inHalfPlane = dx > 0
                primary = dx
                cross = abs(dy)
            case .up:
                inHalfPlane = dy < 0
                primary = -dy
                cross = abs(dx)
            case .down:
                inHalfPlane = dy > 0
                primary = dy
                cross = abs(dx)
            }
            return inHalfPlane ? (index, candidate.0, primary, cross) : nil
        }
        return candidates.min { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            if lhs.3 != rhs.3 { return lhs.3 < rhs.3 }
            return lhs.0 < rhs.0
        }?.1
    }

    private func appendFrames(
        for node: TerminalGroupNode, rect: NormalizedRect,
        into result: inout [(TerminalPaneID, NormalizedRect)]
    ) {
        switch node {
        case .pane(let paneID): result.append((paneID, rect))
        case .split(_, let axis, let fraction, let first, let second):
            let f = TerminalGroupSnapshot.normalizedFraction(fraction)
            if axis == .columns {
                appendFrames(
                    for: first,
                    rect: NormalizedRect(
                        x: rect.x, y: rect.y, width: rect.width * f, height: rect.height),
                    into: &result)
                appendFrames(
                    for: second,
                    rect: NormalizedRect(
                        x: rect.x + rect.width * f, y: rect.y, width: rect.width * (1 - f),
                        height: rect.height), into: &result)
            } else {
                appendFrames(
                    for: first,
                    rect: NormalizedRect(
                        x: rect.x, y: rect.y, width: rect.width, height: rect.height * f),
                    into: &result)
                appendFrames(
                    for: second,
                    rect: NormalizedRect(
                        x: rect.x, y: rect.y + rect.height * f, width: rect.width,
                        height: rect.height * (1 - f)), into: &result)
            }
        }
    }
}
