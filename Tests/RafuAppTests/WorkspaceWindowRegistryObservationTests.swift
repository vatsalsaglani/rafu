import AppKit
import Observation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

@MainActor
struct WorkspaceWindowRegistryObservationTests {
    @Test func liveSnapshotReadsDoNotPublishRegistryChanges() {
        let registry = WorkspaceWindowRegistry()
        let session = rootedSession()
        let window = makeWindow()
        registry.register(session: session, window: window, rootURL: { nil })
        let changed = Mutex(false)
        withObservationTracking {
            _ = registry.entries
        } onChange: {
            changed.withLock { $0 = true }
        }
        #expect(registry.sessionSnapshots().count == 1)
        #expect(registry.snapshots().count == 1)
        #expect(registry.liveWorkspaceWindowCount() == 1)
        #expect(!changed.withLock { $0 })
        withExtendedLifetime(window) {}
    }

    @Test func snapshotReadsFilterDeadWindowsWithoutPruningObservableEntries() throws {
        let registry = WorkspaceWindowRegistry()
        let session = rootedSession()
        weak var expired: NSWindow?
        autoreleasepool {
            let window = makeWindow()
            expired = window
            registry.register(session: session, window: window, rootURL: { nil })
        }
        try #require(expired == nil)
        #expect(registry.entries.count == 1)
        let changed = Mutex(false)
        withObservationTracking {
            _ = registry.entries
        } onChange: {
            changed.withLock { $0 = true }
        }
        #expect(registry.sessionSnapshots().isEmpty)
        #expect(registry.snapshots().isEmpty)
        #expect(registry.liveWorkspaceWindowCount() == 0)
        #expect(registry.entries.count == 1)
        #expect(!changed.withLock { $0 })
        registry.pruneDeadEntries()
        #expect(registry.entries.isEmpty)
        #expect(changed.withLock { $0 })
    }

    @Test func lifecyclePruningDoesNotPublishWhenNothingIsDead() {
        let registry = WorkspaceWindowRegistry()
        let changed = Mutex(false)
        withObservationTracking {
            _ = registry.entries
        } onChange: {
            changed.withLock { $0 = true }
        }
        registry.pruneDeadEntries()
        #expect(!changed.withLock { $0 })
    }

    private func rootedSession() -> WorkspaceSession {
        let session = WorkspaceSession()
        session.descriptor = WorkspaceDescriptor(
            displayName: "Snapshot test",
            location: .local(LocalWorkspaceReference(path: "/tmp/rafu-snapshot-test")))
        return session
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
    }
}
