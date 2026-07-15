import Foundation
import Testing

@testable import RafuApp

@Test("Git workspaces are indexed via git ls-files and respect .gitignore")
func fileNameIndexRespectsGitignoreInGitWorkspaces() async throws {
    try await withRepository { root in
        try write("tracked file", to: root.appending(path: "Tracked.swift"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        try write("nested", to: root.appending(path: "Sources/Nested.swift"))
        try write("ignored\n", to: root.appending(path: ".gitignore"))
        try write("build artifact", to: root.appending(path: "ignored"))
        try runGitFixture(["add", "Tracked.swift", "Sources/Nested.swift", ".gitignore"], at: root)
        try write("untracked but not ignored", to: root.appending(path: "Untracked.swift"))

        let index = WorkspaceFileNameIndex()
        await index.build(rootURL: root)

        guard case .ready(let count, let isTruncated) = await index.currentState else {
            Issue.record("Expected a ready state")
            return
        }
        #expect(!isTruncated)
        #expect(count == 4)

        let all = try await index.query(term: "", limit: 10)
        #expect(
            Set(all) == ["Tracked.swift", "Sources/Nested.swift", ".gitignore", "Untracked.swift"])
        #expect(!all.contains("ignored"))
    }
}

@Test("Non-git workspaces fall back to a filesystem enumeration with shared exclusions")
func fileNameIndexFallsBackForNonGitWorkspaces() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("hello", to: root.appending(path: "Main.swift"))
    try FileManager.default.createDirectory(
        at: root.appending(path: ".build"), withIntermediateDirectories: true)
    try write("junk", to: root.appending(path: ".build/Artifact.o"))
    try FileManager.default.createDirectory(
        at: root.appending(path: "Sources"), withIntermediateDirectories: true)
    try write("nested", to: root.appending(path: "Sources/Nested.swift"))
    try write("noise", to: root.appending(path: ".DS_Store"))

    let index = WorkspaceFileNameIndex()
    await index.build(rootURL: root)

    guard case .ready(let count, let isTruncated) = await index.currentState else {
        Issue.record("Expected a ready state")
        return
    }
    #expect(!isTruncated)
    #expect(count == 2)

    let all = try await index.query(term: "", limit: 10)
    #expect(Set(all) == ["Main.swift", "Sources/Nested.swift"])
}

@Test("The index caps enumeration and reports truncation")
func fileNameIndexReportsTruncation() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<10 {
        try write("contents", to: root.appending(path: "File\(index).swift"))
    }

    let index = WorkspaceFileNameIndex(entryCap: 4)
    await index.build(rootURL: root)

    guard case .ready(let count, let isTruncated) = await index.currentState else {
        Issue.record("Expected a ready state")
        return
    }
    #expect(count == 4)
    #expect(isTruncated)
}

@Test("Querying an empty term returns entries up to the limit; a term ranks filename matches first")
func fileNameIndexQueryRanksFilenameMatchesFirst() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appending(path: "widgets/legacy"), withIntermediateDirectories: true)
    try write("a", to: root.appending(path: "widgets/legacy/Old.swift"))
    try write("b", to: root.appending(path: "Widget.swift"))

    let index = WorkspaceFileNameIndex()
    await index.build(rootURL: root)

    let limited = try await index.query(term: "", limit: 1)
    #expect(limited.count == 1)

    let ranked = try await index.query(term: "widget", limit: 10)
    #expect(ranked.first == "Widget.swift")
}

@Test("Resetting the index clears its state back to idle")
func fileNameIndexResetReturnsToIdle() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("hello", to: root.appending(path: "Main.swift"))

    let index = WorkspaceFileNameIndex()
    await index.build(rootURL: root)
    #expect(await index.currentState != .idle)

    await index.reset()
    #expect(await index.currentState == .idle)
    let results = try await index.query(term: "", limit: 10)
    #expect(results.isEmpty)
}

@Test("Index queries are cancellable")
func fileNameIndexQueryIsCancellable() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<5_000 {
        try write("contents", to: root.appending(path: "File\(index).swift"))
    }

    let index = WorkspaceFileNameIndex()
    await index.build(rootURL: root)

    let task = Task {
        try await index.query(term: "file", limit: 10)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test("Shedding the index clears its state back to idle, exactly like reset")
func fileNameIndexShedReturnsToIdle() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("hello", to: root.appending(path: "Main.swift"))

    let index = WorkspaceFileNameIndex()
    await index.build(rootURL: root)
    #expect(await index.currentState != .idle)

    await index.shed()
    #expect(await index.currentState == .idle)
    let results = try await index.query(term: "", limit: 10)
    #expect(results.isEmpty)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-file-index-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url)
}

private func withRepository(
    _ body: (URL) async throws -> Void
) async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try runGitFixture(["init", "-b", "main"], at: root)
    try runGitFixture(["config", "user.name", "Rafu Tests"], at: root)
    try runGitFixture(["config", "user.email", "rafu-tests@example.invalid"], at: root)
    try await body(root)
}

private func runGitFixture(_ arguments: [String], at root: URL) throws {
    let process = Process()
    let capture = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    _ = FileManager.default.createFile(atPath: capture.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: capture) }
    let output = try FileHandle(forWritingTo: capture)
    defer { try? output.close() }

    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
        throw TestFixtureError.gitCommandFailed(arguments: arguments, message: message)
    }
}

private enum TestFixtureError: Error {
    case gitCommandFailed(arguments: [String], message: String)
}
