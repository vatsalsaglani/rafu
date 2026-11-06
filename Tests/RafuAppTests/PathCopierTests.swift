import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Path copier")
struct PathCopierTests {
    private let app = WorkspaceRoot(path: "/Users/me/app")
    private let lib = WorkspaceRoot(path: "/Users/me/lib")

    @Test("One root: relative to the root, with no label")
    func singleRoot() {
        let url = URL(filePath: "/Users/me/app/Sources/main.swift")
        #expect(PathCopier.path(for: url, style: .relative, roots: [app]) == "Sources/main.swift")
        #expect(
            PathCopier.path(for: url, style: .absolute, roots: [app])
                == "/Users/me/app/Sources/main.swift")
    }

    @Test("Several roots: the root label goes in front")
    func multiRootLabel() {
        let url = URL(filePath: "/Users/me/lib/a.swift")
        #expect(PathCopier.path(for: url, style: .relative, roots: [app, lib]) == "lib/a.swift")
    }

    @Test("A path outside every root falls back to the absolute path")
    func outsideRoots() {
        let url = URL(filePath: "/tmp/notes.txt")
        #expect(PathCopier.path(for: url, style: .relative, roots: [app]) == "/tmp/notes.txt")
    }

    @Test("Several paths go one per line")
    func severalPaths() {
        let urls = [
            URL(filePath: "/Users/me/app/a.txt"), URL(filePath: "/Users/me/app/b/c.txt"),
        ]
        #expect(PathCopier.paths(for: urls, style: .relative, roots: [app]) == "a.txt\nb/c.txt")
    }

    @Test("Target: a file-backed document, else the tree, never an untitled document")
    func target() {
        let document = URL(filePath: "/Users/me/app/a.txt")
        #expect(
            PathCopier.target(
                documentURL: document, documentIsUntitled: false, treePath: "/Users/me/app/b",
                treeHasFocus: false) == document)
        #expect(
            PathCopier.target(
                documentURL: document, documentIsUntitled: false, treePath: "/Users/me/app/b",
                treeHasFocus: true) == URL(filePath: "/Users/me/app/b"))
        #expect(
            PathCopier.target(
                documentURL: document, documentIsUntitled: true, treePath: nil,
                treeHasFocus: false) == nil)
        #expect(
            PathCopier.target(
                documentURL: nil, documentIsUntitled: false, treePath: nil, treeHasFocus: true)
                == nil)
    }
}

/// ⇧⌘C and ⌥⌘C are app-wide menu key equivalents. A second binding of
/// either would make one of them unreachable, so each appears exactly once.
@Suite("Copy Path key equivalents")
struct CopyPathShortcutContractTests {
    @Test("⇧⌘C and ⌥⌘C are each bound exactly once in RafuApp")
    func boundOnce() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/RafuApp", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        var text = ""
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            text += try String(contentsOf: sources.appending(path: relative), encoding: .utf8)
        }
        func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
        #expect(count(#"keyboardShortcut("c", modifiers: [.command, .shift])"#) == 1)
        #expect(count(#"keyboardShortcut("c", modifiers: [.shift, .command])"#) == 0)
        #expect(count(#"keyboardShortcut("c", modifiers: [.command, .option])"#) == 1)
        #expect(count(#"keyboardShortcut("c", modifiers: [.option, .command])"#) == 0)
    }
}
