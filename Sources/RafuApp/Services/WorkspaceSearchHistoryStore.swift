import Foundation

/// Per-workspace list of recent search queries, most recent first.
/// Modeled on `RecentWorkspacesStore`: a small JSON blob in `UserDefaults`
/// keyed by workspace root path. Queries only — never document text.
nonisolated struct WorkspaceSearchHistoryStore: Sendable {
    private static let defaultsKey = "dev.rafu.search-history.v1"
    private static let capacity = 15

    /// `nil` uses the standard defaults; tests inject a suite they clean up.
    /// The suite name (not the `UserDefaults` instance, which is not
    /// `Sendable`) is stored so the struct conforms honestly.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func queries(forRootPath rootPath: String) -> [String] {
        loadAll()[rootPath] ?? []
    }

    func record(query: String, forRootPath rootPath: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = loadAll()
        var queries = all[rootPath] ?? []
        queries.removeAll { $0 == trimmed }
        queries.insert(trimmed, at: 0)
        all[rootPath] = Array(queries.prefix(Self.capacity))
        save(all)
    }

    private func loadAll() -> [String: [String]] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
            let entries = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return entries
    }

    private func save(_ entries: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
