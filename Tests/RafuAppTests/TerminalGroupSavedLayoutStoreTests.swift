import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Terminal Group saved-layout store")
struct TerminalGroupSavedLayoutStoreTests {
    @Test("Save, Save As, list, delete, and workspace isolation are atomic")
    func saveListDeleteAndWorkspaceIsolation() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(identity: .lightning, baseDirectory: base)
            let firstKey = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/one"))
            let secondKey = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/two"))
            let source = try record(name: "Layout")
            let first = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: firstKey, operation: .firstSave, group: source))
            #expect(first.disposition == .created)

            let saveAs = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: firstKey, operation: .saveAs,
                    group: try record(name: "Layout Copy")))
            #expect(saveAs.savedLayoutID != first.savedLayoutID)
            #expect(try await store.listSavedLayouts(for: firstKey).count == 2)
            #expect(try await store.listSavedLayouts(for: secondKey).isEmpty)

            let deleted = try await store.deleteSavedLayout(
                TerminalGroupSavedLayoutDeleteRequest(
                    workspaceKey: firstKey, savedLayoutID: first.savedLayoutID))
            #expect(deleted.removedSavedLayoutID == first.savedLayoutID)
            #expect(try await store.listSavedLayouts(for: firstKey).count == 1)
        }
    }

    @Test("Names are unique after case and diacritic normalization")
    func normalizedNameConflictsAreRejected() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "Café")))
            await #expect(throws: TerminalGroupPersistenceError.nameConflict.self) {
                try await store.saveSavedLayout(
                    TerminalGroupSavedLayoutSaveRequest(
                        workspaceKey: key, operation: .saveAs, group: try record(name: "CAFE")))
            }
        }
    }

    @Test("Corrupt data is preserved after a failed load")
    func corruptDataIsNotOverwritten() async throws {
        try await withTemporaryDirectory { base in
            let root = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "terminal-group-layouts.json")
            let corrupt = Data("not JSON".utf8)
            try corrupt.write(to: file)
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))

            await #expect(throws: TerminalGroupPersistenceError.corruptStoreFile.self) {
                _ = try await store.listSavedLayouts(for: key)
            }
            #expect(try Data(contentsOf: file) == corrupt)
        }
    }

    @Test("Release and Lightning use different Application Support files")
    func variantsUseSeparateStoreFiles() async throws {
        try await withTemporaryDirectory { base in
            let release = TerminalGroupSavedLayoutStore(identity: .release, baseDirectory: base)
            let lightning = TerminalGroupSavedLayoutStore(identity: .lightning, baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            _ = try await release.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "Release")))

            #expect(try await lightning.listSavedLayouts(for: key).isEmpty)
            #expect(
                FileManager.default.fileExists(
                    atPath: RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                        .appending(path: "terminal-group-layouts.json").path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: RafuAppIdentity.lightning.applicationSupportRoot(baseDirectory: base)
                        .appending(path: "terminal-group-layouts.json").path))
        }
    }

    @Test("Subscriptions register before list and advance once per successful mutation")
    func changesAreCurrentAndNotifyOnMutation() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            let stream = await store.changes(for: key)
            var iterator = stream.makeAsyncIterator()
            let initial = await iterator.next()
            #expect(initial?.revision == 0)
            #expect(try await store.listSavedLayouts(for: key).isEmpty)
            let first = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "Layout")))
            let change = await iterator.next()
            #expect(change?.revision == 1)
            let updated = try record(name: "Layout", id: first.savedLayoutID)
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .save(existingID: first.savedLayoutID),
                    group: updated))
            let update = await iterator.next()
            #expect(update?.revision == 2)
            _ = try await store.deleteSavedLayout(
                TerminalGroupSavedLayoutDeleteRequest(
                    workspaceKey: key, savedLayoutID: first.savedLayoutID))
            let delete = await iterator.next()
            #expect(delete?.revision == 3)
        }
    }

    @Test("Concurrent window clients preserve both named layouts")
    func concurrentClientsPreserveBothWrites() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            async let first: TerminalGroupSavedLayoutSaveResult = store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "One")))
            async let second: TerminalGroupSavedLayoutSaveResult = store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "Two")))
            _ = try await (first, second)
            #expect(
                try await store.listSavedLayouts(for: key).map(\.name.rawValue) == ["One", "Two"])
        }
    }

    @Test("Shared factory gives two window clients one authority")
    func sharedFactoryReturnsOneActorPerIdentityAndRoot() async throws {
        try await withTemporaryDirectory { base in
            let first = await TerminalGroupSavedLayoutStore.shared(
                identity: .lightning, baseDirectory: base)
            let second = await TerminalGroupSavedLayoutStore.shared(
                identity: .lightning, baseDirectory: base)
            let release = await TerminalGroupSavedLayoutStore.shared(
                identity: .release, baseDirectory: base)
            #expect(first === second)
            #expect(first !== release)
        }
    }

    @Test("Two subscribers receive each successful revision and newest-one buffering")
    func subscribersReceiveBoundedRevisions() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            let firstStream = await store.changes(for: key)
            let secondStream = await store.changes(for: key)
            var first = firstStream.makeAsyncIterator()
            var second = secondStream.makeAsyncIterator()
            let firstInitial = await first.next()
            let secondInitial = await second.next()
            #expect(firstInitial?.revision == 0)
            #expect(secondInitial?.revision == 0)
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "One")))
            let firstChange = await first.next()
            let secondChange = await second.next()
            #expect(firstChange?.revision == 1)
            #expect(secondChange?.revision == 1)

            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .saveAs, group: try record(name: "Two")))
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .saveAs, group: try record(name: "Three")))
            let newest = await first.next()
            #expect(newest?.revision == 3)
        }
    }

    @Test("Failed and cancelled mutations do not advance a workspace revision")
    func failedAndCancelledWritesDoNotNotify() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            let stream = await store.changes(for: key)
            var iterator = stream.makeAsyncIterator()
            let initial = await iterator.next()
            #expect(initial?.revision == 0)
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "Same")))
            let created = await iterator.next()
            #expect(created?.revision == 1)
            await #expect(throws: TerminalGroupPersistenceError.nameConflict.self) {
                try await store.saveSavedLayout(
                    TerminalGroupSavedLayoutSaveRequest(
                        workspaceKey: key, operation: .saveAs, group: try record(name: "same")))
            }
            let cancelled = Task {
                try await store.saveSavedLayout(
                    TerminalGroupSavedLayoutSaveRequest(
                        workspaceKey: key, operation: .saveAs, group: try record(name: "Cancelled"))
                )
            }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .saveAs, group: try record(name: "Success")))
            let success = await iterator.next()
            #expect(success?.revision == 2)
        }
    }

    @Test("The group count and encoded file limits reject writes without truncation")
    func countAndFileBoundsAreRejected() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            for index in 0..<TerminalGroupSavedLayoutEnvelope.maximumSavedLayouts {
                _ = try await store.saveSavedLayout(
                    TerminalGroupSavedLayoutSaveRequest(
                        workspaceKey: key, operation: .firstSave,
                        group: try record(name: "Layout \(index)")))
            }
            await #expect(throws: TerminalGroupPersistenceError.exceededBounds.self) {
                try await store.saveSavedLayout(
                    TerminalGroupSavedLayoutSaveRequest(
                        workspaceKey: key, operation: .firstSave,
                        group: try record(name: "Overflow")))
            }

            let root = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appending(path: "terminal-group-layouts.json")
            try Data(
                repeating: 0, count: TerminalGroupSavedLayoutStoreFile.maximumEncodedByteCount + 1
            )
            .write(to: file)
            let tooLarge = TerminalGroupSavedLayoutStore(baseDirectory: base)
            await #expect(throws: TerminalGroupPersistenceError.encodedFileTooLarge.self) {
                _ = try await tooLarge.listSavedLayouts(for: key)
            }
        }
    }

    @Test("Update retains its saved identity and stable listing is name ordered")
    func updateAndOrderAreStable() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            let first = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .firstSave, group: try record(name: "zulu")))
            let updated = try record(name: "zulu", id: first.savedLayoutID)
            let result = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .save(existingID: first.savedLayoutID),
                    group: updated))
            #expect(result.disposition == .updated)
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: key, operation: .saveAs, group: try record(name: "Alpha")))
            #expect(
                try await store.listSavedLayouts(for: key).map(\.name.rawValue) == [
                    "Alpha", "zulu",
                ])
        }
    }

    @Test("Restoring one open instance does not create a named library record")
    func openInstanceRestoreDoesNotCreateNamedLayout() async throws {
        try await withTemporaryDirectory { base in
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let paneID = TerminalPaneID()
            let record = try TerminalGroupOpenTabRestorationRecord(
                groupID: TerminalGroupID(), name: try #require(TerminalGroupName("Open")),
                root: .pane(paneID), focusedPaneID: paneID, savedLayoutID: SavedTerminalGroupID(),
                panes: [
                    try TerminalGroupOpenPaneRestorationRecord(
                        id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                        launchProfile: TerminalPaneLaunchProfile(
                            shell: .approvedShellPath("/bin/zsh"),
                            startingFolder: TerminalWorkspaceRelativePath(".")!))
                ])
            _ = try TerminalGroupRestorationCodec().restoreOpenInstance(record)
            #expect(try await store.listSavedLayouts(for: key).isEmpty)
        }
    }

    @Test("Deleting a final workspace record preserves another workspace")
    func finalDeletePreservesOtherWorkspace() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let firstKey = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/one"))
            let secondKey = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/two"))
            let first = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: firstKey, operation: .firstSave, group: try record(name: "One")))
            _ = try await store.saveSavedLayout(
                TerminalGroupSavedLayoutSaveRequest(
                    workspaceKey: secondKey, operation: .firstSave, group: try record(name: "Two")))
            _ = try await store.deleteSavedLayout(
                TerminalGroupSavedLayoutDeleteRequest(
                    workspaceKey: firstKey, savedLayoutID: first.savedLayoutID))
            #expect(try await store.listSavedLayouts(for: firstKey).isEmpty)
            #expect(
                try await store.listSavedLayouts(for: secondKey).map(\.name.rawValue) == ["Two"])
        }
    }

    @Test("An oversized encoded write leaves the last good file unchanged")
    func oversizedWritePreservesLastGoodFile() async throws {
        try await withTemporaryDirectory { base in
            let store = TerminalGroupSavedLayoutStore(baseDirectory: base)
            let key = TerminalGroupWorkspaceKey(standardizedRoot: URL(filePath: "/tmp/workspace"))
            let file = RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base)
                .appending(path: "terminal-group-layouts.json")
            var rejected = false
            for index in 0..<TerminalGroupSavedLayoutEnvelope.maximumSavedLayouts {
                let previous = (try? Data(contentsOf: file)) ?? Data()
                do {
                    _ = try await store.saveSavedLayout(
                        TerminalGroupSavedLayoutSaveRequest(
                            workspaceKey: key, operation: .firstSave,
                            group: try largeRecord(name: "Large \(index)")))
                } catch TerminalGroupPersistenceError.encodedFileTooLarge {
                    #expect(try Data(contentsOf: file) == previous)
                    rejected = true
                    break
                }
            }
            #expect(rejected)
        }
    }

    private func record(name: String, id: SavedTerminalGroupID = SavedTerminalGroupID()) throws
        -> SavedTerminalGroupRecord
    {
        let paneID = SavedTerminalPaneID()
        return try SavedTerminalGroupRecord(
            id: id, name: try #require(TerminalGroupName(name)),
            root: .pane(paneID),
            focusedPaneID: paneID,
            panes: [
                try SavedTerminalPaneRecord(
                    id: paneID, explicitUserName: TerminalPaneName("Pane"), themeColor: .accent,
                    kind: .ordinaryShell,
                    launchProfile: TerminalPaneLaunchProfile(
                        shell: .approvedShellPath("/bin/zsh"),
                        startingFolder: TerminalWorkspaceRelativePath(".")!))
            ])
    }

    private func largeRecord(name: String) throws -> SavedTerminalGroupRecord {
        let paneIDs = (0..<TerminalGroupSnapshot.maximumPanesPerGroup).map { _ in
            SavedTerminalPaneID()
        }
        var root: SavedTerminalGroupNode = .pane(paneIDs[0])
        for paneID in paneIDs.dropFirst() {
            root = .split(
                id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                first: root, second: .pane(paneID))
        }
        let path = TerminalWorkspaceRelativePath(String(repeating: "p", count: 1_024))!
        let panes = try paneIDs.map { paneID in
            try SavedTerminalPaneRecord(
                id: paneID,
                explicitUserName: TerminalPaneName(String(repeating: "n", count: 80)),
                themeColor: .accent, kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .approvedShellPath("/bin/zsh"), startingFolder: path))
        }
        return try SavedTerminalGroupRecord(
            id: SavedTerminalGroupID(), name: try #require(TerminalGroupName(name)), root: root,
            focusedPaneID: paneIDs[0], panes: panes)
    }
}
