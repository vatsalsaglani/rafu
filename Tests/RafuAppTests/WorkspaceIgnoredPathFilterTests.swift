import Foundation
import Testing

@testable import RafuApp

@Suite("Ignored FSEvents path filter")
struct WorkspaceIgnoredPathFilterTests {
    @Test("A plan asks about each path and its parent folders, once each")
    func planQueriesPathsAndParents() {
        let plan = WorkspaceIgnoredPathFilter().plan(
            candidates: [".venv/lib/a.py", ".venv/lib/b.py", "README.md"],
            nestedRepositories: [])
        #expect(plan.knownIgnored.isEmpty)
        #expect(plan.groups.count == 1)
        let group = plan.groups[0]
        #expect(group.repositoryRelativePath == "")
        #expect(group.paths == [".venv/lib/a.py", ".venv/lib/b.py", "README.md"])
        #expect(group.directories == [".venv/lib", ".venv"])
    }

    @Test("Paths inside a nested repository form its own group")
    func planGroupsNestedRepositories() {
        let plan = WorkspaceIgnoredPathFilter().plan(
            candidates: ["child/tmp/x.txt", "child", "src/a.swift"],
            nestedRepositories: ["child"])
        #expect(plan.groups.map(\.repositoryRelativePath) == ["child", ""])
        #expect(plan.groups[0].paths == ["child/tmp/x.txt"])
        // The nested folder itself is asked about by the outer repository.
        #expect(plan.groups[0].directories == ["child/tmp"])
        #expect(plan.groups[1].paths == ["child", "src/a.swift"])
        #expect(plan.groups[1].directories == ["src"])
    }

    @Test("Remembered paths and clean folders need no process")
    func rememberedAnswersSkipQueries() {
        var filter = WorkspaceIgnoredPathFilter()
        filter.learn(.init(ignoredPaths: ["server.log"], cleanIgnoredDirectories: [".next"]))
        #expect(filter.isKnownIgnored("server.log"))
        #expect(filter.isKnownIgnored(".next"))
        #expect(filter.isKnownIgnored(".next/cache/a.js"))
        #expect(!filter.isKnownIgnored(".nextjs/a.js"))
        #expect(!filter.isKnownIgnored("src/server.log"))

        let plan = filter.plan(
            candidates: ["server.log", ".next/cache/a.js", "src/a.swift"],
            nestedRepositories: [])
        #expect(plan.knownIgnored == ["server.log", ".next/cache/a.js"])
        #expect(plan.groups.flatMap(\.paths) == ["src/a.swift"])

        filter.reset()
        #expect(!filter.isKnownIgnored("server.log"))
    }

    @Test("Only known answers apply when a batch is too large to ask about")
    func oversizedBatchFailsOpen() {
        let candidates = (0...WorkspaceIgnoredPathFilter.maximumQueryPaths).map { "f\($0)" }
        let plan = WorkspaceIgnoredPathFilter().plan(
            candidates: candidates, nestedRepositories: [])
        #expect(plan.groups.isEmpty)
        #expect(plan.knownIgnored.isEmpty)
    }

    @Test("The memory is cleared, not grown, above its bound")
    func memoryIsBounded() {
        var filter = WorkspaceIgnoredPathFilter()
        let many = Set((0..<WorkspaceIgnoredPathFilter.maximumRememberedEntries).map { "f\($0)" })
        filter.learn(.init(ignoredPaths: many))
        #expect(filter.ignoredPaths.count == many.count)
        filter.learn(.init(ignoredPaths: ["extra"]))
        #expect(filter.ignoredPaths == ["extra"])
    }

    @Test("Outermost folders, check-ignore output, and tracked files")
    func pureHelpers() {
        #expect(
            WorkspaceIgnoredPathFilter.outermost([".venv", ".venv/lib", "tmp", "a/b"], limit: 8)
                == [".venv", "a/b", "tmp"])
        #expect(WorkspaceIgnoredPathFilter.outermost(["a", "b", "c"], limit: 2) == ["a", "b"])
        #expect(
            WorkspaceIgnoredPathFilter.parseReportedPaths(
                Data("tmp/x\0b.log\0".utf8), repositoryRelativePath: "child")
                == ["child/tmp/x", "child/b.log"])
        #expect(
            WorkspaceIgnoredPathFilter.directoriesWithoutTrackedFiles(
                [".logs", "tmp"], trackedPaths: [".logs/keep", "tmpfile"])
                == ["tmp"])
    }

    @Test("Git answers for a real repository, nested repository, and tracked file")
    func resolveAgainstGit() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "rafu-ignore-filter-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let fileManager = FileManager.default
        for folder in [".venv/lib", ".logs", "src", "child/build"] {
            try fileManager.createDirectory(
                at: base.appending(path: folder), withIntermediateDirectories: true)
        }
        try ignoreFixtureGit(["init", "-q"], at: base)
        try ".venv/\n*.log\n.logs/\n".write(
            to: base.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        for file in [".venv/lib/a.py", ".logs/keep", ".logs/run", "src/a.swift", "src/b.log"] {
            try "x\n".write(to: base.appending(path: file), atomically: true, encoding: .utf8)
        }
        try ignoreFixtureGit(["add", "-f", ".logs/keep"], at: base)
        let child = base.appending(path: "child")
        try ignoreFixtureGit(["init", "-q"], at: child)
        try "build/\n".write(
            to: child.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "x\n".write(
            to: child.appending(path: "build/out.o"), atomically: true, encoding: .utf8)
        try "x\n".write(to: child.appending(path: "main.c"), atomically: true, encoding: .utf8)

        let filter = WorkspaceIgnoredPathFilter()
        let plan = filter.plan(
            candidates: [
                ".venv/lib/a.py", ".logs/keep", ".logs/run", "src/a.swift", "src/b.log",
                "child/build/out.o", "child/main.c",
            ],
            nestedRepositories: ["child"])
        let result = await WorkspaceIgnoredPathFilter.resolve(plan, rootPath: base.path)

        #expect(
            result.ignoredPaths
                == [".venv/lib/a.py", ".logs/run", "src/b.log", "child/build/out.o"])
        // `.logs` holds a tracked file, so it is not remembered as a folder.
        #expect(result.cleanIgnoredDirectories == [".venv", "child/build"])
    }

    @Test("A folder outside any Git work tree is not filtered")
    func resolveOutsideGit() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "rafu-ignore-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let plan = WorkspaceIgnoredPathFilter().plan(
            candidates: ["a.log"], nestedRepositories: [])
        let result = await WorkspaceIgnoredPathFilter.resolve(plan, rootPath: base.path)
        #expect(result == .init())
    }
}

private func ignoreFixtureGit(_ arguments: [String], at root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IgnoreFixtureError.gitFailed(arguments)
    }
}

private enum IgnoreFixtureError: Error {
    case gitFailed([String])
}
