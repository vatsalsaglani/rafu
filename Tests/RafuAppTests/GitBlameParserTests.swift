import Foundation
import Testing

@testable import RafuApp

@Suite("Git blame parser")
struct GitBlameParserTests {
    private let rootID = String(repeating: "a", count: 40)
    private let nextID = String(repeating: "b", count: 40)

    @Test("Two commits map line numbers, authors, timestamps, and summaries")
    func twoCommits() throws {
        let blame = GitBlameParser.parse(
            fixture(
                "\(rootID) 1 1 1",
                "author Root Author",
                "author-time 1577836800",
                "summary Initial",
                "boundary",
                "filename file.txt",
                "\tone",
                "\(nextID) 2 2 1",
                "author Next Author",
                "author-time 1609459200",
                "summary Update line two",
                "filename file.txt",
                "\ttwo"
            )
        )

        #expect(blame.lines.count == 2)
        let first = try #require(blame.lines.first)
        let second = try #require(blame.lines.last)
        #expect(first.lineNumber == 1)
        #expect(first.commitID == rootID)
        #expect(first.shortID == "aaaaaaaa")
        #expect(first.author == "Root Author")
        #expect(first.summary == "Initial")
        #expect(first.time.timeIntervalSince1970 == 1_577_836_800)
        #expect(first.isBoundary)
        #expect(second.lineNumber == 2)
        #expect(second.commitID == nextID)
        #expect(second.author == "Next Author")
        #expect(second.summary == "Update line two")
        #expect(!second.isBoundary)
    }

    @Test("Deduplicated headers reuse SHA metadata including boundary state")
    func metadataCache() {
        let blame = GitBlameParser.parse(
            fixture(
                "\(rootID) 1 1 2",
                "author Root Author",
                "author-time 1577836800",
                "summary Initial",
                "boundary",
                "filename file.txt",
                "\tone",
                "\(rootID) 2 2",
                "\ttwo"
            )
        )

        #expect(blame.lines.map(\.lineNumber) == [1, 2])
        #expect(blame.lines.map(\.author) == ["Root Author", "Root Author"])
        #expect(blame.lines.allSatisfy { $0.isBoundary })
    }

    @Test("Malformed headers and blocks missing metadata are ignored")
    func malformedBlocks() {
        let blame = GitBlameParser.parse(
            fixture(
                "not-a-sha 1 1 1",
                "\tignored",
                "\(nextID) 1 0 1",
                "\tignored",
                "\(nextID) 1 1 1",
                "author Nobody",
                "\tmissing time and summary"
            )
        )

        #expect(blame.lines.isEmpty)
    }
}

private func fixture(_ lines: String...) -> Data {
    Data((lines.joined(separator: "\n") + "\n").utf8)
}
