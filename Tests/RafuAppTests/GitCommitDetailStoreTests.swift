import Foundation
import Testing

@testable import RafuApp

/// Counts loader calls across the store's tasks.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
@Suite("Commit detail store")
struct GitCommitDetailStoreTests {
    private let root = URL(fileURLWithPath: "/tmp/rafu-detail-store", isDirectory: true)

    nonisolated private static func echo(_ id: String) -> GitCommitDetail {
        GitCommitDetail(body: id, filesChanged: 0, insertions: 0, deletions: 0)
    }

    @Test("A load runs once per commit and caches the result")
    func loadsOncePerCommit() async {
        let counter = CallCounter()
        let store = GitCommitDetailStore(
            loadDetail: { id, _ in
                await counter.increment()
                return Self.echo(id)
            },
            loadRemote: { _, _ in nil })
        store.load("abc1234", rootURL: root)
        store.load("abc1234", rootURL: root)
        #expect(store.state(for: "abc1234", rootURL: root) == .loading)
        await store.waitForPendingWork()
        store.load("abc1234", rootURL: root)
        #expect(store.state(for: "abc1234", rootURL: root) == .loaded(Self.echo("abc1234")))
        #expect(await counter.count == 1)
    }

    @Test("Cancelling an unfinished load forgets it; a failure is recorded")
    func cancelAndFailure() async {
        let store = GitCommitDetailStore(
            loadDetail: { id, _ in
                if id == "bad0000" { throw GitServiceError.invalidRevision(id) }
                try await Task.sleep(for: .seconds(30))
                return Self.echo(id)
            },
            loadRemote: { _, _ in nil })
        store.load("slow000", rootURL: root)
        store.cancel("slow000", rootURL: root)
        #expect(store.state(for: "slow000", rootURL: root) == nil)

        store.load("bad0000", rootURL: root)
        await store.waitForPendingWork()
        #expect(store.state(for: "bad0000", rootURL: root) == .failed)
    }

    @Test("Finished entries beyond the capacity evict the least recently used")
    func evictsLeastRecentlyUsed() async {
        let store = GitCommitDetailStore(
            loadDetail: { id, _ in Self.echo(id) },
            loadRemote: { _, _ in nil })
        let ids = (0...GitCommitDetailStore.capacity).map { "commit\($0)" }
        for id in ids {
            store.load(id, rootURL: root)
            await store.waitForPendingWork()
        }
        #expect(store.state(for: ids[0], rootURL: root) == nil)
        #expect(store.state(for: ids[1], rootURL: root) != nil)
        #expect(store.state(for: ids[ids.count - 1], rootURL: root) != nil)
    }

    @Test("The GitHub page is derived once per remote and the raw URL is not kept")
    func resolvesGitHubPage() async {
        let counter = CallCounter()
        let store = GitCommitDetailStore(
            loadDetail: { id, _ in Self.echo(id) },
            loadRemote: { _, _ in
                await counter.increment()
                return "https://user:token@github.com/octo/rafu.git"
            })
        #expect(store.gitHubCommitURL(for: "8be02b5f", rootURL: root, remote: "origin") == nil)
        store.resolveRemote("origin", rootURL: root)
        store.resolveRemote("origin", rootURL: root)
        await store.waitForPendingWork()
        store.resolveRemote("origin", rootURL: root)
        let url = store.gitHubCommitURL(for: "8be02b5f", rootURL: root, remote: "origin")
        #expect(url?.absoluteString == "https://github.com/octo/rafu/commit/8be02b5f")
        #expect(
            !store.repositoryPages.values.contains { $0?.absoluteString.contains("token") == true })
        #expect(await counter.count == 1)
    }
}
