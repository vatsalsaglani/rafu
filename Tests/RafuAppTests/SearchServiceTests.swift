import Foundation
import Testing

@testable import RafuApp

@Test("Workspace search groups text matches and skips ignored, binary, and symlink files")
func workspaceSearchIsBoundedAndSafe() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("Rafu\nother Rafu\n".utf8).write(to: root.appending(path: "visible.txt"))
    try Data([0, 1, 2, 3]).write(to: root.appending(path: "binary.dat"))
    let ignored = root.appending(path: "node_modules", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try Data("Rafu".utf8).write(to: ignored.appending(path: "ignored.txt"))
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "linked.txt"),
        withDestinationURL: root.appending(path: "visible.txt")
    )

    let result = try await WorkspaceSearchService().search(
        WorkspaceSearchRequest(rootURL: root, query: "Rafu", options: [.caseSensitive]))

    #expect(result.groups.map(\.relativePath) == ["visible.txt"])
    #expect(result.groups.first?.matches.map(\.line) == [1, 2])
    #expect(result.totalMatchCount == 2)
    #expect(result.statistics.skippedBinaryFiles == 1)
    #expect(result.statistics.skippedIgnoredItems == 1)
    #expect(result.statistics.skippedSymlinks == 1)
}

@Test("Workspace search applies include and exclude globs")
func workspaceSearchAppliesGlobFilters() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appending(path: "Sources/App", directoryHint: .isDirectory)
    let tests = root.appending(path: "Tests", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try Data("Rafu".utf8).write(to: sources.appending(path: "Main.swift"))
    try Data("Rafu".utf8).write(to: sources.appending(path: "notes.md"))
    try Data("Rafu".utf8).write(to: tests.appending(path: "MainTests.swift"))
    let service = WorkspaceSearchService()

    let included = try await service.search(
        WorkspaceSearchRequest(rootURL: root, query: "Rafu", includeGlobs: ["*.swift"]))
    #expect(
        included.groups.map(\.relativePath) == ["Sources/App/Main.swift", "Tests/MainTests.swift"])

    let filtered = try await service.search(
        WorkspaceSearchRequest(
            rootURL: root,
            query: "Rafu",
            includeGlobs: ["*.swift"],
            excludeGlobs: ["Tests"]
        ))
    #expect(filtered.groups.map(\.relativePath) == ["Sources/App/Main.swift"])
    #expect(filtered.statistics.skippedIgnoredItems > 0)

    let excludedByPath = try await service.search(
        WorkspaceSearchRequest(rootURL: root, query: "Rafu", excludeGlobs: ["Sources/**"]))
    #expect(excludedByPath.groups.map(\.relativePath) == ["Tests/MainTests.swift"])
}

@Test("Workspace search enforces per-file and total result limits")
func workspaceSearchHonorsResultLimits() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x x x x".utf8).write(to: root.appending(path: "many.txt"))
    var limits = WorkspaceSearchLimits.standard
    limits.maximumMatchesPerFile = 2
    limits.maximumTotalMatches = 2

    let result = try await WorkspaceSearchService().search(
        WorkspaceSearchRequest(rootURL: root, query: "x", limits: limits))

    #expect(result.totalMatchCount == 2)
    #expect(result.groups.first?.matches.count == 2)
    #expect(result.groups.first?.isTruncated == true)
    #expect(result.isTruncated)
}

@Test("Replacement preview applies regex captures using atomic file writes")
func workspaceReplacementPreviewAndApply() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "theme.txt")
    try Data("indigo-khadi\nindigo-khadi\n".utf8).write(to: file)
    let service = WorkspaceSearchService()
    let request = WorkspaceSearchRequest(
        rootURL: root,
        query: #"(indigo)-(khadi)"#,
        options: [.regularExpression, .caseSensitive]
    )

    let preview = try await service.previewReplacement(request, replacement: "$2/$1")
    #expect(preview.replacementCount == 2)
    #expect(preview.files.first?.edits.first?.replacement == "khadi/indigo")

    let report = try await service.apply(preview)

    #expect(report.changedFiles == [file])
    #expect(report.replacementCount == 2)
    #expect(try String(contentsOf: file, encoding: .utf8) == "khadi/indigo\nkhadi/indigo\n")
}

@Test("Workspace replacement refuses stale previews")
func workspaceReplacementDetectsExternalChange() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "notes.txt")
    try Data("Rafu".utf8).write(to: file)
    let service = WorkspaceSearchService()
    let preview = try await service.previewReplacement(
        WorkspaceSearchRequest(rootURL: root, query: "Rafu"),
        replacement: "રફૂ"
    )
    try Data("externally changed".utf8).write(to: file, options: .atomic)

    await #expect(throws: WorkspaceSearchError.self) {
        try await service.apply(preview)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "externally changed")
}

@Test("Workspace search truncates once the maximumFiles visited cap is hit")
func workspaceSearchTruncatesAtMaximumFilesCap() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<5 {
        try Data("Rafu".utf8).write(to: root.appending(path: "file\(index).txt"))
    }
    var limits = WorkspaceSearchLimits.standard
    limits.maximumFiles = 2

    let result = try await WorkspaceSearchService().search(
        WorkspaceSearchRequest(rootURL: root, query: "Rafu", limits: limits))

    #expect(result.isTruncated)
    #expect(result.groups.count <= 2)
}

@Test("Workspace search skips a file over maximumFileBytes without reading it")
func workspaceSearchSkipsFilesOverMaximumFileBytesCap() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("Rafu".utf8).write(to: root.appending(path: "small.txt"))
    let oversizedContent = String(repeating: "Rafu ", count: 10)
    try Data(oversizedContent.utf8).write(to: root.appending(path: "large.txt"))
    var limits = WorkspaceSearchLimits.standard
    limits.maximumFileBytes = 10

    let result = try await WorkspaceSearchService().search(
        WorkspaceSearchRequest(rootURL: root, query: "Rafu", limits: limits))

    #expect(result.groups.map(\.relativePath) == ["small.txt"])
    #expect(result.statistics.skippedLargeFiles == 1)
    #expect(!result.isTruncated)
}

/// Service-level analog of `WorkspaceSearchModel`'s cancel-safety: the model
/// only assigns `self?.result` after `try Task.checkCancellation()` post
/// -await, so a cancelled search task never publishes stale/partial results.
/// This exercises the guarantee that backs it — `scan`'s
/// `Task.checkCancellation()` at the top of its enumeration loop throws
/// before any group is produced, so there is nothing left to publish.
@Test("A cancelled search throws before producing any result to publish")
func workspaceSearchCancellationNeverReturnsAResult() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<5_000 {
        try Data("Rafu".utf8).write(to: root.appending(path: "file\(index).txt"))
    }

    let service = WorkspaceSearchService()
    let task = Task {
        try await service.search(WorkspaceSearchRequest(rootURL: root, query: "Rafu"))
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
