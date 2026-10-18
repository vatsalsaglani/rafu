import Foundation
import Testing

@testable import RafuApp

@Suite("Git panel presentation")
struct GitPanelPresentationTests {
    // MARK: Relative time (G6, G10)

    @Test("Relative time shows seconds only in the first minute")
    func relativeTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func label(_ secondsAgo: TimeInterval) -> String {
            GitRelativeTime.label(for: now.addingTimeInterval(-secondsAgo), now: now)
        }
        #expect(label(0) == "just now")
        #expect(label(9) == "just now")
        #expect(label(10) == "10 sec ago")
        #expect(label(59) == "59 sec ago")
        #expect(label(60) == "1 min ago")
        #expect(label(146) == "2 min ago")  // "2 min, 26 sec" in the old UI
        #expect(label(3_599) == "59 min ago")
        #expect(label(3_600) == "1 h ago")
        #expect(label(2 * 3_600 + 40) == "2 h ago")
        #expect(label(86_400) == "1 d ago")
        #expect(label(6 * 86_400) == "6 d ago")
        #expect(label(7 * 86_400) == "1 w ago")
        #expect(label(30 * 86_400) == "1 mo ago")
        #expect(label(365 * 86_400) == "1 y ago")
    }

    @Test("A date in the future never shows a negative time")
    func relativeTimeFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(GitRelativeTime.label(for: now.addingTimeInterval(500), now: now) == "just now")
    }

    // MARK: Sync control (G4, G15)

    @Test("Sync label shows ahead and behind counts when an upstream exists")
    func syncTracking() {
        let sync = GitSyncPresentation.resolve(
            hasRemote: true, upstream: "origin/main", aheadCount: 2, behindCount: 1)
        #expect(sync.state == .tracking)
        #expect(sync.label == "↑2 ↓1")
        #expect(sync.canSync)
        let even = GitSyncPresentation.resolve(
            hasRemote: true, upstream: "origin/main", aheadCount: 0, behindCount: 0)
        #expect(even.label == "↑0 ↓0")
    }

    @Test("Without a remote the sync control is a neutral capsule and sync is disabled")
    func syncNoRemote() {
        let sync = GitSyncPresentation.resolve(
            hasRemote: false, upstream: nil, aheadCount: 0, behindCount: 0)
        #expect(sync.state == .noRemote)
        #expect(sync.label == "No remote")
        #expect(!sync.canSync)
        #expect(GitSyncPresentation.noRemoteHelp == "This repository has no remote.")
    }

    @Test("A remote without an upstream branch can still sync")
    func syncNoUpstream() {
        let sync = GitSyncPresentation.resolve(
            hasRemote: true, upstream: nil, aheadCount: 3, behindCount: 3)
        #expect(sync.state == .noUpstream)
        #expect(sync.label == "No upstream")
        #expect(sync.canSync)
        // Counts are meaningless without an upstream.
        #expect(sync.aheadCount == 0)
        #expect(sync.behindCount == 0)
    }

    // MARK: Section picker (G1)

    @Test("Section order is Changes, History, Worktrees, with the change count")
    func sectionLabels() {
        #expect(GitInspectorSection.allCases.map(\.title) == ["Changes", "History", "Worktrees"])
        #expect(GitInspectorSection.changes.segmentLabel(changeCount: 4) == "Changes (4)")
        #expect(GitInspectorSection.changes.segmentLabel(changeCount: 0) == "Changes")
        #expect(GitInspectorSection.history.segmentLabel(changeCount: 4) == "History")
        #expect(GitInspectorSection.worktrees.segmentLabel(changeCount: 4) == "Worktrees")
    }

    @Test("The section picker switches to icons below 320 pt")
    func sectionPickerIconThreshold() {
        #expect(GitSectionPickerLayout.usesIcons(forWidth: 300))
        #expect(GitSectionPickerLayout.usesIcons(forWidth: 319.5))
        #expect(!GitSectionPickerLayout.usesIcons(forWidth: 320))
        #expect(!GitSectionPickerLayout.usesIcons(forWidth: 340))
    }

    @Test("View as offers List and Tree")
    func viewAsTitles() {
        #expect(GitChangesViewMode.allCases.map(\.title) == ["List", "Tree"])
    }

    // MARK: File rows (G2)

    @Test("A file at the repository root has no folder")
    func rootFileHasNoFolder() {
        let parts = GitChangePathParts(path: "README.md")
        #expect(parts.name == "README.md")
        #expect(parts.folder == nil)
    }

    @Test("A nested file splits into name and folder")
    func nestedFileSplits() {
        let parts = GitChangePathParts(path: "Sources/RafuApp/Views/Root.swift")
        #expect(parts.name == "Root.swift")
        #expect(parts.folder == "Sources/RafuApp/Views")
    }

    // MARK: Composer (G7)

    @Test("The commit caption counts staged files")
    func commitCaption() {
        #expect(GitCommitCaption.text(stagedCount: 0) == "Nothing staged")
        #expect(GitCommitCaption.text(stagedCount: 1) == "Commits 1 file")
        #expect(GitCommitCaption.text(stagedCount: 2) == "Commits 2 files")
    }

    // MARK: History (G10, G11)

    @Test("Ref decorations become plain chips without an ASCII arrow")
    func refChips() {
        let chips = GitRefLabels.chips(from: [
            "HEAD -> main", "origin/main", "tag: v1.0", "origin/HEAD",
        ])
        #expect(chips == ["HEAD", "main", "origin/main", "v1.0", "origin/HEAD"])
        #expect(!chips.contains { $0.contains("->") })
    }

    @Test("Duplicate and empty decorations are dropped")
    func refChipsDeduplicate() {
        #expect(GitRefLabels.chips(from: ["HEAD", "", "HEAD"]) == ["HEAD"])
        #expect(GitRefLabels.chips(from: []).isEmpty)
    }

    @Test("A full hash splits by character count with no hyphen and rejoins exactly")
    func hashLines() {
        let hash = "8be02b5fd3f3fc02a1b2c3d4e5f60718293a4b5c"
        let lines = GitHashDisplay.lines(for: hash)
        #expect(lines.count == 2)
        #expect(lines.joined() == hash)
        #expect(lines.allSatisfy { !$0.contains("-") && $0.count <= 20 })
        #expect(GitHashDisplay.lines(for: "").isEmpty)
        #expect(GitHashDisplay.lines(for: "abc") == ["abc"])
    }

    // MARK: Diff header (G8)

    @Test("The diff header names the real comparison for each scope")
    func comparisonLabels() {
        #expect(
            GitDiffHeaderPresentation.comparisonLabel(for: .workingTree) == "Working Tree ↔ Index")
        #expect(GitDiffHeaderPresentation.comparisonLabel(for: .staged) == "Index ↔ HEAD")
        #expect(
            GitDiffHeaderPresentation.comparisonLabel(
                for: .commit("8be02b5fd3f3fc02a1b2c3d4e5f60718293a4b5c")) == "8be02b5f ↔ Parent")
        #expect(
            GitDiffHeaderPresentation.comparisonLabel(
                for: .between(base: "aaaaaaaa11", head: "bbbbbbbb22"))
                == "bbbbbbbb ↔ aaaaaaaa")
    }

    @Test("The breadcrumb keeps the last components and collapses leading folders")
    func breadcrumb() {
        #expect(GitDiffHeaderPresentation.breadcrumb(for: "Demo.swift") == ["Demo.swift"])
        #expect(
            GitDiffHeaderPresentation.breadcrumb(for: "Sources/App/Demo.swift")
                == ["Sources", "App", "Demo.swift"])
        #expect(
            GitDiffHeaderPresentation.breadcrumb(for: "a/b/c/d/e/Demo.swift")
                == ["…", "d", "e", "Demo.swift"])
    }

    @Test("Diff line counts include modification rows on both sides")
    func lineCounts() {
        func line(_ number: Int, _ kind: GitDiffLineKind) -> GitDiffLine {
            GitDiffLine(number: number, content: "x", kind: kind)
        }
        let rows = [
            GitDiffRow(
                id: 0, oldLine: line(1, .context), newLine: line(1, .context), kind: .context),
            GitDiffRow(
                id: 1, oldLine: line(2, .deletion), newLine: line(2, .addition), kind: .modification
            ),
            GitDiffRow(id: 2, oldLine: nil, newLine: line(3, .addition), kind: .addition),
            GitDiffRow(id: 3, oldLine: line(4, .deletion), newLine: nil, kind: .deletion),
        ]
        let hunk = GitDiffHunk(
            id: 0, header: "@@ -1,4 +1,3 @@", oldStart: 1, oldCount: 4, newStart: 1,
            newCount: 3, rows: rows)
        let diff = GitFileDiff(
            path: "Demo.swift", originalPath: nil, isBinary: false, hunks: [hunk], rawPatch: "")
        let counts = GitDiffHeaderPresentation.lineCounts(for: diff)
        #expect(counts == GitDiffLineCounts(added: 2, deleted: 2))
    }
}
