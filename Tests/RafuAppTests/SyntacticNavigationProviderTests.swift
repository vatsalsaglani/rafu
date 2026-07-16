import Foundation
import Testing

@testable import RafuApp

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-syntactic-nav-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}

@Test("Provider ranks definitions same-file, then same-directory, then lexicographic")
func syntacticProviderRanksDefinitions() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Four files each declaring `target`, in three locations relative to the
    // request's own file `feature/Current.swift`.
    try write("func target() {}\n", to: root.appending(path: "feature/Current.swift"))
    try write("func target() {}\n", to: root.appending(path: "feature/Sibling.swift"))
    try write("func target() {}\n", to: root.appending(path: "other/Far.swift"))
    try write("func target() {}\n", to: root.appending(path: "aaa/Alpha.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let provider = SyntacticNavigationProvider(index: index, rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "feature/Current.swift"),
        position: 0,
        languageID: "swift",
        kind: .definition,
        symbolName: "target"
    )
    let answer = try #require(try await provider.answer(request))
    #expect(answer.tier == .syntactic)
    #expect(answer.state == .ready)

    let paths = answer.candidates.map(\.relativePath)
    // Same file first, then same directory (Sibling), then the rest
    // lexicographically (aaa/Alpha before other/Far).
    #expect(
        paths == [
            "feature/Current.swift",
            "feature/Sibling.swift",
            "aaa/Alpha.swift",
            "other/Far.swift",
        ])
    #expect(answer.candidates.first?.kindLabel == "function")
    #expect(answer.candidates.first?.previewLine == "func target() {}")
}

@Test("Provider declines references so the text tier can answer")
func syntacticProviderDeclinesReferences() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func target() {}\n", to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let provider = SyntacticNavigationProvider(index: index, rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .references,
        symbolName: "target"
    )
    #expect(try await provider.answer(request) == nil)
}

@Test("Provider declines hover and a missing symbol name")
func syntacticProviderDeclinesHoverAndMissingName() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func target() {}\n", to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let provider = SyntacticNavigationProvider(index: index, rootURL: root)
    let base = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .hover,
        symbolName: "target"
    )
    #expect(try await provider.answer(base) == nil)

    let missingName = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .definition,
        symbolName: nil
    )
    #expect(try await provider.answer(missingName) == nil)
}

@Test("Provider reports indexing (not authoritative) for a fresh, unbuilt index")
func syntacticProviderFreshIndexIsIndexing() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func target() {}\n", to: root.appending(path: "A.swift"))

    // Deliberately never `build(rootURL:)`ed — the index starts `.idle`.
    let index = WorkspaceSymbolIndex()

    let provider = SyntacticNavigationProvider(index: index, rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .definition,
        symbolName: "target"
    )
    let answer = try #require(try await provider.answer(request))
    #expect(answer.state == .indexing)
    #expect(answer.candidates.isEmpty)
}

@Test("Provider is authoritative for a ready index with no matching declaration")
func syntacticProviderReadyWithNoMatchIsAuthoritative() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("func present() {}\n", to: root.appending(path: "A.swift"))

    let index = WorkspaceSymbolIndex()
    await index.build(rootURL: root)

    let provider = SyntacticNavigationProvider(index: index, rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .definition,
        symbolName: "absent"
    )
    // Non-nil answer with empty candidates: ready and authoritative, NOT a
    // decline (the ladder must not fall through to the text tier).
    let answer = try #require(try await provider.answer(request))
    #expect(answer.state == .ready)
    #expect(answer.candidates.isEmpty)
}
