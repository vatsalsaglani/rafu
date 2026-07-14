import Foundation
import Testing

@testable import RafuApp

@Test("Directory listing sorts folders first and excludes generated directories")
func workspaceDirectoryListingIsBoundedAndSorted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("hello".utf8).write(to: root.appending(path: "z.txt"))
    try FileManager.default.createDirectory(
        at: root.appending(path: "A"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appending(path: ".build"), withIntermediateDirectories: true)

    let listing = try await WorkspaceFileService().listDirectory(
        rootURL: root, relativeDirectoryPath: "")

    #expect(listing.map(\.name) == ["A", "z.txt"])
}

@Test("Directory listing lists exactly one level and never recurses into subdirectories")
func workspaceDirectoryListingDoesNotRecurse() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appending(path: "A")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: nested.appending(path: "inner.txt"))

    let service = WorkspaceFileService()
    let rootListing = try await service.listDirectory(rootURL: root, relativeDirectoryPath: "")
    #expect(rootListing.map(\.name) == ["A"])
    #expect(rootListing.first?.isDirectory == true)

    let nestedListing = try await service.listDirectory(
        rootURL: root, relativeDirectoryPath: "A")
    #expect(nestedListing.map(\.name) == ["inner.txt"])
}

@Test("Workspace service atomically writes and reads UTF-8 text")
func workspaceReadWriteRoundTrip() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let service = WorkspaceFileService()

    try await service.writeText("રફૂ\n", to: url)

    #expect(try await service.readText(at: url) == "રફૂ\n")
}
