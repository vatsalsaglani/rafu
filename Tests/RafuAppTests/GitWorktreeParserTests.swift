import Foundation
import Testing

@testable import RafuApp

@Suite("Git worktree porcelain parser")
struct GitWorktreeParserTests {
    @Test("Parses main plus linked worktrees with branch short names")
    func parsesBranches() {
        let output = """
            worktree /repo
            HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            branch refs/heads/main

            worktree /repo/../lane-a
            HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            branch refs/heads/lane/multi-cursor

            """
        let worktrees = GitWorktreeParser.parse(output)
        #expect(worktrees.count == 2)
        #expect(worktrees[0].isMain)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[0].shortHead == "aaaaaaaa")
        #expect(worktrees[1].isMain == false)
        #expect(worktrees[1].branch == "lane/multi-cursor")
        #expect(worktrees[1].name == "lane-a")
    }

    @Test("Marks detached, locked, prunable, and bare states")
    func parsesFlags() {
        let output = """
            worktree /repo
            HEAD cccccccccccccccccccccccccccccccccccccccc
            bare

            worktree /repo/detached
            HEAD dddddddddddddddddddddddddddddddddddddddd
            detached

            worktree /repo/locked
            HEAD eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
            branch refs/heads/wip
            locked claude session (pid 123)

            worktree /repo/gone
            HEAD ffffffffffffffffffffffffffffffffffffffff
            branch refs/heads/old
            prunable gitdir file points to non-existent location

            """
        let worktrees = GitWorktreeParser.parse(output)
        #expect(worktrees.count == 4)
        #expect(worktrees[0].isBare)
        #expect(worktrees[1].isDetached)
        #expect(worktrees[1].branch == nil)
        #expect(worktrees[2].isLocked)
        #expect(worktrees[2].lockReason == "claude session (pid 123)")
        #expect(worktrees[3].isPrunable)
    }

    @Test("Tolerates CRLF and a trailing blank record")
    func toleratesWhitespace() {
        let output =
            "worktree /repo\r\nHEAD 1111111111111111111111111111111111111111\r\nbranch refs/heads/main\r\n\r\n"
        let worktrees = GitWorktreeParser.parse(output)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].branch == "main")
    }

    @Test("Empty output yields no worktrees")
    func emptyOutput() {
        #expect(GitWorktreeParser.parse("").isEmpty)
        #expect(GitWorktreeParser.parse("\n\n").isEmpty)
    }
}
