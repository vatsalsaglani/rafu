import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

@MainActor
@Suite("Closed window save ordering repair")
struct WorkspaceCloseSaveOrderingRepairTests {
    @Test(
        "Quit drains a closed window's delayed bookmark on a separate store actor",
        .timeLimit(.minutes(1)))
    func closedWindowCannotOverwriteQuitState() async throws {
        let suite = "dev.rafu.close-order-repair.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let released = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let draining = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            entered.continuation.finish()
            released.continuation.finish()
            draining.continuation.finish()
        }
        let tracker = WorkspaceCloseSaveTracker { draining.continuation.yield(()) }
        let closedStore = WorkspaceRestorationStore(
            defaultsSuiteName: suite,
            bookmarkMaker: { _ in
                entered.continuation.yield(())
                var release = released.stream.makeAsyncIterator()
                guard await release.next() != nil else { throw CancellationError() }
                return Data([1])
            })
        let liveStore = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([2]) })
        let closed = session(name: "closed", store: closedStore, tracker: tracker)
        let key = session(name: "key", store: liveStore, tracker: tracker)
        defer {
            closed.descriptor = nil
            key.descriptor = nil
        }
        closed.teardownTerminalGroups()
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()

        let persistence = WorkspaceTerminationPersistence(closeSaveTracker: tracker)
        var replies = 0
        let quit = persistence.request(sessions: [key]) { replies += 1 }
        var drain = draining.stream.makeAsyncIterator()
        _ = await drain.next()
        #expect(replies == 0)
        released.continuation.yield(())
        await quit.value

        let saved = try #require(try await liveStore.load())
        #expect(saved.rootPath == key.rootURL?.path)
        #expect(saved.bookmark == Data([2]))
        #expect(replies == 1)
    }

    @Test(
        "Quit cancels a new close during the key save and releases its barrier after reply",
        .timeLimit(.minutes(1)))
    func lateCloseCannotEscapeFinalSave() async throws {
        let suite = "dev.rafu.close-order-repair.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let released = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            entered.continuation.finish()
            released.continuation.finish()
        }
        let tracker = WorkspaceCloseSaveTracker()
        let lateBookmarkCalls = Mutex(0)
        let closedStore = WorkspaceRestorationStore(
            defaultsSuiteName: suite,
            bookmarkMaker: { _ in
                lateBookmarkCalls.withLock { $0 += 1 }
                return Data([1])
            })
        let liveStore = WorkspaceRestorationStore(
            defaultsSuiteName: suite,
            bookmarkMaker: { _ in
                entered.continuation.yield(())
                var release = released.stream.makeAsyncIterator()
                guard await release.next() != nil else { throw CancellationError() }
                return Data([2])
            })
        let closed = session(name: "late-closed", store: closedStore, tracker: tracker)
        let key = session(name: "late-key", store: liveStore, tracker: tracker)
        defer {
            closed.descriptor = nil
            key.descriptor = nil
        }
        let persistence = WorkspaceTerminationPersistence(closeSaveTracker: tracker)
        var replies = 0
        let quit = persistence.request(sessions: [key]) { replies += 1 }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()
        closed.teardownTerminalGroups()
        #expect(replies == 0)
        released.continuation.yield(())
        await quit.value
        await tracker.drain()
        let saved = try #require(try await liveStore.load())
        #expect(saved.rootPath == key.rootURL?.path)
        #expect(saved.bookmark == Data([2]))
        #expect(lateBookmarkCalls.withLock { $0 } == 0)
        #expect(replies == 1)

        // The simulated reply returned without exiting. A later ordinary
        // close must be allowed to save, rather than leaving the barrier set.
        let later = session(name: "after-reply", store: closedStore, tracker: tracker)
        defer { later.descriptor = nil }
        later.teardownTerminalGroups()
        await tracker.drain()
        let afterReply = try #require(try await closedStore.load())
        #expect(afterReply.rootPath == later.rootURL?.path)
        #expect(lateBookmarkCalls.withLock { $0 } == 1)
    }

    @Test("A close registered during the final live save causes a final live rewrite")
    func completedCloseDuringFinalSaveIsNotMissed() async {
        let tracker = WorkspaceCloseSaveTracker()
        var finalSaveCalls = 0
        var closedSaveCalls = 0
        await tracker.drainBeforeFinalSave {
            finalSaveCalls += 1
            if finalSaveCalls == 1 {
                let close = Task { @MainActor in closedSaveCalls += 1 }
                tracker.track(close)
                // The task can complete and be removed before final-save
                // completion. Its registration must still cause a rewrite.
                await close.value
            }
        }
        #expect(closedSaveCalls == 1)
        #expect(finalSaveCalls == 2)
    }

    private func session(
        name: String, store: WorkspaceRestorationStore, tracker: WorkspaceCloseSaveTracker
    ) -> WorkspaceSession {
        let session = WorkspaceSession(restorationStore: store, closeSaveTracker: tracker)
        session.descriptor = WorkspaceDescriptor(
            displayName: name,
            location: .local(LocalWorkspaceReference(path: "/tmp/rafu-close-order-\(name)")))
        return session
    }
}
