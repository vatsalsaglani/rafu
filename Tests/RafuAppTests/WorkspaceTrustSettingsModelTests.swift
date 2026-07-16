import Foundation
import Testing

@testable import RafuApp

/// Not `@MainActor`-annotated — every call into `WorkspaceTrustSettingsModel`
/// (a `@MainActor` type) below crosses the actor boundary via an explicit
/// `await`, matching `LanguageServersCatalogModelTests`'s convention so
/// these tests stay free of a `@MainActor` test function nesting the shared
/// (non-`@Sendable`-closure) `withTemporaryDirectory` helper.
private func waitUntil(
    timeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(5),
    _ predicate: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await predicate()
}

@Suite("Workspace trust settings model")
struct WorkspaceTrustSettingsModelTests {
    @Test("Loading flattens every workspace's approvals into sorted rows")
    func loadFlattensApprovalsIntoSortedRows() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            try await store.approve(serverID: "rust-analyzer", forWorkspaceKey: "/Users/a/zeta")
            try await store.approve(serverID: "clangd", forWorkspaceKey: "/Users/a/zeta")
            try await store.approve(serverID: "pyright", forWorkspaceKey: "/Users/a/alpha")

            let model = await WorkspaceTrustSettingsModel(store: store)
            await model.load()

            let rows = await model.rows
            #expect(rows.count == 3)
            // Sorted by display name first: "alpha" before "zeta".
            #expect(rows.map(\.workspaceDisplayName) == ["alpha", "zeta", "zeta"])
            // Within "zeta", sorted by server id: "clangd" before
            // "rust-analyzer".
            #expect(rows[1].serverID == "clangd")
            #expect(rows[2].serverID == "rust-analyzer")
        }
    }

    @Test("Loading twice does not duplicate rows")
    func loadingTwiceDoesNotDuplicate() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            try await store.approve(serverID: "clangd", forWorkspaceKey: "/Users/a/one")

            let model = await WorkspaceTrustSettingsModel(store: store)
            await model.load()
            await model.load()

            let rows = await model.rows
            #expect(rows.count == 1)
        }
    }

    @Test("Revoking a row removes it and persists through the store")
    func revokeRemovesRowAndPersists() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            try await store.approve(serverID: "clangd", forWorkspaceKey: "/Users/a/one")
            try await store.approve(serverID: "rust-analyzer", forWorkspaceKey: "/Users/a/one")

            let model = await WorkspaceTrustSettingsModel(store: store)
            await model.load()
            let loadedRows = await model.rows
            #expect(loadedRows.count == 2)

            let row = try #require(await model.rows.first { $0.serverID == "clangd" })
            await model.revoke(row)

            let landed = await waitUntil { model.rows.count == 1 }
            #expect(landed)
            let rows = await model.rows
            #expect(rows.first?.serverID == "rust-analyzer")
            #expect(
                try await store.isTrusted(serverID: "clangd", forWorkspaceKey: "/Users/a/one")
                    == false)
        }
    }

    @Test("An empty trust store loads to zero rows")
    func emptyStoreLoadsToZeroRows() async throws {
        try await withTemporaryDirectory { directory in
            let store = WorkspaceTrustStore(baseDirectory: directory)
            let model = await WorkspaceTrustSettingsModel(store: store)
            await model.load()
            let rows = await model.rows
            #expect(rows.isEmpty)
        }
    }

    @Test("rows(from:) flattens a TrustFile's approvals map")
    func rowsFromFlattensApprovalsMap() {
        let file = TrustFile(
            schemaVersion: WorkspaceTrustStore.currentSchemaVersion,
            approvals: ["/Users/a/one": ["clangd", "rust-analyzer"]]
        )
        let rows = WorkspaceTrustSettingsModel.rows(from: file)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.workspaceKey == "/Users/a/one" })
        #expect(rows.allSatisfy { $0.workspaceDisplayName == "one" })
        #expect(Set(rows.map(\.serverID)) == ["clangd", "rust-analyzer"])
    }
}
