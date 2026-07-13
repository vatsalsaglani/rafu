import Foundation

nonisolated struct RestorableWorkspace: Codable, Sendable {
    let bookmark: Data
    let rootPath: String
    let openRelativePaths: [String]
    let selectedRelativePath: String?
    let navigatorMode: WorkspaceNavigatorMode
    let editorLayout: EditorLayoutRestoration?
}

nonisolated struct WorkspaceRestorationStore: Sendable {
    private let defaultsKey = "dev.rafu.last-workspace.v1"

    @concurrent
    func save(_ workspace: RestorableWorkspace) async throws {
        let data = try JSONEncoder().encode(workspace)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    @concurrent
    func load() async throws -> RestorableWorkspace? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try JSONDecoder().decode(RestorableWorkspace.self, from: data)
    }

    @concurrent
    func clear() async {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    @concurrent
    func makeBookmark(for url: URL) async throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    @concurrent
    func resolve(_ bookmark: Data) async throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}
