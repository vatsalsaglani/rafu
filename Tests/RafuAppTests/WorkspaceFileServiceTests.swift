import Foundation
import Testing

@testable import RafuApp

@Test("Workspace tree sorts folders first and excludes generated directories")
func workspaceTreeIsBoundedAndSorted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("hello".utf8).write(to: root.appending(path: "z.txt"))
    try FileManager.default.createDirectory(
        at: root.appending(path: "A"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appending(path: ".build"), withIntermediateDirectories: true)

    let tree = try await WorkspaceFileService().tree(rootURL: root)

    #expect(tree.map(\.name) == ["A", "z.txt"])
}

@Test("Workspace service atomically writes and reads UTF-8 text")
func workspaceReadWriteRoundTrip() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let service = WorkspaceFileService()

    try await service.writeText("રફૂ\n", to: url)

    #expect(try await service.readText(at: url) == "રફૂ\n")
}
