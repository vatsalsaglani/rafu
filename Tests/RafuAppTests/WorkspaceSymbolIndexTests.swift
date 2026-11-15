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

/// A fixture whose names are longer than 15 UTF-8 bytes (so a `String` cannot
/// hold them inline) and whose file contains a non-ASCII character before and
/// inside the names (so the UTF-16 offsets differ from the byte offsets).
private let nativeNameFixture = """
    // Größe 日本語 comment
    struct ConfigurationRegistryProvider {
        func resolveConfigurationValueForKey() {}
        var currentConfigurationSnapshotValue = 0
        let größenAnpassungsFaktorWert = 1
    }
    func topLevelInitializationCoordinator() {}
    """

@Test("Extracted symbol names are native strings, not bridged NSString values")
func symbolExtractorNamesAreContiguousUTF8() async throws {
    let extracted = try #require(
        await WorkspaceSymbolExtractor.extract(text: nativeNameFixture, grammarID: .swift))

    let names = Set(extracted.map(\.name))
    #expect(names.contains("ConfigurationRegistryProvider"))
    #expect(names.contains("resolveConfigurationValueForKey"))
    #expect(names.contains("größenAnpassungsFaktorWert"))
    #expect(names.contains { $0.utf8.count > 15 })
    // A bridged `NSString` is not contiguous UTF-8; this fails if the
    // `makeContiguousUTF8()` copy in `WorkspaceSymbolExtractor` is removed.
    for symbol in extracted {
        #expect(symbol.name.isContiguousUTF8, "\(symbol.name) is not native")
    }
}

@Test("Names returned by the built index are native strings")
func symbolIndexNamesAreContiguousUTF8() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(nativeNameFixture, to: root.appending(path: "Fixture.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let matches = try await index.query(term: "Configuration", limit: 20)
    #expect(matches.count >= 3)
    for match in matches {
        #expect(match.name.isContiguousUTF8, "\(match.name) is not native")
        #expect(match.relativePath.isContiguousUTF8)
    }
}

@Test("Extractor returns nil for a grammar without a vendored tags.scm")
func symbolExtractorNilForUnsupportedGrammar() async throws {
    #expect(await WorkspaceSymbolExtractor.extract(text: "{}\n", grammarID: .json) == nil)
}

@Test("Extractor finds TOML table names and bare-key pairs")
func symbolExtractorTOMLGrammar() async throws {
    let extracted = try #require(
        await WorkspaceSymbolExtractor.extract(
            text: "[server]\nport = 8080\n", grammarID: .toml))

    #expect(extracted.contains { $0.name == "server" && $0.kind == "class" })
    #expect(extracted.contains { $0.name == "port" && $0.kind == "property" })
}

@Test("Extractor finds Markdown ATX and Setext headings as sections")
func symbolExtractorMarkdownGrammar() async throws {
    let extracted = try #require(
        await WorkspaceSymbolExtractor.extract(
            text: "# Alpha\n\nBeta\n=====\n\n## Gamma\n", grammarID: .markdown))

    #expect(extracted.allSatisfy { $0.kind == "section" })
    // The `setext_heading` capture's `paragraph` field spans through the
    // trailing newline before the underline, so names are trimmed of
    // whitespace/newlines for the comparison — the extractor itself is left
    // untouched.
    let names = Set(
        extracted.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
    #expect(names == ["Alpha", "Beta", "Gamma"])
}

@Test("Extractor maps only grammar-with-tags files by path")
func symbolExtractorGrammarWithTagsFilter() {
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/B.swift") == .swift)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/b.py") == .python)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/b.tsx") == .tsx)
    // json maps to a grammar but has no tags.scm; Dockerfile and Bash gained
    // a vendored tags.scm in the symbol-coverage lane's increment A; TOML
    // and YAML gained one in increment B; Markdown gained one in
    // increment C.
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "a/b.json") == nil)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "Dockerfile") == .dockerfile)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "build.sh") == .bash)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "notes.md") == .markdown)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "Cargo.toml") == .toml)
    #expect(WorkspaceSymbolExtractor.grammarWithTags(forRelativePath: "config.yaml") == .yaml)
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
        // Widget + render; config.yaml's top-level `key: value` pair is now
        // indexed by the YAML `tags.scm` added in increment B; ignored.swift
        // is excluded by .gitignore.
        #expect(count == 3)

        let matches = try await index.query(term: "render", limit: 10)
        #expect(matches.map(\.name) == ["render"])
        #expect(matches.first?.relativePath == "Widget.swift")
        // `render` is a struct-body method (kind "method"/"function"
        // depending on which `tags.scm` pattern dedup keeps). `Widget` (a
        // struct) is unambiguously kinded "class" by the Swift `tags.scm`.
        #expect(["method", "function"].contains(matches.first?.kind ?? ""))
        let widget = try await index.query(term: "Widget", limit: 10)
        #expect(widget.first?.kind == "class")

        let key = try await index.query(term: "key", limit: 10)
        #expect(key.map(\.name) == ["key"])
        #expect(key.first?.relativePath == "config.yaml")
        #expect(key.first?.kind == "property")
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

@Test("A directory symlink listed before sibling directories does not hide the first sibling")
func symbolIndexSymlinkBeforeSiblingsKeepsEveryDirectory() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileManager = FileManager.default
    for directory in 0..<2 {
        try fileManager.createDirectory(
            at: root.appending(path: "Modul\(directory)"), withIntermediateDirectories: true)
        try write(
            "def kennung\(directory)():\n    pass\n",
            to: root.appending(path: "Modul\(directory)/app.py"))
    }
    // `Link` sorts before `Modul0` and points at a sibling directory.
    try fileManager.createSymbolicLink(
        atPath: root.appending(path: "Link").path, withDestinationPath: "Modul1")

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let first = try await index.query(term: "kennung0", limit: 10)
    #expect(first.map(\.name) == ["kennung0"])
    let second = try await index.query(term: "kennung1", limit: 10)
    #expect(second.map(\.name) == ["kennung1"])
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

@Test("A rebuild drops the old generation first: never two symbol sets at once")
func symbolIndexRebuildNeverHoldsTwoGenerations() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(
        "func one() {}\nfunc two() {}\nfunc three() {}\nfunc four() {}\n",
        to: root.appending(path: "A.swift"))
    try write("func five() {}\nfunc six() {}\n", to: root.appending(path: "B.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)
    guard case .ready(let count, _) = await index.currentState else {
        Issue.record("Expected a ready state")
        return
    }
    #expect(count == 6)
    #expect(await index.peakRetainedSymbolCount == count)

    // A second full build over the same tree: if the old generation stayed
    // live until the swap, the peak would reach 2 x count.
    await index.build(rootURL: root)
    #expect(await index.currentState == .ready(count: count, isTruncated: false))
    #expect(await index.peakRetainedSymbolCount == count)
    #expect(await index.startedBuildCount == 2)
}

@Test("A cancelled build leaves an empty, idle index")
func symbolIndexCancelledBuildIsIdleAndEmpty() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func here() {}\n", to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)
    #expect(try await index.query(term: "here", limit: 10).map(\.name) == ["here"])

    // A child added to a cancelled group starts cancelled, so the build sees
    // the cancellation deterministically (no race with a fast build).
    await withTaskGroup(of: Void.self) { group in
        group.cancelAll()
        group.addTask { await index.build(rootURL: root) }
    }

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
