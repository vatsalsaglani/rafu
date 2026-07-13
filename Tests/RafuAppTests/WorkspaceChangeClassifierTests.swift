import Foundation
import Testing

@testable import RafuApp

private let root = "/workspace/project"

@Test("Only .git HEAD and index changes count as Git changes")
func classifierFiltersGitInternals() {
    let classifier = WorkspaceChangeClassifier()

    let head = classifier.classify(
        paths: ["\(root)/.git/HEAD"], rootPath: root, openDocumentPaths: [])
    #expect(head == WorkspaceChangeSet(treeChanged: false, gitChanged: true))

    let index = classifier.classify(
        paths: ["\(root)/.git/index"], rootPath: root, openDocumentPaths: [])
    #expect(index.gitChanged)
    #expect(!index.treeChanged)

    let internals = classifier.classify(
        paths: [
            "\(root)/.git/objects/ab/cdef0123",
            "\(root)/.git/index.lock",
            "\(root)/.git/refs/heads/main",
            "\(root)/.git",
        ],
        rootPath: root,
        openDocumentPaths: []
    )
    #expect(internals.isEmpty)
}

@Test("Noise directories and .DS_Store are dropped entirely")
func classifierDropsNoisePaths() {
    let classifier = WorkspaceChangeClassifier()
    let changes = classifier.classify(
        paths: [
            "\(root)/.build/debug/App.o",
            "\(root)/node_modules/pkg/index.js",
            "\(root)/DerivedData/Log.txt",
            "\(root)/.swiftpm/xcode/settings",
            "\(root)/dist/bundle.js",
            "\(root)/.DS_Store",
            "\(root)/Sources/.DS_Store",
        ],
        rootPath: root,
        openDocumentPaths: []
    )
    #expect(changes.isEmpty)
}

@Test("Workspace file changes mark the tree and hit open documents")
func classifierFlagsTreeAndOpenDocuments() {
    let classifier = WorkspaceChangeClassifier()
    let openPath = "\(root)/Sources/Main.swift"
    let changes = classifier.classify(
        paths: ["\(root)/Sources/Main.swift", "\(root)/README.md"],
        rootPath: root,
        openDocumentPaths: [openPath]
    )
    #expect(changes.treeChanged)
    #expect(!changes.gitChanged)
    #expect(changes.changedDocumentPaths == [openPath])
}

@Test("Paths outside the root are ignored; mixed batches combine flags")
func classifierHandlesMixedBatches() {
    let classifier = WorkspaceChangeClassifier()
    let openPath = "\(root)/Notes.md"
    let changes = classifier.classify(
        paths: [
            "/somewhere/else/file.txt",
            "\(root)/.git/HEAD",
            "\(root)/.build/debug/junk",
            "\(root)/Notes.md",
            root,
            "\(root)/Sources/",
        ],
        rootPath: root,
        openDocumentPaths: [openPath]
    )
    #expect(changes.treeChanged)
    #expect(changes.gitChanged)
    #expect(changes.changedDocumentPaths == [openPath])
}
