import Foundation
import Testing

@testable import RafuApp

private let root = "/workspace/project"

@Test("Only .git HEAD, index, and ref changes count as Git changes")
func classifierFiltersGitInternals() {
    let classifier = WorkspaceChangeClassifier()

    let head = classifier.classify(
        paths: ["\(root)/.git/HEAD"], rootPath: root, openDocumentPaths: [])
    #expect(head == WorkspaceChangeSet(treeChanged: false, gitChanged: true))

    let index = classifier.classify(
        paths: ["\(root)/.git/index"], rootPath: root, openDocumentPaths: [])
    #expect(index.gitChanged)
    #expect(!index.treeChanged)

    for ref in ["refs/heads/main", "refs/remotes/origin/main", "refs/tags/v1", "packed-refs"] {
        let changes = classifier.classify(
            paths: ["\(root)/.git/\(ref)"], rootPath: root, openDocumentPaths: [])
        #expect(changes == WorkspaceChangeSet(gitChanged: true), "\(ref)")
    }

    let internals = classifier.classify(
        paths: [
            "\(root)/.git/objects/ab/cdef0123",
            "\(root)/.git/index.lock",
            "\(root)/.git/refs/heads/main.lock",
            "\(root)/.git/logs/HEAD",
            "\(root)/.git/info/exclude",
            "\(root)/.git",
        ],
        rootPath: root,
        openDocumentPaths: []
    )
    #expect(internals.isEmpty)
}

@Test("A nested repository's own .git changes are reported by folder")
func classifierReportsNestedRepositoryGitChanges() {
    let classifier = WorkspaceChangeClassifier()
    let changes = classifier.classify(
        paths: [
            "\(root)/child/.git/HEAD",
            "\(root)/child/.git/objects/ab/cd",
            "\(root)/other/.git/refs/heads/main.lock",
        ],
        rootPath: root,
        openDocumentPaths: []
    )
    #expect(changes.nestedGitChangedDirectories == ["child"])
    #expect(!changes.treeChanged)
    #expect(!changes.gitChanged)
}

@Test("Ignored paths re-list only their folder and never mark the tree changed")
func classifierSeparatesIgnoredPaths() {
    let classifier = WorkspaceChangeClassifier()
    let openLog = "\(root)/.logs/run.log"
    let ignoredOnly = classifier.classify(
        paths: [openLog, "\(root)/.venv/lib/a.py"],
        rootPath: root,
        openDocumentPaths: [openLog],
        isIgnored: { $0.hasPrefix(".logs/") || $0.hasPrefix(".venv/") }
    )
    #expect(!ignoredOnly.treeChanged)
    #expect(ignoredOnly.changedDirectoryRelativePaths.isEmpty)
    #expect(ignoredOnly.ignoredDirectoryRelativePaths == [".logs", ".venv/lib"])
    #expect(ignoredOnly.changedDocumentPaths == [openLog])
    #expect(!ignoredOnly.isEmpty)

    let mixed = classifier.classify(
        paths: ["\(root)/src/a.swift", "\(root)/src/b.log"],
        rootPath: root,
        openDocumentPaths: [],
        isIgnored: { $0.hasSuffix(".log") }
    )
    #expect(mixed.treeChanged)
    #expect(mixed.changedDirectoryRelativePaths == ["src"])
    // The folder is re-listed through the tree change already.
    #expect(mixed.ignoredDirectoryRelativePaths.isEmpty)
}

@Test("Ignored paths do not count toward a storm")
func classifierIgnoredPathsAreNotAStorm() {
    let classifier = WorkspaceChangeClassifier()
    let paths = (0..<2_000).map { "\(root)/.next/cache/f\($0).js" }
    let changes = classifier.classify(
        paths: paths, rootPath: root, openDocumentPaths: [],
        isIgnored: { $0.hasPrefix(".next/") })
    #expect(!changes.isStorm)
    #expect(!changes.treeChanged)
    #expect(changes.ignoredDirectoryRelativePaths == [".next/cache"])
}

@Test("Candidates skip noise and .git paths and keep batch order once each")
func classifierCandidatePaths() {
    let classifier = WorkspaceChangeClassifier()
    let candidates = classifier.candidateRelativePaths(
        paths: [
            "\(root)/src/a.swift", "\(root)/.git/HEAD", "\(root)/child/.git/index",
            "\(root)/node_modules/x.js", "\(root)/src/a.swift", "\(root)/.venv/",
            root, "/elsewhere/file",
        ],
        rootPath: root)
    #expect(candidates == ["src/a.swift", ".venv"])
}

@Test("Ignore rules change with a .gitignore or info/exclude")
func classifierDetectsIgnoreRuleChanges() {
    let classifier = WorkspaceChangeClassifier()
    #expect(
        classifier.ignoreRulesMayHaveChanged(
            paths: ["\(root)/src/.gitignore"], rootPath: root))
    #expect(
        classifier.ignoreRulesMayHaveChanged(
            paths: ["\(root)/.git/info/exclude"], rootPath: root))
    #expect(
        classifier.ignoreRulesMayHaveChanged(
            paths: ["\(root)/child/.git/info/exclude"], rootPath: root))
    #expect(
        !classifier.ignoreRulesMayHaveChanged(
            paths: ["\(root)/src/a.swift", "\(root)/.git/index"], rootPath: root))
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
