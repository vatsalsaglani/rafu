import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Workspace quit restoration repair")
struct WorkspaceTerminationPersistenceRepairTests {
    @Test("Quit waits for both metadata saves and saves the key workspace last")
    func keyWorkspaceSavedLast() async throws {
        let suite = "dev.rafu.quit-repair.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        let key = session(name: "key", store: store)
        let other = session(name: "other", store: store)
        defer {
            key.descriptor = nil
            other.descriptor = nil
        }
        key.navigatorMode = .search
        other.navigatorMode = .sourceControl
        let persistence = WorkspaceTerminationPersistence()
        var replies = 0
        let save = persistence.request(sessions: [key, other]) { replies += 1 }
        #expect(replies == 0)
        await save.value
        let saved = try #require(try await store.load())
        #expect(saved.rootPath == key.rootURL?.path)
        #expect(saved.navigatorMode == .search)
        #expect(replies == 1)
    }

    @Test("A duplicate pending quit request does not send a second reply")
    func duplicateRequestHasOneReply() async {
        let persistence = WorkspaceTerminationPersistence()
        var firstReplies = 0
        var duplicateReplies = 0
        let first = persistence.request(sessions: []) { firstReplies += 1 }
        let duplicate = persistence.request(sessions: []) { duplicateReplies += 1 }
        await first.value
        await duplicate.value
        #expect(firstReplies == 1)
        #expect(duplicateReplies == 0)

        // A later request can start a new cycle if AppKit did not quit.
        let next = persistence.request(sessions: []) { firstReplies += 1 }
        await next.value
        #expect(firstReplies == 2)
    }

    @Test("Quit metadata save preserves dirty text and existing close confirmation state")
    func dirtyStateIsNotChangedByFlush() async {
        let suite = "dev.rafu.quit-repair.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        let workspace = session(name: "dirty", store: store)
        defer { workspace.descriptor = nil }
        let document = EditorDocument(untitledNumber: 1)
        document.isDirty = true
        document.pendingDirtyText = "unsaved text"
        var fileSaveCalls = 0
        document.saveAction = { fileSaveCalls += 1 }
        workspace.openDocuments = [document]
        workspace.pendingCloseDocument = document
        workspace.isQuitConfirmationPresented = true
        let persistence = WorkspaceTerminationPersistence()
        let save = persistence.request(sessions: [workspace]) {}
        await save.value
        #expect(workspace.openDocuments.first === document)
        #expect(workspace.pendingCloseDocument === document)
        #expect(workspace.isQuitConfirmationPresented)
        #expect(document.isDirty)
        #expect(document.pendingDirtyText == "unsaved text")
        #expect(document.isUntitled)
        #expect(fileSaveCalls == 0)
        #expect(workspace.terminal.sessions.isEmpty)
    }

    private func session(name: String, store: WorkspaceRestorationStore) -> WorkspaceSession {
        let session = WorkspaceSession(restorationStore: store)
        session.descriptor = WorkspaceDescriptor(
            displayName: name,
            location: .local(LocalWorkspaceReference(path: "/tmp/rafu-quit-repair-\(name)")))
        return session
    }
}
