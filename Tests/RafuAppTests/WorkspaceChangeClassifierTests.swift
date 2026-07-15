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

@Test("Changed directory paths are workspace-relative, keyed by parent")
func classifierComputesChangedDirectoryRelativePaths() {
    let classifier = WorkspaceChangeClassifier()

    let topLevel = classifier.classify(
        paths: ["\(root)/README.md"], rootPath: root, openDocumentPaths: [])
    #expect(topLevel.changedDirectoryRelativePaths == [""])

    let nested = classifier.classify(
        paths: ["\(root)/Sources/App/Main.swift"], rootPath: root, openDocumentPaths: [])
    #expect(nested.changedDirectoryRelativePaths == ["Sources/App"])

    let rootItself = classifier.classify(paths: [root], rootPath: root, openDocumentPaths: [])
    #expect(rootItself.changedDirectoryRelativePaths == [""])

    let noise = classifier.classify(
        paths: ["\(root)/.build/debug/junk"], rootPath: root, openDocumentPaths: [])
    #expect(noise.changedDirectoryRelativePaths.isEmpty)

    let mixed = classifier.classify(
        paths: ["\(root)/Sources/App/Main.swift", "\(root)/Sources/App/View.swift"],
        rootPath: root,
        openDocumentPaths: []
    )
    #expect(mixed.changedDirectoryRelativePaths == ["Sources/App"])
}

@Test("A large single-directory batch is a storm and clears changed directories")
func classifierDetectsStormBySurvivingPathCount() {
    let classifier = WorkspaceChangeClassifier()
    let paths = (0..<1_001).map { "\(root)/dir/f\($0).swift" }
    let changes = classifier.classify(paths: paths, rootPath: root, openDocumentPaths: [])
    #expect(changes.isStorm)
    #expect(changes.treeChanged)
    #expect(changes.changedDirectoryRelativePaths.isEmpty)
}

@Test("A batch touching many distinct directories is a storm even under the path threshold")
func classifierDetectsStormByChangedDirectoryCount() {
    let classifier = WorkspaceChangeClassifier()
    let paths = (0...200).map { "\(root)/d\($0)/f.swift" }
    let changes = classifier.classify(paths: paths, rootPath: root, openDocumentPaths: [])
    #expect(changes.isStorm)
    #expect(changes.changedDirectoryRelativePaths.isEmpty)
}

@Test("Exactly 1,000 paths in one directory is not a storm")
func classifierBoundaryNotStormBySurvivingPathCount() {
    let classifier = WorkspaceChangeClassifier()
    let paths = (0..<1_000).map { "\(root)/dir/f\($0).swift" }
    let changes = classifier.classify(paths: paths, rootPath: root, openDocumentPaths: [])
    #expect(!changes.isStorm)
    #expect(changes.changedDirectoryRelativePaths == ["dir"])
}

@Test("Exactly 200 single-file directories is not a storm")
func classifierBoundaryNotStormByChangedDirectoryCount() {
    let classifier = WorkspaceChangeClassifier()
    let paths = (0..<200).map { "\(root)/d\($0)/f.swift" }
    let changes = classifier.classify(paths: paths, rootPath: root, openDocumentPaths: [])
    #expect(!changes.isStorm)
    #expect(changes.changedDirectoryRelativePaths.count == 200)
}

@Test("A small classify result is not a storm and matches a memberwise literal")
func classifierSmallBatchIsNotStorm() {
    let classifier = WorkspaceChangeClassifier()
    let changes = classifier.classify(
        paths: ["\(root)/README.md"], rootPath: root, openDocumentPaths: [])
    #expect(!changes.isStorm)
    #expect(
        changes
            == WorkspaceChangeSet(
                treeChanged: true,
                gitChanged: false,
                changedDocumentPaths: [],
                changedDirectoryRelativePaths: [""],
                isStorm: false
            ))
}
