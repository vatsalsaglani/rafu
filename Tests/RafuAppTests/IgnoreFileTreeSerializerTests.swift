import Testing

@testable import RafuApp

@Suite("Ignore file tree serializer")
struct IgnoreFileTreeSerializerTests {
    @Test("Empty input serializes to an empty string")
    func emptyInput() {
        #expect(IgnoreFileTreeSerializer.serialize(paths: []).isEmpty)
    }

    @Test("Paths render as an indented, sorted tree")
    func sortedTree() {
        let output = IgnoreFileTreeSerializer.serialize(
            paths: ["b.txt", "a/two.txt", "a/one.txt"]
        )
        #expect(
            output
                == """
                a/
                  one.txt
                  two.txt
                b.txt
                """)
    }

    @Test("Identical inputs in a different order serialize identically")
    func deterministicOrdering() {
        let first = IgnoreFileTreeSerializer.serialize(paths: ["z", "a", "m/1", "m/2"])
        let second = IgnoreFileTreeSerializer.serialize(paths: ["m/2", "a", "m/1", "z"])
        #expect(first == second)
    }

    @Test("A directory with more children than the cap collapses with a count")
    func directoryChildCollapse() {
        let paths = (1...30).map { "dir/file\(String(format: "%02d", $0)).txt" }
        let output = IgnoreFileTreeSerializer.serialize(paths: paths, maxChildrenPerDirectory: 5)
        let lines = output.split(separator: "\n")
        #expect(lines.first == "dir/")
        #expect(lines.contains { $0.contains("… and 25 more") })
        #expect(lines.count == 7)  // "dir/" + 5 files + 1 collapse line
    }

    @Test("Total output stops at the line cap and marks truncation")
    func totalLineCap() {
        let paths = (1...50).map { "file\(String(format: "%02d", $0)).txt" }
        let output = IgnoreFileTreeSerializer.serialize(paths: paths, maxLines: 10)
        let lines = output.split(separator: "\n")
        #expect(lines.count == 11)  // 10 files + the truncation marker
        #expect(lines.last == "… output truncated")
    }

    @Test("Nested directories indent by depth")
    func nestedIndentation() {
        let output = IgnoreFileTreeSerializer.serialize(paths: ["a/b/c.txt"])
        #expect(
            output
                == """
                a/
                  b/
                    c.txt
                """)
    }
}
