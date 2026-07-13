import Foundation
import Testing

@testable import RafuApp

@Test("Search history is per-workspace, deduped, and most recent first")
func searchHistoryRecordsPerWorkspace() throws {
    let suiteName = "dev.rafu.tests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceSearchHistoryStore(suiteName: suiteName)

    store.record(query: "first", forRootPath: "/workspace/a")
    store.record(query: "second", forRootPath: "/workspace/a")
    store.record(query: "other", forRootPath: "/workspace/b")
    store.record(query: "first", forRootPath: "/workspace/a")

    #expect(store.queries(forRootPath: "/workspace/a") == ["first", "second"])
    #expect(store.queries(forRootPath: "/workspace/b") == ["other"])
    #expect(store.queries(forRootPath: "/workspace/unknown") == [])
}

@Test("Search history keeps at most 15 queries and ignores blank ones")
func searchHistoryEnforcesCapacity() throws {
    let suiteName = "dev.rafu.tests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceSearchHistoryStore(suiteName: suiteName)

    store.record(query: "   ", forRootPath: "/workspace")
    for index in 1...20 {
        store.record(query: "query-\(index)", forRootPath: "/workspace")
    }

    let queries = store.queries(forRootPath: "/workspace")
    #expect(queries.count == 15)
    #expect(queries.first == "query-20")
    #expect(queries.last == "query-6")
}

@Test("Search history trims whitespace before recording")
func searchHistoryTrimsQueries() throws {
    let suiteName = "dev.rafu.tests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceSearchHistoryStore(suiteName: suiteName)

    store.record(query: "  needle  ", forRootPath: "/workspace")
    store.record(query: "needle", forRootPath: "/workspace")

    #expect(store.queries(forRootPath: "/workspace") == ["needle"])
}
