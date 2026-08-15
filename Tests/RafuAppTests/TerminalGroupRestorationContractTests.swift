import Foundation
import Testing

@testable import RafuApp

private enum TerminalGroupRestorationTestError: Error {
    case invalidTestValue
}

private func explicitPaneName(_ value: String) throws -> TerminalPaneName {
    guard let name = TerminalPaneName(value) else {
        throw TerminalGroupRestorationTestError.invalidTestValue
    }
    return name
}

private func terminalGroupRestorationRecord() throws -> TerminalGroupOpenTabRestorationRecord {
    let paneID = TerminalPaneID()
    let paneName = try explicitPaneName("Explicit pane name")
    return try TerminalGroupOpenTabRestorationRecord(
        groupID: TerminalGroupID(),
        name: try #require(TerminalGroupName("Safe group")),
        root: .pane(paneID),
        focusedPaneID: paneID,
        savedLayoutID: SavedTerminalGroupID(),
        panes: [
            try TerminalGroupOpenPaneRestorationRecord(
                id: paneID,
                explicitUserName: paneName,
                themeColor: .accent,
                kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell,
                    startingFolder: try #require(TerminalWorkspaceRelativePath("Sources"))
                )
            )
        ]
    )
}

private func savedTerminalGroupRecord() throws -> SavedTerminalGroupRecord {
    let paneID = SavedTerminalPaneID()
    return try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(),
        name: try #require(TerminalGroupName("Saved group")),
        root: .pane(paneID),
        focusedPaneID: paneID,
        panes: [
            try SavedTerminalPaneRecord(
                id: paneID,
                explicitUserName: try explicitPaneName("Saved pane"),
                themeColor: .accent,
                kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell,
                    startingFolder: .root
                )
            )
        ]
    )
}

private func restorableWorkspaceJSON() throws -> [String: Any] {
    let workspace = RestorableWorkspace(
        bookmark: Data([1, 2, 3]),
        rootPath: "/workspace/root",
        openRelativePaths: ["README.md"],
        selectedRelativePath: "README.md",
        navigatorMode: .files,
        editorLayout: EditorLayoutRestoration(layout: EditorLayoutState())
    )
    let data = try JSONEncoder().encode(workspace)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("Saved records encode only inert allow-list fields")
func terminalGroupSavedRecordContainsNoLiveOrOSCFields() throws {
    let record = try terminalGroupRestorationRecord()
    let restoration = try TerminalGroupWorkspaceRestoration(openGroups: [record])
    let encoded = try JSONEncoder().encode(restoration)
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(json.contains("Explicit pane name"))
    for prohibitedKey in [
        "sessionID", "reportedTitle", "displayName", "provider", "model", "environment",
        "token", "credential", "TerminalProcessSpec", "pid", "pty", "output", "controller",
    ] {
        #expect(!json.contains(prohibitedKey), "Encoded record contained \(prohibitedKey)")
    }
}

@Test("Workspace restoration decodes old payloads with no Terminal Group field")
func oldRestorableWorkspacePayloadDecodes() throws {
    let json = try restorableWorkspaceJSON()
    #expect(json["terminalGroupRestoration"] == nil)
    let data = try JSONSerialization.data(withJSONObject: json)

    let decoded = try JSONDecoder().decode(RestorableWorkspace.self, from: data)

    #expect(decoded.rootPath == "/workspace/root")
    #expect(decoded.openRelativePaths == ["README.md"])
    #expect(decoded.terminalGroupRestoration == nil)
    #expect(decoded.terminalGroupRestorationDiagnostics == [.missingTerminalGroupField])
}

@Test("Malformed and unsupported Terminal Group fields preserve file workspace data")
func malformedAndUnsupportedTerminalGroupFieldsAreIsolated() throws {
    var malformed = try restorableWorkspaceJSON()
    malformed["terminalGroupRestoration"] = "not an object"
    let malformedDecoded = try JSONDecoder().decode(
        RestorableWorkspace.self,
        from: JSONSerialization.data(withJSONObject: malformed)
    )
    #expect(malformedDecoded.rootPath == "/workspace/root")
    #expect(malformedDecoded.editorLayout != nil)
    #expect(malformedDecoded.terminalGroupRestoration == nil)
    #expect(malformedDecoded.terminalGroupRestorationDiagnostics == [.malformedTerminalGroupField])

    var unsupported = try restorableWorkspaceJSON()
    unsupported["terminalGroupRestoration"] = ["schemaVersion": 99, "openGroups": []]
    let unsupportedDecoded = try JSONDecoder().decode(
        RestorableWorkspace.self,
        from: JSONSerialization.data(withJSONObject: unsupported)
    )
    #expect(unsupportedDecoded.rootPath == "/workspace/root")
    #expect(unsupportedDecoded.editorLayout != nil)
    #expect(unsupportedDecoded.terminalGroupRestoration == nil)
    #expect(
        unsupportedDecoded.terminalGroupRestorationDiagnostics
            == [.unsupportedTerminalGroupSchema(99)])
}

@Test("A bad Terminal Group sibling record does not discard valid inert records")
func malformedTerminalGroupSiblingIsDropped() throws {
    let record = try terminalGroupRestorationRecord()
    let restoration = try TerminalGroupWorkspaceRestoration(openGroups: [record])
    let restorationData = try JSONEncoder().encode(restoration)
    var restorationJSON = try #require(
        JSONSerialization.jsonObject(with: restorationData) as? [String: Any]
    )
    restorationJSON["openGroups"] = [
        try #require(restorationJSON["openGroups"] as? [[String: Any]]).first!,
        ["groupID": 42],
    ]

    var workspaceJSON = try restorableWorkspaceJSON()
    workspaceJSON["terminalGroupRestoration"] = restorationJSON
    let decoded = try JSONDecoder().decode(
        RestorableWorkspace.self,
        from: JSONSerialization.data(withJSONObject: workspaceJSON)
    )

    #expect(decoded.rootPath == "/workspace/root")
    #expect(decoded.terminalGroupRestoration?.openGroups == [record])
    #expect(
        decoded.terminalGroupRestorationDiagnostics == [.malformedTerminalGroupRecord])
}

@Test("Saved layout envelope rejects unsupported schemas and hides its workspace root")
func savedLayoutEnvelopeIsVersionedAndWorkspaceOpaque() throws {
    let root = URL(fileURLWithPath: "/private/workspace", isDirectory: true)
    let workspaceKey = TerminalGroupWorkspaceKey(standardizedRoot: root)
    let envelope = try TerminalGroupSavedLayoutEnvelope(workspaceKey: workspaceKey, groups: [:])
    let encoded = try JSONEncoder().encode(envelope)
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(!json.contains("/private/workspace"))
    #expect(json.contains("sha256:"))
    #expect(throws: TerminalGroupRestorationError.unsupportedSavedLayoutSchema(9)) {
        _ = try TerminalGroupSavedLayoutEnvelope(
            schemaVersion: 9,
            workspaceKey: workspaceKey,
            groups: [:]
        )
    }
}

@Test("Saved-layout writes and deletes return typed atomic IDs")
func savedLayoutStoreRequestsAndResultsRetainMutationIDs() throws {
    let workspaceKey = TerminalGroupWorkspaceKey(
        standardizedRoot: URL(fileURLWithPath: "/private/workspace", isDirectory: true)
    )
    let record = try savedTerminalGroupRecord()
    let firstSave = try TerminalGroupSavedLayoutSaveRequest(
        workspaceKey: workspaceKey,
        operation: .firstSave,
        group: record
    )
    let saveAs = try TerminalGroupSavedLayoutSaveRequest(
        workspaceKey: workspaceKey,
        operation: .saveAs,
        group: record
    )
    let save = try TerminalGroupSavedLayoutSaveRequest(
        workspaceKey: workspaceKey,
        operation: .save(existingID: record.id),
        group: record
    )
    let saveResult = TerminalGroupSavedLayoutSaveResult(
        savedLayoutID: record.id,
        disposition: .created
    )
    let deleteRequest = TerminalGroupSavedLayoutDeleteRequest(
        workspaceKey: workspaceKey,
        savedLayoutID: record.id
    )
    let deleteResult = TerminalGroupSavedLayoutDeleteResult(removedSavedLayoutID: record.id)

    #expect(firstSave.operation == .firstSave)
    #expect(saveAs.operation == .saveAs)
    #expect(save.operation == .save(existingID: record.id))
    #expect(saveResult.savedLayoutID == record.id)
    #expect(deleteRequest.savedLayoutID == record.id)
    #expect(deleteResult.removedSavedLayoutID == record.id)
    let mismatchedRecord = try savedTerminalGroupRecord()
    #expect(
        throws: TerminalGroupRestorationError.savedLayoutUpdateIDMismatch(
            expected: record.id,
            actual: mismatchedRecord.id
        )
    ) {
        _ = try TerminalGroupSavedLayoutSaveRequest(
            workspaceKey: workspaceKey,
            operation: .save(existingID: record.id),
            group: mismatchedRecord
        )
    }
}

@Test("Saved-layout envelopes cap reusable records at 32")
func savedLayoutEnvelopeUsesThirtyTwoRecordBound() throws {
    let workspaceKey = TerminalGroupWorkspaceKey(
        standardizedRoot: URL(fileURLWithPath: "/private/workspace", isDirectory: true)
    )
    var groups: [SavedTerminalGroupID: SavedTerminalGroupRecord] = [:]
    for _ in 0..<TerminalGroupSavedLayoutEnvelope.maximumSavedLayouts {
        let record = try savedTerminalGroupRecord()
        groups[record.id] = record
    }
    _ = try TerminalGroupSavedLayoutEnvelope(workspaceKey: workspaceKey, groups: groups)

    let overflow = try savedTerminalGroupRecord()
    groups[overflow.id] = overflow
    #expect(throws: TerminalGroupRestorationError.invalidSavedGroup) {
        _ = try TerminalGroupSavedLayoutEnvelope(workspaceKey: workspaceKey, groups: groups)
    }
}

@Test("Terminal Group restoration stops after a bounded malformed-record scan")
func terminalGroupRestorationBoundsMalformedRecordInspection() throws {
    let record = try terminalGroupRestorationRecord()
    let restoration = try TerminalGroupWorkspaceRestoration(openGroups: [record])
    let restorationData = try JSONEncoder().encode(restoration)
    var restorationJSON = try #require(
        JSONSerialization.jsonObject(with: restorationData) as? [String: Any]
    )
    let validRecord = try #require(
        (restorationJSON["openGroups"] as? [[String: Any]])?.first
    )
    var records = Array(
        repeating: ["groupID": 42] as [String: Any],
        count: TerminalGroupWorkspaceRestoration.maximumRecordsToInspect
    )
    records.append(validRecord)
    restorationJSON["openGroups"] = records

    var workspaceJSON = try restorableWorkspaceJSON()
    workspaceJSON["terminalGroupRestoration"] = restorationJSON
    let decoded = try JSONDecoder().decode(
        RestorableWorkspace.self,
        from: JSONSerialization.data(withJSONObject: workspaceJSON)
    )

    #expect(decoded.terminalGroupRestoration?.openGroups.isEmpty == true)
    #expect(
        decoded.terminalGroupRestoration?.diagnostics.count
            == TerminalGroupWorkspaceRestoration.maximumDiagnostics)
    #expect(
        decoded.terminalGroupRestoration?.diagnostics.allSatisfy {
            $0 == .malformedTerminalGroupRecord
        } == true)
}
