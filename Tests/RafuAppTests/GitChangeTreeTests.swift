import Foundation
import Testing

@testable import RafuApp

@Test("Single-child directory chains compact into one segment, stopping at branching")
func gitChangeTreeCompactsChainsAndStopsAtBranching() throws {
    let changes = [
        GitChange(path: "Sources/RafuApp/AI/Client.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "Sources/RafuApp/Git/Service.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "Sources/RafuApp/Views/Root.swift", indexStatus: " ", worktreeStatus: "M"),
    ]

    let tree = GitChangeTreeBuilder.build(changes: changes)

    #expect(tree.rootFiles.isEmpty)
    #expect(tree.directories.count == 1)
    let top = try #require(tree.directories.first)
    #expect(top.displayName == "Sources/RafuApp")
    #expect(top.id == "Sources/RafuApp")
    #expect(top.fileCount == 3)
    #expect(top.directories.map(\.displayName).sorted() == ["AI", "Git", "Views"])
    #expect(top.directories.allSatisfy { $0.files.count == 1 })
}

@Test("Root-level loose files are grouped separately from compacted directories")
func gitChangeTreeGroupsRootFilesSeparately() {
    let changes = [
        GitChange(path: "README.md", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "Package.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "Sources/RafuApp/Root.swift", indexStatus: " ", worktreeStatus: "M"),
    ]

    let tree = GitChangeTreeBuilder.build(changes: changes)

    #expect(tree.rootFiles.map(\.path) == ["Package.swift", "README.md"])
    #expect(tree.directories.map(\.displayName) == ["Sources/RafuApp"])
}

@Test("A directory with its own files does not compact past itself")
func gitChangeTreeStopsCompactionWhenDirectoryHasOwnFiles() throws {
    let changes = [
        GitChange(path: "Sources/index.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "Sources/RafuApp/Root.swift", indexStatus: " ", worktreeStatus: "M"),
    ]

    let tree = GitChangeTreeBuilder.build(changes: changes)

    #expect(tree.directories.map(\.displayName) == ["Sources"])
    let sources = try #require(tree.directories.first)
    #expect(sources.id == "Sources")
    #expect(sources.files.map(\.path) == ["Sources/index.swift"])
    #expect(sources.directories.map(\.displayName) == ["RafuApp"])
}

@Test("Folder staging state aggregates children, and one partial file makes the folder partial")
func gitChangeTreeAggregatesTriStateStaging() throws {
    let allStaged = [
        GitChange(path: "a/one.swift", indexStatus: "M", worktreeStatus: " "),
        GitChange(path: "a/two.swift", indexStatus: "A", worktreeStatus: " "),
    ]
    let allStagedTree = GitChangeTreeBuilder.build(changes: allStaged)
    #expect(try #require(allStagedTree.directories.first).stagingState == .all)

    let allUnstaged = [
        GitChange(path: "b/one.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "b/two.swift", indexStatus: "?", worktreeStatus: "?"),
    ]
    let allUnstagedTree = GitChangeTreeBuilder.build(changes: allUnstaged)
    #expect(try #require(allUnstagedTree.directories.first).stagingState == .none)

    let mixed = [
        GitChange(path: "c/one.swift", indexStatus: "M", worktreeStatus: " "),
        GitChange(path: "c/two.swift", indexStatus: " ", worktreeStatus: "M"),
    ]
    let mixedTree = GitChangeTreeBuilder.build(changes: mixed)
    #expect(try #require(mixedTree.directories.first).stagingState == .some)

    let partialFileOnly = [
        GitChange(path: "d/one.swift", indexStatus: "M", worktreeStatus: "M")
    ]
    let partialTree = GitChangeTreeBuilder.build(changes: partialFileOnly)
    #expect(try #require(partialTree.directories.first).stagingState == .some)
}

@Test("visibleRows lists directories before files at every depth and honors collapsed folders")
func gitChangeTreeFlattenerOrdersAndCollapses() {
    let changes = [
        GitChange(path: "z-root.txt", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "src/a.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "src/nested/b.swift", indexStatus: " ", worktreeStatus: "M"),
        GitChange(path: "src/c.swift", indexStatus: " ", worktreeStatus: "M"),
    ]
    let tree = GitChangeTreeBuilder.build(changes: changes)

    let expanded = GitChangeTreeBuilder.visibleRows(tree: tree, collapsedIDs: [])
    let expandedIDs = expanded.map(\.id)
    // "src" folder, then its child folder "src/nested" before its own files,
    // then "src"'s own files, then the root-level loose file last.
    #expect(
        expandedIDs == [
            "dir:src", "dir:src/nested", "src/nested/b.swift", "src/a.swift", "src/c.swift",
            "z-root.txt",
        ])

    let collapsed = GitChangeTreeBuilder.visibleRows(tree: tree, collapsedIDs: ["src"])
    #expect(collapsed.map(\.id) == ["dir:src", "z-root.txt"])
}

@Test("Numstat -z parses ordinary, binary, and rename records, attributing counts to the new path")
func gitNumstatParserParsesAllRecordShapes() {
    var payload = Data()
    payload.append(Data("0\t3\tfile1.txt".utf8))
    payload.append(0)
    payload.append(Data("-\t-\tfile.bin".utf8))
    payload.append(0)
    payload.append(Data("1\t0\t".utf8))
    payload.append(0)
    payload.append(Data("old.txt".utf8))
    payload.append(0)
    payload.append(Data("renamed.txt".utf8))
    payload.append(0)

    let stats = GitNumstatParser.parse(payload)

    #expect(stats["file1.txt"] == GitLineStats(added: 0, deleted: 3))
    #expect(stats["file.bin"] == GitLineStats(isBinary: true))
    #expect(stats["renamed.txt"] == GitLineStats(added: 1, deleted: 0))
    #expect(stats["old.txt"] == nil)
}
