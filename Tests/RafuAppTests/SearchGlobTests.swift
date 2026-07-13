import Foundation
import Testing

@testable import RafuApp

@Test("Glob without a slash matches the last path component at any depth")
func globMatchesLastComponent() throws {
    let glob = try #require(WorkspaceSearchGlob(pattern: "*.swift"))
    #expect(glob.matches(relativePath: "Main.swift"))
    #expect(glob.matches(relativePath: "Sources/App/Main.swift"))
    #expect(!glob.matches(relativePath: "Sources/App/Main.swift.orig"))
    #expect(!glob.matches(relativePath: "notes.md"))
}

@Test("Glob with a slash matches the full relative path")
func globMatchesFullRelativePath() throws {
    let glob = try #require(WorkspaceSearchGlob(pattern: "Sources/**"))
    #expect(glob.matches(relativePath: "Sources/App/Main.swift"))
    #expect(glob.matches(relativePath: "Sources/Main.swift"))
    #expect(!glob.matches(relativePath: "Tests/AppTests/MainTests.swift"))
    #expect(!glob.matches(relativePath: "Sources"))
}

@Test("Single star stays within one path component")
func globSingleStarDoesNotCrossSlashes() throws {
    let glob = try #require(WorkspaceSearchGlob(pattern: "Sources/*.swift"))
    #expect(glob.matches(relativePath: "Sources/Main.swift"))
    #expect(!glob.matches(relativePath: "Sources/App/Main.swift"))
}

@Test("Leading **/ also matches zero directories")
func globDoubleStarSlashMatchesZeroDirectories() throws {
    let glob = try #require(WorkspaceSearchGlob(pattern: "**/Tests/*.swift"))
    #expect(glob.matches(relativePath: "Tests/MainTests.swift"))
    #expect(glob.matches(relativePath: "Packages/Kit/Tests/KitTests.swift"))
    #expect(!glob.matches(relativePath: "Tests/Nested/MainTests.swift"))
}

@Test("Question mark matches exactly one non-slash character")
func globQuestionMark() throws {
    let glob = try #require(WorkspaceSearchGlob(pattern: "file?.txt"))
    #expect(glob.matches(relativePath: "file1.txt"))
    #expect(!glob.matches(relativePath: "file12.txt"))
    #expect(!glob.matches(relativePath: "file/.txt"))
}

@Test("Regex metacharacters in globs are treated literally")
func globEscapesRegexMetacharacters() throws {
    let glob = try #require(WorkspaceSearchGlob(pattern: "release+(1).txt"))
    #expect(glob.matches(relativePath: "release+(1).txt"))
    #expect(!glob.matches(relativePath: "releasee(1).txt"))

    let dotGlob = try #require(WorkspaceSearchGlob(pattern: "*.md"))
    #expect(!dotGlob.matches(relativePath: "READMEmd"))
}

@Test("Blank patterns do not compile")
func globRejectsBlankPatterns() {
    #expect(WorkspaceSearchGlob(pattern: "") == nil)
    #expect(WorkspaceSearchGlob(pattern: "   ") == nil)
}
