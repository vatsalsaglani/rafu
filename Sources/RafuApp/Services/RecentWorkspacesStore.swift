import Foundation

nonisolated struct RecentWorkspaceEntry: Codable, Identifiable, Sendable {
    let bookmark: Data
    let rootPath: String
    let displayName: String
    let lastOpened: Date

    var id: String { rootPath }
}

/// Lightweight most-recently-opened workspace list backing the welcome screen.
/// Stores security-scoped bookmarks so reopening works under sandboxing.
nonisolated struct RecentWorkspacesStore: Sendable {
    private static let defaultsKey = "dev.rafu.recent-workspaces.v1"
    private static let capacity = 6

    func load() -> [RecentWorkspaceEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let entries = try? JSONDecoder().decode([RecentWorkspaceEntry].self, from: data)
        else { return [] }
        return entries
    }

    func record(url: URL, displayName: String) {
        guard
            let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        else { return }
        var entries = load().filter { $0.rootPath != url.path }
        entries.insert(
            RecentWorkspaceEntry(
                bookmark: bookmark,
                rootPath: url.path,
                displayName: displayName,
                lastOpened: Date()
            ),
            at: 0
        )
        save(Array(entries.prefix(Self.capacity)))
    }

    func remove(rootPath: String) {
        save(load().filter { $0.rootPath != rootPath })
    }

    func resolve(_ entry: RecentWorkspaceEntry) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: entry.bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func save(_ entries: [RecentWorkspaceEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
