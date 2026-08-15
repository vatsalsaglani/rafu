import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Terminal Group persistence security")
struct TerminalGroupPersistenceSecurityTests {
    @Test("Stored JSON contains only safe metadata and no root path")
    func encodedJSONExcludesRuntimeAndCapabilityData() async throws {
        try await withTemporaryDirectory { base in
            let root = URL(filePath: "/private/tmp/tg22-security-root")
            let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
            let store = TerminalGroupSavedLayoutStore(identity: .lightning, baseDirectory: base)
            let paneID = SavedTerminalPaneID()
            let secondPaneID = SavedTerminalPaneID()
            let profile = TerminalPaneLaunchProfile(
                shell: .approvedShellPath("/bin/zsh"),
                startingFolder: TerminalWorkspaceRelativePath("child")!)
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Safe")),
                root: .split(
                    id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                    first: .pane(paneID), second: .pane(secondPaneID)),
                focusedPaneID: paneID,
                panes: [
                    try SavedTerminalPaneRecord(
                        id: paneID, explicitUserName: TerminalPaneName("User name"),
                        themeColor: .info,
                        kind: .ordinaryShell,
                        launchProfile: profile),
                    try SavedTerminalPaneRecord(
                        id: secondPaneID, explicitUserName: nil, themeColor: nil,
                        kind: .ordinaryShell, launchProfile: profile),
                ])
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: record))

            let file = RafuAppIdentity.lightning.applicationSupportRoot(baseDirectory: base)
                .appending(path: "terminal-group-layouts.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let serialized = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
            let text = try #require(String(data: serialized, encoding: .utf8))
            #expect(
                collectedKeys(in: object) == [
                    "_0", "axis", "explicitUserName", "first", "focusedPaneID", "fraction",
                    "groups",
                    "id", "kind", "launchProfile", "name", "pane", "panes", "rawValue", "root",
                    "schemaVersion", "second", "shell", "split", "startingFolder", "themeColor",
                    "workspaceKey", "workspaces",
                ])
            let prohibited = [
                "session", "pid", "pty", "controller", "output", "scrollback", "transcript",
                "history",
                "executable", "argument", "argv", "process", "command", "environment", "token",
                "RAFU_ENSEMBLE_TOKEN", "credential", "secret", "reply", "provider", "model",
                "OSC title must not persist", root.path,
            ]
            #expect(prohibited.allSatisfy { !text.localizedCaseInsensitiveContains($0) })
            #expect(text.contains(key.rawValue))
            #expect(!text.contains(root.path))
        }
    }

    @Test("The codec drops session ids and OSC titles before JSON encoding")
    func codecDropsLiveFields() throws {
        let paneID = TerminalPaneID()
        let profile = TerminalPaneLaunchProfile(
            shell: .approvedShellPath("/bin/zsh"),
            startingFolder: TerminalWorkspaceRelativePath(".")!)
        let snapshot = try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Safe")),
            root: .pane(paneID),
            focusedPaneID: paneID, savedLayoutID: nil,
            panes: [
                try TerminalPaneSnapshot(
                    id: paneID, sessionID: UUID(), explicitUserName: nil,
                    reportedTitle: TerminalReportedTitle("private OSC title"),
                    runtimeKind: .ordinaryShell,
                    themeColor: nil, status: .live, launchProfile: profile,
                    startAvailability: .available)
            ], retainedPaneCount: 1)
        let data = try JSONEncoder().encode(
            TerminalGroupRestorationCodec().savedRecord(from: snapshot))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("private OSC title"))
        #expect(!text.localizedCaseInsensitiveContains("session"))
    }

    @Test("Workspace digests are deterministic and do not retain the source root")
    func workspaceDigestIsDeterministicAndOpaque() {
        let direct = TerminalGroupWorkspaceKey(
            standardizedRoot: URL(filePath: "/private/tmp/tg22-digest"))
        let normalized = TerminalGroupWorkspaceKey(
            standardizedRoot: URL(filePath: "/private/tmp/../tmp/tg22-digest"))
        #expect(direct == normalized)
        #expect(direct.rawValue.hasPrefix("sha256:"))
        #expect(!direct.rawValue.contains("tg22-digest"))
    }

    @Test("Text and path bounds reject rather than truncate persisted input")
    func textAndPathBoundsRejectInputs() {
        #expect(TerminalGroupName(String(repeating: "a", count: 81)) == nil)
        #expect(TerminalPaneName(String(repeating: "a", count: 81)) == nil)
        #expect(TerminalWorkspaceRelativePath(String(repeating: "a", count: 1_025)) == nil)
        #expect(TerminalWorkspaceRelativePath("../outside") == nil)
    }

    @Test("Malformed safe-record fields keep their typed validation results")
    func malformedRecordsKeepTypedErrors() async throws {
        try await assertTypedLoadError(
            changing: "kind", to: "futurePane", expected: .unknownSavedPaneKind)
        try await assertTypedLoadError(
            changing: "startingFolder", to: "../escape", expected: .invalidRelativePath)
        try await assertTypedLoadError(
            changing: "focusedPaneID", to: ["rawValue": UUID().uuidString],
            expected: .missingFocusedPane)
        try await assertTypedLoadError(
            changing: "name", to: String(repeating: "a", count: 81), expected: .exceededBounds)
        try await assertTypedLoadError(
            changing: "name", to: "   ", expected: .invalidTree)
        try await assertTypedLoadError(
            changing: "startingFolder", to: String(repeating: "a", count: 1_025),
            expected: .exceededBounds)
        try await assertTypedLoadError(
            changing: "startingFolder", to: NSNull(), expected: .missingStartingFolder)
        try await assertTypedLoadError(
            changing: "shell", to: NSNull(), expected: .missingShellProfile)
        try await assertTypedLoadError(
            changing: "shell", to: "relative-shell", expected: .unapprovedShellProfile)
        try await assertTypedLoadError(
            changing: "launchProfile", to: NSNull(), expected: .missingShellProfile)
        try await assertTypedLoadError(
            changing: "root", to: NSNull(), expected: .invalidTree)
        try await assertTypedLoadError(
            changing: "schemaVersion", to: 0, expected: .unsupportedSchema(0))
    }

    private func assertTypedLoadError(
        changing keyToChange: String,
        to replacement: Any,
        expected: TerminalGroupPersistenceError
    ) async throws {
        try await withTemporaryDirectory { base in
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/tg22-typed"))
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let paneID = SavedTerminalPaneID()
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Safe")),
                root: .pane(paneID), focusedPaneID: paneID,
                panes: [
                    try SavedTerminalPaneRecord(
                        id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                        launchProfile: TerminalPaneLaunchProfile(
                            shell: .approvedShellPath("/bin/zsh"),
                            startingFolder: TerminalWorkspaceRelativePath("child")!))
                ])
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: record))
            let file = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                .appending(path: "terminal-group-layouts.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let replacement = replaceFirstValue(
                for: keyToChange, in: object, with: replacement)
            try JSONSerialization.data(withJSONObject: replacement.value, options: [.sortedKeys])
                .write(to: file)

            do {
                _ = try await store.listSavedLayouts(for: key)
                Issue.record("Expected typed saved-layout validation failure")
            } catch let error as TerminalGroupPersistenceError {
                #expect(error == expected)
            }
        }
    }

    @Test("Raw split fraction and axis errors retain their typed results")
    func rawSplitErrorsStayTyped() async throws {
        try await assertTypedSplitLoadError(
            changing: "fraction", to: 0.99, expected: .invalidFraction)
        try await assertTypedSplitLoadError(
            changing: "axis", to: "diagonal", expected: .invalidTree)
    }

    @Test("Raw pane-count and missing-profile errors retain typed results")
    func rawCountAndMissingProfileStayTyped() async throws {
        try await assertTypedLoadError(
            changing: "panes", to: Array(repeating: NSNull(), count: 7), expected: .exceededBounds)
        try await assertMissingProfileKeyError()
    }

    @Test("Raw duplicate identities and group map mismatch retain typed results")
    func rawDuplicateAndMapIdentityErrorsStayTyped() async throws {
        try await assertRawMutationLoadError(expected: .duplicateID) { object in
            let result = appendDuplicateFirstArrayElement(for: "panes", in: object)
            try #require(result.changed)
            return result.value
        }
        try await assertRawMutationLoadError(expected: .duplicateID) { object in
            let root = try #require(firstValue(for: "root", in: object))
            let duplicated = duplicateNestedSplitID(in: root)
            try #require(duplicated.changed)
            let replaced = replaceFirstValue(for: "root", in: object, with: duplicated.value)
            try #require(replaced.replaced)
            return replaced.value
        }
        try await assertRawMutationLoadError(expected: .duplicateID) { object in
            let result = appendDuplicateGroupMapEntry(in: object)
            try #require(result.changed)
            return result.value
        }
        try await assertRawMutationLoadError(expected: .invalidTree) { object in
            let result = replaceFirstGroupMapKey(in: object, with: UUID().uuidString)
            try #require(result.changed)
            return result.value
        }
    }

    @Test("The current schema file loads successfully")
    func currentSchemaLoads() async throws {
        try await withTemporaryDirectory { base in
            let key = TerminalGroupWorkspaceKey(
                standardizedRoot: URL(filePath: "/tmp/tg22-current"))
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let paneID = SavedTerminalPaneID()
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Current")),
                root: .pane(paneID), focusedPaneID: paneID,
                panes: [
                    try SavedTerminalPaneRecord(
                        id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                        launchProfile: TerminalPaneLaunchProfile(
                            shell: .approvedShellPath("/bin/zsh"),
                            startingFolder: TerminalWorkspaceRelativePath(".")!))
                ])
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: record))
            #expect(try await store.listSavedLayouts(for: key).count == 1)
        }
    }

    private func assertMissingProfileKeyError() async throws {
        try await withTemporaryDirectory { base in
            let key = TerminalGroupWorkspaceKey(
                standardizedRoot: URL(filePath: "/tmp/tg22-profile"))
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let paneID = SavedTerminalPaneID()
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Profile")),
                root: .pane(paneID), focusedPaneID: paneID,
                panes: [
                    try SavedTerminalPaneRecord(
                        id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                        launchProfile: TerminalPaneLaunchProfile(
                            shell: .approvedShellPath("/bin/zsh"),
                            startingFolder: TerminalWorkspaceRelativePath(".")!))
                ])
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: record))
            let file = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                .appending(path: "terminal-group-layouts.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let removed = removeFirstKey("launchProfile", from: object)
            try JSONSerialization.data(withJSONObject: removed.value, options: [.sortedKeys]).write(
                to: file)
            do {
                _ = try await store.listSavedLayouts(for: key)
                Issue.record("Expected missing profile validation failure")
            } catch let error as TerminalGroupPersistenceError {
                #expect(error == .missingShellProfile)
            }
        }
    }

    private func assertTypedSplitLoadError(
        changing keyToChange: String, to replacement: Any, expected: TerminalGroupPersistenceError
    ) async throws {
        try await withTemporaryDirectory { base in
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/tg22-split"))
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let first = SavedTerminalPaneID()
            let second = SavedTerminalPaneID()
            let profile = TerminalPaneLaunchProfile(
                shell: .approvedShellPath("/bin/zsh"),
                startingFolder: TerminalWorkspaceRelativePath("child")!)
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Split")),
                root: .split(
                    id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                    first: .pane(first), second: .pane(second)), focusedPaneID: first,
                panes: [
                    try SavedTerminalPaneRecord(
                        id: first, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                        launchProfile: profile),
                    try SavedTerminalPaneRecord(
                        id: second, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                        launchProfile: profile),
                ])
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: record))
            let file = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                .appending(path: "terminal-group-layouts.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let altered = replaceFirstValue(for: keyToChange, in: object, with: replacement)
            try JSONSerialization.data(withJSONObject: altered.value, options: [.sortedKeys]).write(
                to: file)
            do {
                _ = try await store.listSavedLayouts(for: key)
                Issue.record("Expected typed split validation failure")
            } catch let error as TerminalGroupPersistenceError {
                #expect(error == expected)
            }
        }
    }

    private func assertRawMutationLoadError(
        expected: TerminalGroupPersistenceError,
        mutate: (Any) throws -> Any
    ) async throws {
        try await withTemporaryDirectory { base in
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/tg22-raw"))
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let record = try splitRecord()
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: record))
            let file = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                .appending(path: "terminal-group-layouts.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            let mutated = try mutate(object)
            try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys]).write(
                to: file)
            do {
                _ = try await store.listSavedLayouts(for: key)
                Issue.record("Expected typed raw saved-layout validation failure")
            } catch let error as TerminalGroupPersistenceError {
                #expect(error == expected)
            }
        }
    }

    private func splitRecord() throws -> SavedTerminalGroupRecord {
        let first = SavedTerminalPaneID()
        let second = SavedTerminalPaneID()
        let third = SavedTerminalPaneID()
        let profile = TerminalPaneLaunchProfile(
            shell: .approvedShellPath("/bin/zsh"),
            startingFolder: TerminalWorkspaceRelativePath("child")!)
        return try SavedTerminalGroupRecord(
            id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Raw split")),
            root: .split(
                id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                first: .pane(first),
                second: .split(
                    id: SavedTerminalGroupSplitID(), axis: .rows, fraction: 0.5,
                    first: .pane(second), second: .pane(third))),
            focusedPaneID: first,
            panes: [
                try SavedTerminalPaneRecord(
                    id: first, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                    launchProfile: profile),
                try SavedTerminalPaneRecord(
                    id: second, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                    launchProfile: profile),
                try SavedTerminalPaneRecord(
                    id: third, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                    launchProfile: profile),
            ])
    }

    private func collectedKeys(in object: Any) -> Set<String> {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: Set<String>()) { result, entry in
                if !entry.key.hasPrefix("sha256:") { result.insert(entry.key) }
                result.formUnion(collectedKeys(in: entry.value))
            }
        }
        if let array = object as? [Any] {
            return array.reduce(into: Set<String>()) { result, entry in
                result.formUnion(collectedKeys(in: entry))
            }
        }
        return []
    }

    private func replaceFirstValue(
        for key: String, in object: Any, with replacement: Any
    ) -> (value: Any, replaced: Bool) {
        if var dictionary = object as? [String: Any] {
            if dictionary[key] != nil {
                dictionary[key] = replacement
                return (dictionary, true)
            }
            for (nestedKey, nestedValue) in dictionary {
                let result = replaceFirstValue(for: key, in: nestedValue, with: replacement)
                if result.replaced {
                    dictionary[nestedKey] = result.value
                    return (dictionary, true)
                }
            }
            return (dictionary, false)
        }
        if var array = object as? [Any] {
            for index in array.indices {
                let result = replaceFirstValue(for: key, in: array[index], with: replacement)
                if result.replaced {
                    array[index] = result.value
                    return (array, true)
                }
            }
            return (array, false)
        }
        return (object, false)
    }

    private func removeFirstKey(_ key: String, from object: Any) -> (value: Any, removed: Bool) {
        if var dictionary = object as? [String: Any] {
            if dictionary.removeValue(forKey: key) != nil { return (dictionary, true) }
            for (nestedKey, nestedValue) in dictionary {
                let result = removeFirstKey(key, from: nestedValue)
                if result.removed {
                    dictionary[nestedKey] = result.value
                    return (dictionary, true)
                }
            }
            return (dictionary, false)
        }
        if var array = object as? [Any] {
            for index in array.indices {
                let result = removeFirstKey(key, from: array[index])
                if result.removed {
                    array[index] = result.value
                    return (array, true)
                }
            }
            return (array, false)
        }
        return (object, false)
    }

    private func firstValue(for key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] { return value }
            for value in dictionary.values {
                if let found = firstValue(for: key, in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = firstValue(for: key, in: value) { return found }
            }
        }
        return nil
    }

    private func appendDuplicateFirstArrayElement(
        for key: String, in object: Any
    ) -> (value: Any, changed: Bool) {
        if var dictionary = object as? [String: Any] {
            if var entries = dictionary[key] as? [Any], let first = entries.first {
                entries.append(first)
                dictionary[key] = entries
                return (dictionary, true)
            }
            for (nestedKey, nestedValue) in dictionary {
                let result = appendDuplicateFirstArrayElement(for: key, in: nestedValue)
                if result.changed {
                    dictionary[nestedKey] = result.value
                    return (dictionary, true)
                }
            }
            return (dictionary, false)
        }
        if var array = object as? [Any] {
            for index in array.indices {
                let result = appendDuplicateFirstArrayElement(for: key, in: array[index])
                if result.changed {
                    array[index] = result.value
                    return (array, true)
                }
            }
            return (array, false)
        }
        return (object, false)
    }

    private func duplicateNestedSplitID(in node: Any) -> (value: Any, changed: Bool) {
        guard var node = node as? [String: Any], let rawSplit = node["split"] as? [String: Any]
        else { return (node, false) }
        var payload = rawSplit["_0"] as? [String: Any] ?? rawSplit
        guard let firstID = payload["id"] else { return (node, false) }
        for childKey in ["first", "second"] {
            let child = duplicateNestedSplitID(in: payload[childKey] as Any)
            if child.changed {
                payload[childKey] = child.value
                if rawSplit["_0"] != nil {
                    var wrapped = rawSplit
                    wrapped["_0"] = payload
                    node["split"] = wrapped
                } else {
                    node["split"] = payload
                }
                return (node, true)
            }
        }
        if var nestedSplit = payload["second"] as? [String: Any],
            var nestedPayload = nestedSplit["split"]
                as? [String: Any]
        {
            if nestedPayload["_0"] != nil,
                var wrappedPayload = nestedPayload["_0"] as? [String: Any]
            {
                wrappedPayload["id"] = firstID
                nestedPayload["_0"] = wrappedPayload
            } else {
                nestedPayload["id"] = firstID
            }
            nestedSplit["split"] = nestedPayload
            payload["second"] = nestedSplit
            if rawSplit["_0"] != nil {
                var wrapped = rawSplit
                wrapped["_0"] = payload
                node["split"] = wrapped
            } else {
                node["split"] = payload
            }
            return (node, true)
        }
        return (node, false)
    }

    private func appendDuplicateGroupMapEntry(in object: Any) -> (value: Any, changed: Bool) {
        if var dictionary = object as? [String: Any] {
            if var groups = dictionary["groups"] as? [Any], groups.count >= 2 {
                groups.append(groups[0])
                groups.append(groups[1])
                dictionary["groups"] = groups
                return (dictionary, true)
            }
            for (key, value) in dictionary {
                let result = appendDuplicateGroupMapEntry(in: value)
                if result.changed {
                    dictionary[key] = result.value
                    return (dictionary, true)
                }
            }
            return (dictionary, false)
        }
        if var array = object as? [Any] {
            for index in array.indices {
                let result = appendDuplicateGroupMapEntry(in: array[index])
                if result.changed {
                    array[index] = result.value
                    return (array, true)
                }
            }
            return (array, false)
        }
        return (object, false)
    }

    private func replaceFirstGroupMapKey(
        in object: Any, with replacement: String
    ) -> (value: Any, changed: Bool) {
        if var dictionary = object as? [String: Any] {
            if var groups = dictionary["groups"] as? [Any], !groups.isEmpty {
                groups[0] = ["rawValue": replacement]
                dictionary["groups"] = groups
                return (dictionary, true)
            }
            for (key, value) in dictionary {
                let result = replaceFirstGroupMapKey(in: value, with: replacement)
                if result.changed {
                    dictionary[key] = result.value
                    return (dictionary, true)
                }
            }
            return (dictionary, false)
        }
        if var array = object as? [Any] {
            for index in array.indices {
                let result = replaceFirstGroupMapKey(in: array[index], with: replacement)
                if result.changed {
                    array[index] = result.value
                    return (array, true)
                }
            }
            return (array, false)
        }
        return (object, false)
    }
}
