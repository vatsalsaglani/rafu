import Foundation
import Testing

@testable import RafuApp

@Test("Expanded directories refresh when FSEvents reports their parent")
func refreshScopeIncludesMaterializedDirectChild() {
    let refreshed = WorkspaceFileTreeRefreshScope.materializedDirectories(
        affectedBy: [""],
        among: ["", ".rafu", ".rafu/agents"]
    )

    #expect(refreshed == ["", ".rafu"])
}

@Test("File-tree refresh scope does not materialize collapsed directories")
func refreshScopeDoesNotPreloadUnmaterializedDirectories() {
    let refreshed = WorkspaceFileTreeRefreshScope.materializedDirectories(
        affectedBy: [""],
        among: [""]
    )

    #expect(refreshed == [""])
}

@Test("A refreshed .rafu listing includes a new runs directory")
func refreshedRafuListingIncludesRuns() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let rafu = root.appending(path: ".rafu", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rafu, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: rafu.appending(path: "agents", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )

    let service = WorkspaceFileService()
    #expect(
        try await service.listDirectory(rootURL: root, relativeDirectoryPath: ".rafu").map(\.name)
            == ["agents"]
    )

    try FileManager.default.createDirectory(
        at: rafu.appending(path: "runs", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )

    #expect(
        try await service.listDirectory(rootURL: root, relativeDirectoryPath: ".rafu").map(\.name)
            == ["agents", "runs"]
    )
}
