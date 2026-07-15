import Foundation
import Testing

@testable import RafuApp

// MARK: - Extractor

@Test("Extractor keeps every definition kind and dedups the duplicate-method wart")
func symbolExtractorKeepsAllKindsAndDedups() async throws {
    let text = """
        struct Palette {
            var count = 0
            func rank(query: String) -> Int { 0 }
        }

        func topLevel() {}
        """
    let extracted = try #require(
        await WorkspaceSymbolExtractor.extract(text: text, grammarID: .swift))

    // `var count` is `@definition.property` — kept this increment (the buffer
    // scanner dropped it).
    #expect(extracted.contains { $0.name == "count" && $0.kind == "property" })
    #expect(extracted.contains { $0.name == "Palette" && $0.kind == "class" })
    #expect(extracted.contains { $0.name == "topLevel" && $0.kind == "function" })
    // The Swift `tags.scm` matches a class-body method against both the nested
    // `definition.method` and the generic `definition.function` pattern at the
    // same range; dedup by (name, range) collapses that to one entry.
    #expect(extracted.filter { $0.name == "rank" }.count == 1)

    let nsText = text as NSString
    for symbol in extracted {
        #expect(nsText.substring(with: symbol.range) == symbol.name)
    }
}

@Test("Extractor returns nil for a grammar without a vendored tags.scm")
func symbolExtractorNilForUnsupportedGrammar() async throws {
    #expect(await WorkspaceSymbolExtractor.extract(text: "key: value\n", grammarID: .yaml) == nil)
}

@Test("Extractor maps only grammar-with-tags files by path")
func symbolExtractorGrammarWithTagsFilter() {
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/B.swift") == .swift)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/b.py") == .python)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/b.tsx") == .tsx)
    // json/yaml/markdown/dockerfile map to a grammar but have no tags.scm.
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/b.json") == nil)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "Dockerfile") == nil)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "notes.md") == nil)
}

// MARK: - Build

@Test("Git workspaces index only grammar-with-tags files and respect .gitignore")
func symbolIndexBuildsFromGitWorkspace() async throws {
    try await withRepository { root in
        try write(
            """
            struct Widget {
                func render() {}
            }
            """,
            to: root.appending(path: "Widget.swift"))
        try write("key: value\n", to: root.appending(path: "config.yaml"))
        try write("ignored.swift\n", to: root.appending(path: ".gitignore"))
        try write("func hidden() {}\n", to: root.appending(path: "ignored.swift"))
        try runGitFixture(["add", "Widget.swift", "config.yaml", ".gitignore"], at: root)

        let index = WorkspaceSymbolIndex()
        await index.build(rootURL: root)

        guard case .ready(let count, let isTruncated) = await index.currentState else {
            Issue.record("Expected a ready state")
            return
        }
        #expect(!isTruncated)
        // Widget + render; config.yaml has no tags.scm; ignored.swift ignored.
        #expect(count == 2)

        let matches = try await index.query(term: "render", limit: 10)
        #expect(matches.map(\.name) == ["render"])
        #expect(matches.first?.relativePath == "Widget.swift")
        // `render` is a struct-body method (kind "method"/"function"
        // depending on which `tags.scm` pattern dedup keeps). `Widget` (a
        // struct) is unambiguously kinded "class" by the Swift `tags.scm`.
        #expect(["method", "function"].contains(matches.first?.kind ?? ""))
        let widget = try await index.query(term: "Widget", limit: 10)
        #expect(widget.first?.kind == "class")
    }
}

@Test("Non-git workspaces fall back to a filesystem enumeration")
func symbolIndexFallsBackForNonGitWorkspaces() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("def compute():\n    pass\n", to: root.appending(path: "app.py"))
    try FileManager.default.createDirectory(
        at: root.appending(path: ".build"), withIntermediateDirectories: true)
    try write("func excluded() {}\n", to: root.appending(path: ".build/Ignored.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let matches = try await index.query(term: "compute", limit: 10)
    #expect(matches.map(\.name) == ["compute"])
    // `.build` is an excluded directory: its symbol never appears.
    let excluded = try await index.query(term: "excluded", limit: 10)
    #expect(excluded.isEmpty)
}

@Test("The index skips files above the byte cap before reading them")
func symbolIndexEnforcesFileByteCap() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let big = "func tooBig() {}\n" + String(repeating: "// pad\n", count: 200)
    try write(big, to: root.appending(path: "Big.swift"))
    try write("func small() {}\n", to: root.appending(path: "Small.swift"))

    let index = WorkspaceSymbolIndex(fileByteCap: 64)
    await index.build(rootURL: root)

    #expect(try await index.query(term: "tooBig", limit: 10).isEmpty)
    #expect(try await index.query(term: "small", limit: 10).map(\.name) == ["small"])
}

@Test("The index caps symbols per file")
func symbolIndexEnforcesPerFileSymbolCap() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = (0..<10).map { "func symbol\($0)() {}" }.joined(separator: "\n")
    try write(text, to: root.appending(path: "Many.swift"))

    let index = WorkspaceSymbolIndex(perFileLimit: 3)
    await index.build(rootURL: root)

    guard case .ready(let count, _) = await index.currentState else {
        Issue.record("Expected a ready state")
        return
    }
    #expect(count == 3)
}

@Test("The index enforces the global symbol cap and reports truncation")
func symbolIndexEnforcesGlobalCapAndTruncation() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for fileIndex in 0..<5 {
        let text = (0..<4).map { "func f\(fileIndex)_\($0)() {}" }.joined(separator: "\n")
        try write(text, to: root.appending(path: "File\(fileIndex).swift"))
    }

    let index = WorkspaceSymbolIndex(symbolCap: 6)
    await index.build(rootURL: root)

    guard case .ready(let count, let isTruncated) = await index.currentState else {
        Issue.record("Expected a ready state")
        return
    }
    #expect(count <= 6)
    #expect(isTruncated)
}

// MARK: - Incremental updates

@Test("Incremental updates add, replace, and remove a file's symbols")
func symbolIndexAppliesIncrementalChanges() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appending(path: "Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try write("func original() {}\n", to: sources.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)
    #expect(try await index.query(term: "original", limit: 10).map(\.name) == ["original"])

    // Replace A.swift's contents and add a new B.swift in the same directory.
    try write("func replaced() {}\n", to: sources.appending(path: "A.swift"))
    try write("func added() {}\n", to: sources.appending(path: "B.swift"))
    await index.applyChanges(changedDirectoryRelativePaths: ["Sources"], rootURL: root)

    #expect(try await index.query(term: "original", limit: 10).isEmpty)
    #expect(try await index.query(term: "replaced", limit: 10).map(\.name) == ["replaced"])
    #expect(try await index.query(term: "added", limit: 10).map(\.name) == ["added"])

    // Delete B.swift and re-apply: its symbol is dropped.
    try FileManager.default.removeItem(at: sources.appending(path: "B.swift"))
    await index.applyChanges(changedDirectoryRelativePaths: ["Sources"], rootURL: root)
    #expect(try await index.query(term: "added", limit: 10).isEmpty)
    #expect(try await index.query(term: "replaced", limit: 10).map(\.name) == ["replaced"])
}

@Test("Incremental updates are a no-op on an index that never built")
func symbolIndexIncrementalNoopWhenNotReady() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func here() {}\n", to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.applyChanges(changedDirectoryRelativePaths: [""], rootURL: root)
    #expect(await index.currentState == .idle)
}

// MARK: - Query, reset, shed, cancellation

@Test("Symbol query ranks exact and prefix matches ahead of looser subsequences")
func symbolIndexQueryRanking() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(
        """
        func render() {}
        func renderList() {}
        func gardener() {}
        """,
        to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let ranked = try await index.query(term: "render", limit: 10)
    #expect(ranked.first?.name == "render")
    #expect(ranked.map(\.name).prefix(2) == ["render", "renderList"])
}

@Test("Resetting and shedding the index clear it back to idle")
func symbolIndexResetAndShed() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func here() {}\n", to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)
    #expect(await index.currentState != .idle)

    await index.reset()
    #expect(await index.currentState == .idle)
    #expect(try await index.query(term: "here", limit: 10).isEmpty)

    await index.build(rootURL: root)
    await index.shed()
    #expect(await index.currentState == .idle)
    #expect(try await index.query(term: "here", limit: 10).isEmpty)
}

@Test("Symbol ranker is cancellable")
func symbolRankerRespectsCancellation() async {
    let candidates = (0..<50_000).map {
        WorkspaceSymbolMatch(
            name: "symbol\($0)", kind: "function", relativePath: "File\($0 % 200).swift",
            range: NSRange(location: 0, length: 6))
    }
    let task = Task {
        try await WorkspaceSymbolRanker.rank(query: "symbol", candidates: candidates, limit: 10)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

// MARK: - Fixtures

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-symbol-index-tests-\(UUID().uuidString)",
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
        throw SymbolIndexTestFixtureError.gitCommandFailed(arguments: arguments, message: message)
    }
}

private enum SymbolIndexTestFixtureError: Error {
    case gitCommandFailed(arguments: [String], message: String)
}
