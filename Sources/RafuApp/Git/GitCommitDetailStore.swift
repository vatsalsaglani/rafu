import Foundation
import Observation

/// On-demand commit details for the History graph's hover card and the
/// expanded commit row. It is owned by `GitCommitGraphView` as `@State`, not
/// by `WorkspaceSession`, so a hover never invalidates session observers.
///
/// - Keyed by (repository root, commit ID); at most `capacity` finished
///   entries, least recently used evicted first.
/// - At most one in-flight load per key. `cancel` stops a load the pointer
///   left before it finished.
/// - Caches the GitHub repository page per (root, remote) — never the raw
///   remote URL, which can hold credentials.
///
/// Rows never read this store: only the one visible card and the expanded
/// row do, so a finished load does not re-render the list.
@Observable
@MainActor
final class GitCommitDetailStore {
    enum State: Equatable {
        case loading
        case loaded(GitCommitDetail)
        case failed
    }

    nonisolated struct Key: Hashable, Sendable {
        let rootPath: String
        let commitID: String
    }

    typealias DetailLoader = @Sendable (String, URL) async throws -> GitCommitDetail
    typealias RemoteLoader = @Sendable (String, URL) async throws -> String?

    static let capacity = 200

    private(set) var states: [Key: State] = [:]
    /// GitHub repository page per "root|remote"; `nil` value = resolved, no
    /// GitHub remote.
    private(set) var repositoryPages: [String: URL?] = [:]

    @ObservationIgnored private var recency: [Key] = []
    @ObservationIgnored private var tasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var remoteTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let loadDetail: DetailLoader
    @ObservationIgnored private let loadRemote: RemoteLoader

    init(
        loadDetail: @escaping DetailLoader = { id, root in
            try await GitService().commitDetail(id, at: root)
        },
        loadRemote: @escaping RemoteLoader = { name, root in
            try await GitService().remoteURL(name: name, at: root)
        }
    ) {
        self.loadDetail = loadDetail
        self.loadRemote = loadRemote
    }

    func state(for commitID: String, rootURL: URL) -> State? {
        states[Key(rootPath: rootURL.standardizedFileURL.path, commitID: commitID)]
    }

    /// Starts loading unless the entry is already loading or loaded.
    func load(_ commitID: String, rootURL: URL) {
        let key = Key(rootPath: rootURL.standardizedFileURL.path, commitID: commitID)
        switch states[key] {
        case .loading:
            return
        case .loaded:
            touch(key)
            return
        case .failed, nil:
            break
        }
        states[key] = .loading
        let loader = loadDetail
        tasks[key] = Task { [weak self] in
            let result: State
            do {
                result = .loaded(try await loader(commitID, rootURL))
            } catch {
                result = .failed
            }
            guard !Task.isCancelled else { return }
            self?.finish(key, with: result)
        }
    }

    /// Stops an unfinished load and forgets it. A finished entry stays cached.
    func cancel(_ commitID: String, rootURL: URL) {
        let key = Key(rootPath: rootURL.standardizedFileURL.path, commitID: commitID)
        guard states[key] == .loading else { return }
        tasks.removeValue(forKey: key)?.cancel()
        states.removeValue(forKey: key)
    }

    /// Awaits every load and remote lookup started so far. Tests use it
    /// instead of sleeping; the view never awaits it.
    func waitForPendingWork() async {
        let pending = Array(tasks.values) + Array(remoteTasks.values)
        for task in pending { await task.value }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        for task in remoteTasks.values { task.cancel() }
        tasks.removeAll()
        remoteTasks.removeAll()
        states = states.filter { $0.value != .loading }
    }

    /// The commit page on GitHub, once the remote is resolved; nil while it
    /// is unresolved or when the remote is not on GitHub.
    func gitHubCommitURL(for commitID: String, rootURL: URL, remote: String) -> URL? {
        guard let page = repositoryPages[remoteKey(rootURL, remote)] ?? nil else { return nil }
        return page.appending(path: "commit").appending(path: commitID)
    }

    /// Resolves the remote once per (root, remote) with one `git remote
    /// get-url` process.
    func resolveRemote(_ remote: String, rootURL: URL) {
        let key = remoteKey(rootURL, remote)
        guard repositoryPages[key] == nil, remoteTasks[key] == nil else { return }
        let loader = loadRemote
        remoteTasks[key] = Task { [weak self] in
            let raw = try? await loader(remote, rootURL)
            guard !Task.isCancelled else { return }
            // Keep only the derived page; the raw URL is dropped here.
            let page = raw.flatMap { GitHubRemoteURL.repositoryURL(remote: $0) }
            self?.repositoryPages[key] = .some(page)
            self?.remoteTasks[key] = nil
        }
    }

    private func remoteKey(_ rootURL: URL, _ remote: String) -> String {
        "\(rootURL.standardizedFileURL.path)|\(remote)"
    }

    private func finish(_ key: Key, with state: State) {
        tasks[key] = nil
        states[key] = state
        touch(key)
        evictIfNeeded()
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while recency.count > Self.capacity {
            let oldest = recency.removeFirst()
            states.removeValue(forKey: oldest)
        }
    }
}
