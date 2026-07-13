import Foundation
import Testing

@testable import RafuApp

@Test("Pure additions parse from zero-count old ranges")
func hunkParserAdditions() {
    let changes = GitGutterHunkParser.parse("@@ -0,0 +1,3 @@\n+a\n+b\n+c")
    #expect(changes.added == [1...3])
    #expect(changes.modified.isEmpty)
    #expect(changes.deletedAfter.isEmpty)
}

@Test("Modifications parse from balanced ranges, including implicit counts")
func hunkParserModifications() {
    let changes = GitGutterHunkParser.parse("@@ -5,2 +5,2 @@ context\n-x\n-y\n+x2\n+y2")
    #expect(changes.modified == [5...6])

    let implicit = GitGutterHunkParser.parse("@@ -3 +3 @@\n-a\n+b")
    #expect(implicit.modified == [3...3])
}

@Test("Deletions parse from zero-count new ranges, including line zero")
func hunkParserDeletions() {
    let changes = GitGutterHunkParser.parse("@@ -7,2 +6,0 @@\n-x\n-y")
    #expect(changes.deletedAfter == [6])

    let atTop = GitGutterHunkParser.parse("@@ -1,2 +0,0 @@\n-x\n-y")
    #expect(atTop.deletedAfter == [0])
}

@Test("Multiple hunks and non-hunk lines combine into one marker set")
func hunkParserMultipleHunks() {
    let patch = """
        diff --git a/f.swift b/f.swift
        index 1111111..2222222 100644
        --- a/f.swift
        +++ b/f.swift
        @@ -0,0 +1,2 @@
        +new
        +new
        @@ -10,1 +12,1 @@
        -old
        +changed
        @@ -20,3 +21,0 @@
        -gone
        -gone
        -gone
        """
    let changes = GitGutterHunkParser.parse(patch)
    #expect(changes.added == [1...2])
    #expect(changes.modified == [12...12])
    #expect(changes.deletedAfter == [21])
    #expect(!changes.isEmpty)
}

@Test("Empty and malformed patches yield no markers")
func hunkParserMalformed() {
    #expect(GitGutterHunkParser.parse("").isEmpty)
    #expect(GitGutterHunkParser.parse("not a diff").isEmpty)
    #expect(GitGutterHunkParser.parse("@@ broken @@").isEmpty)
    #expect(GitGutterHunkParser.parse("@@ -x,1 +1,1 @@").isEmpty)
}

@Test("Untracked files synthesize an all-added range")
func allAddedSynthesis() {
    #expect(GitGutterLineChanges.allAdded(lineCount: 3).added == [1...3])
    #expect(GitGutterLineChanges.allAdded(lineCount: 0).isEmpty)
}
