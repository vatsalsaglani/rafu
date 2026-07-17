import Foundation
import Testing

@testable import RafuApp

@Suite("Git stash parser")
struct GitStashParserTests {
    @Test("Empty output produces no stashes")
    func emptyOutput() {
        #expect(GitStashParser.parse(Data()).isEmpty)
    }

    @Test("WIP subjects expose branch and distinguish their generated message")
    func wipSubject() throws {
        let entries = GitStashParser.parse(
            records("stash@{0}\u{1F}1700000000\u{1F}WIP on feature/git: pending edits")
        )

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.index == 0)
        #expect(entry.selector == "stash@{0}")
        #expect(entry.branch == "feature/git")
        #expect(entry.message == "WIP — pending edits")
        #expect(entry.createdAt.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("Named On subjects expose the user message without a WIP label")
    func namedSubject() throws {
        let entry = try #require(
            GitStashParser.parse(
                records("stash@{3}\u{1F}1700000123\u{1F}On main: before refactor")
            ).first
        )

        #expect(entry.index == 3)
        #expect(entry.branch == "main")
        #expect(entry.message == "before refactor")
    }

    @Test("Many records preserve order and tolerate fallback subjects")
    func manyRecords() {
        let entries = GitStashParser.parse(
            records(
                "stash@{0}\u{1F}1700000002\u{1F}On main: newest",
                "stash@{1}\u{1F}1700000001\u{1F}WIP on main: older",
                "stash@{2}\u{1F}1700000000\u{1F}imported stash"
            )
        )

        #expect(entries.map(\.index) == [0, 1, 2])
        #expect(entries.map(\.message) == ["newest", "WIP — older", "imported stash"])
        #expect(entries.map(\.branch) == ["main", "main", nil])
    }

    @Test("Malformed and noncanonical selectors are rejected")
    func invalidRecords() {
        let entries = GitStashParser.parse(
            records(
                "stash@{01}\u{1F}1700000000\u{1F}On main: leading zero",
                "stash@{-1}\u{1F}1700000000\u{1F}On main: negative",
                "refs/stash\u{1F}1700000000\u{1F}On main: raw ref",
                "stash@{0}\u{1F}-1\u{1F}On main: invalid time",
                "stash@{0}\u{1F}1700000000"
            )
        )

        #expect(entries.isEmpty)
    }
}

private func records(_ values: String...) -> Data {
    var data = Data()
    for value in values {
        data.append(Data(value.utf8))
        data.append(0)
    }
    return data
}
