import Foundation
import Testing

@testable import RafuApp

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-text-search-nav-tests-\(UUID().uuidString)",
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

@Test("Text tier ranks matches same-file, then same-directory, then lexicographic")
func textTierRanksMatches() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // The request's own file has the target twice; a sibling and two
    // distant files each have it once. Written in an order that would NOT
    // already sort correctly by raw filesystem enumeration.
    try write(
        "let widget = 1\nfunc widget() {}\n", to: root.appending(path: "feature/Current.swift"))
    try write("let widget = 2\n", to: root.appending(path: "other/Far.swift"))
    try write("let widget = 3\n", to: root.appending(path: "aaa/Alpha.swift"))
    try write("let widget = 4\n", to: root.appending(path: "feature/Sibling.swift"))

    let provider = TextSearchNavigationProvider(rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "feature/Current.swift"),
        position: 0,
        languageID: "swift",
        kind: .references,
        symbolName: "widget"
    )
    let answer = try #require(try await provider.answer(request))
    #expect(answer.tier == .text)

    let paths = answer.candidates.map(\.relativePath)
    #expect(
        paths == [
            "feature/Current.swift",
            "feature/Current.swift",
            "feature/Sibling.swift",
            "aaa/Alpha.swift",
            "other/Far.swift",
        ])
}

@Test("Text tier declines .hover so hover stays LSP-only")
func textTierDeclinesHover() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("let widget = 1\n", to: root.appending(path: "A.swift"))

    let provider = TextSearchNavigationProvider(rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .hover,
        symbolName: "widget"
    )
    #expect(try await provider.answer(request) == nil)
}

@Test("Text tier declines when no symbol name is supplied")
func textTierDeclinesMissingSymbolName() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("let widget = 1\n", to: root.appending(path: "A.swift"))

    let provider = TextSearchNavigationProvider(rootURL: root)
    let request = NavigationRequest(
        documentURL: root.appending(path: "A.swift"),
        position: 0,
        languageID: "swift",
        kind: .references,
        symbolName: nil
    )
    #expect(try await provider.answer(request) == nil)
}
