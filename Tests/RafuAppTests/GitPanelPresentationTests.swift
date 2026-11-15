import AppKit
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
        #expect(GitInspectorSection.changes.segmentLabel(changeCount: 4) == "Changes 4")
        #expect(GitInspectorSection.changes.segmentLabel(changeCount: 0) == "Changes")
        #expect(GitInspectorSection.history.segmentLabel(changeCount: 4) == "History")
        #expect(GitInspectorSection.worktrees.segmentLabel(changeCount: 4) == "Worktrees")
    }

    /// The fixed 320 pt threshold put the picker on icons at every normal
    /// sidebar width. The shared picker now tries the words first and uses
    /// the icons only when the words do not fit.
    @Test("Every section has a real SF Symbol for the narrow fallback")
    func sectionPickerIconFallback() {
        for section in GitInspectorSection.allCases {
            #expect(
                NSImage(systemSymbolName: section.symbolName, accessibilityDescription: nil)
                    != nil)
        }
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

    // Composer (G7): see `GitCommitComposerPresentationTests` below.

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

    @Test("Full decorations give the same chips as short ones")
    func refChipsFromFullDecorations() {
        let chips = GitRefLabels.chips(from: [
            "HEAD -> refs/heads/main", "refs/remotes/origin/main", "tag: refs/tags/v1.0",
            "refs/remotes/origin/HEAD",
        ])
        #expect(chips == ["HEAD", "main", "origin/main", "v1.0", "origin/HEAD"])
    }

    @Test("Typed ref labels classify head, local, remote, and tag refs in display order")
    func typedRefLabels() {
        let labels = GitRefLabels.labels(from: [
            "tag: refs/tags/v1.0", "refs/remotes/origin/main", "HEAD -> refs/heads/main",
            "refs/heads/feature/x", "refs/remotes/origin/HEAD", "refs/heads/feature/x", "",
        ])
        #expect(
            labels == [
                GitRefLabel(kind: .head, name: "main"),
                GitRefLabel(kind: .local, name: "feature/x"),
                GitRefLabel(kind: .remote, name: "origin/main"),
                GitRefLabel(kind: .tag, name: "v1.0"),
            ])
        #expect(GitRefLabels.labels(from: ["HEAD"]) == [GitRefLabel(kind: .head, name: "HEAD")])
        // Short decorations still parse; an unprefixed name is a local branch.
        #expect(
            GitRefLabels.labels(from: ["HEAD -> main", "tag: v2"]) == [
                GitRefLabel(kind: .head, name: "main"), GitRefLabel(kind: .tag, name: "v2"),
            ])
        #expect(GitRefLabels.labels(from: []).isEmpty)
    }

    @Test("Commit stats read like Git's summary, with singular forms")
    func commitStatsText() {
        let detail = GitCommitDetail(body: "", filesChanged: 2, insertions: 5, deletions: 1)
        #expect(
            GitCommitStatsPresentation.summary(for: detail)
                == "2 files changed, 5 insertions(+), 1 deletion(-)")
        #expect(GitCommitStatsPresentation.filesText(1) == "1 file changed")
        #expect(GitCommitStatsPresentation.insertionsText(1) == "1 insertion(+)")
        #expect(GitCommitStatsPresentation.deletionsText(0) == "0 deletions(-)")
    }

    @Test("The card body drops the subject line and surrounding blank lines")
    func bodyWithoutSubject() {
        #expect(GitCommitStatsPresentation.bodyWithoutSubject("Subject") == "")
        #expect(
            GitCommitStatsPresentation.bodyWithoutSubject("Subject\n\nLine 1\nLine 2\n")
                == "Line 1\nLine 2")
    }

    // MARK: Commit message reflow (history round 5)

    @Test("Hard-wrapped lines join within a paragraph; a blank line splits paragraphs")
    func reflowJoinsParagraphLines() {
        let body = """
            This module uploads raw runtime evidence to S3 as soon as it
            is written, so a separate worker can build overlays.


            Second paragraph
            continues here.
            """
        #expect(
            GitCommitMessageReflow.reflow(body)
                == "This module uploads raw runtime evidence to S3 as soon as it is written,"
                + " so a separate worker can build overlays.\n\nSecond paragraph continues here.")
    }

    @Test("List items start new lines; a wrapped item's indented line joins it")
    func reflowKeepsListItems() {
        let body = """
            Changes:
            - Deck depth: inset 12, shadow 0.55 dark,
              and a 1 pt inner top highlight.
            - Corner wedges repaint the frame.
            * Star item
            • Bullet item
            1. First
            12) Twelfth
            """
        #expect(
            GitCommitMessageReflow.reflow(body)
                == """
                Changes:
                - Deck depth: inset 12, shadow 0.55 dark, and a 1 pt inner top highlight.
                - Corner wedges repaint the frame.
                * Star item
                • Bullet item
                1. First
                12) Twelfth
                """)
    }

    @Test("Fenced and indented code stay line for line")
    func reflowKeepsCode() {
        let fenced = "Run this:\n```\nlet a = 1\n  let b = 2\n\n```\nAfter the fence\nwraps."
        #expect(
            GitCommitMessageReflow.reflow(fenced)
                == "Run this:\n```\nlet a = 1\n  let b = 2\n\n```\nAfter the fence wraps.")

        let indented = "Commands:\n\n    swift build\n    swift test\nnext\n\tTabbed line"
        #expect(
            GitCommitMessageReflow.reflow(indented)
                == "Commands:\n\n    swift build\n    swift test\nnext\n\tTabbed line")
    }

    @Test("Trailer lines stay on their own lines; a colon in prose still joins")
    func reflowKeepsTrailers() {
        let body = """
            Note: the rewrite keeps
            the old order.

            Co-Authored-By: Someone <someone@example.com>
            Claude-Session: https://example.com/session
            """
        #expect(
            GitCommitMessageReflow.reflow(body)
                == """
                Note: the rewrite keeps the old order.

                Co-Authored-By: Someone <someone@example.com>
                Claude-Session: https://example.com/session
                """)
    }

    @Test("CRLF, trailing spaces, and outer blank lines are normalized")
    func reflowNormalizesWhitespace() {
        #expect(GitCommitMessageReflow.reflow("\r\nOne  \r\ntwo\r\n\r\n") == "One two")
        #expect(GitCommitMessageReflow.reflow("") == "")
    }

    @Test("A commit detail carries its reflowed body without the subject")
    func detailDisplayBody() {
        let detail = GitCommitDetail(
            body: "Subject line\n\nFirst wrapped\nline.\n\n- item", filesChanged: 1,
            insertions: 1, deletions: 0)
        #expect(detail.displayBody == "First wrapped line.\n\n- item")
        #expect(
            GitCommitDetail(body: "Only a subject", filesChanged: 0, insertions: 0, deletions: 0)
                .displayBody == "")
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

// MARK: - Commit composer (G7, Option B)

@Suite("Git commit composer presentation")
struct GitCommitComposerPresentationTests {
    private func presentation(
        message: String = "",
        staged: Int = 0,
        stageable: Int = 0,
        branch: String? = "main",
        merge: Bool = false,
        drafting: Bool = false,
        busy: Bool = false,
        descriptionFocused: Bool = false
    ) -> GitCommitComposerPresentation {
        GitCommitComposerPresentation(
            .init(
                message: message, stagedCount: staged, stageableCount: stageable, branch: branch,
                isMergeInProgress: merge, isDrafting: drafting, isBusy: busy,
                isDescriptionFocused: descriptionFocused))
    }

    // MARK: Split and join

    @Test("A summary and a description round-trip through one message")
    func roundTrip() {
        let parts = GitCommitMessageParts(summary: "Fix the border", description: "Use 8 pt.")
        #expect(parts.message == "Fix the border\n\nUse 8 pt.")
        #expect(GitCommitMessageParts(message: parts.message) == parts)
        for message in ["Fix", "Fix\n\nBody", "Fix\n\nLine 1\nLine 2", "Fix\n\n\nIndented"] {
            #expect(GitCommitMessageParts(message: message).message == message)
        }
    }

    @Test("A summary only has an empty description and no separator")
    func summaryOnly() {
        let parts = GitCommitMessageParts(message: "Fix the border")
        #expect(parts.summary == "Fix the border")
        #expect(parts.description.isEmpty)
        #expect(parts.message == "Fix the border")
    }

    @Test("A description only keeps an empty summary")
    func descriptionOnly() {
        let parts = GitCommitMessageParts(summary: "", description: "Only a body")
        #expect(parts.message == "\n\nOnly a body")
        #expect(GitCommitMessageParts(message: parts.message) == parts)
        #expect(!presentation(message: parts.message, staged: 1).canCommit)
        #expect(presentation(message: parts.message, staged: 1).showsDescription)
    }

    @Test("Trailing spaces stay in both parts")
    func trailingSpaces() {
        let parts = GitCommitMessageParts(message: "Fix the  \n\nBody  ")
        #expect(parts.summary == "Fix the  ")
        #expect(parts.description == "Body  ")
        #expect(
            GitCommitMessageParts.message("Fix\n\nBody", replacingSummary: "Fix ")
                == "Fix \n\nBody")
    }

    @Test("CRLF reads as LF")
    func crlf() {
        let parts = GitCommitMessageParts(message: "Fix\r\n\r\nLine 1\r\nLine 2\r\n")
        #expect(parts.summary == "Fix")
        #expect(parts.description == "Line 1\nLine 2\n")
    }

    @Test("AI text streams into the summary, then the description")
    func streaming() {
        let deltas = ["Fix the", " border\n", "\nThe", " card used 12 pt."]
        var message = ""
        var seen: [GitCommitMessageParts] = []
        for delta in deltas {
            message += delta
            seen.append(GitCommitMessageParts(message: message))
        }
        #expect(seen[0] == .init(summary: "Fix the", description: ""))
        #expect(seen[1] == .init(summary: "Fix the border", description: ""))
        #expect(seen[2] == .init(summary: "Fix the border", description: "The"))
        #expect(seen[3] == .init(summary: "Fix the border", description: "The card used 12 pt."))
        // A draft with no blank line still splits after the first line.
        #expect(
            GitCommitMessageParts(message: "Fix\nBody")
                == .init(summary: "Fix", description: "Body"))
    }

    @Test("Editing one part keeps the other")
    func editParts() {
        let message = "Fix\n\nBody"
        #expect(
            GitCommitMessageParts.message(message, replacingSummary: "Fix it") == "Fix it\n\nBody")
        #expect(GitCommitMessageParts.message(message, replacingDescription: "") == "Fix")
        #expect(
            GitCommitMessageParts.message("Fix", replacingDescription: "Body\n")
                == "Fix\n\nBody\n")
        // A pasted multi-line summary moves its extra lines to the description.
        let pasted = GitCommitMessageParts.message(message, replacingSummary: "One\nTwo")
        #expect(GitCommitMessageParts(message: pasted).summary == "One")
    }

    // MARK: Visibility

    @Test("A clean tree hides the composer unless a message, a merge or a draft keeps it")
    func visibility() {
        #expect(!presentation().isVisible)
        #expect(presentation(message: "WIP").isVisible)
        #expect(presentation(merge: true).isVisible)
        #expect(presentation(drafting: true).isVisible)
        #expect(presentation(stageable: 1).isVisible)
        #expect(presentation(staged: 1).isVisible)
    }

    @Test("The description shows with a summary, a description, focus or a draft")
    func descriptionVisibility() {
        #expect(!presentation(stageable: 2).showsDescription)
        #expect(!presentation(message: "   ", stageable: 2).showsDescription)
        #expect(presentation(message: "Fix", stageable: 2).showsDescription)
        #expect(presentation(stageable: 2, descriptionFocused: true).showsDescription)
        #expect(presentation(stageable: 2, drafting: true).showsDescription)
    }

    // MARK: Button

    @Test("Nothing staged: Stage All names the file count")
    func stageAllState() {
        let three = presentation(stageable: 3)
        #expect(three.action == .stageAll)
        #expect(three.buttonTitle == "Stage All 3 Files")
        #expect(three.buttonBranchSuffix == nil)
        #expect(three.isButtonEnabled)
        #expect(!three.isButtonProminent)
        #expect(three.disabledReason == nil)
        #expect(presentation(stageable: 1).buttonTitle == "Stage All 1 File")
        #expect(!presentation(stageable: 3, busy: true).isButtonEnabled)
    }

    @Test("Staged files: Commit names the count and the branch")
    func commitState() {
        let ready = presentation(message: "Fix", staged: 2, stageable: 1)
        #expect(ready.action == .commit)
        #expect(ready.buttonTitle == "Commit 2 Files")
        #expect(ready.buttonBranchSuffix == "to main")
        #expect(ready.buttonAccessibilityLabel == "Commit 2 Files to main")
        #expect(ready.canCommit)
        #expect(ready.isButtonEnabled)
        #expect(ready.isButtonProminent)
        #expect(presentation(message: "Fix", staged: 1).buttonTitle == "Commit 1 File")
    }

    @Test("Commit without a summary is disabled and says why")
    func commitNeedsSummary() {
        for message in ["", "  ", "\n\nOnly a body"] {
            let missing = presentation(message: message, staged: 2)
            #expect(missing.action == .commit)
            #expect(!missing.canCommit)
            #expect(!missing.isButtonEnabled)
            #expect(missing.disabledReason == "Write a summary to commit.")
            #expect(missing.buttonHelp == "Write a summary to commit.")
        }
    }

    @Test("A detached HEAD has no branch suffix")
    func detachedHead() {
        let detached = presentation(message: "Fix", staged: 2, branch: nil)
        #expect(detached.buttonBranchSuffix == nil)
        #expect(detached.buttonAccessibilityLabel == "Commit 2 Files")
    }

    @Test("A long branch name stays in the suffix; the title keeps the count")
    func longBranch() {
        let branch = String(repeating: "feature/very-long-name-", count: 4)
        let long = presentation(message: "Fix", staged: 2, branch: branch)
        #expect(long.buttonTitle == "Commit 2 Files")
        #expect(long.buttonBranchSuffix == "to \(branch)")
    }

    @Test("Drafting disables the button and names the draft")
    func draftingState() {
        let drafting = presentation(message: "Fix the", staged: 2, drafting: true)
        #expect(drafting.action == .drafting)
        #expect(drafting.buttonTitle == "Drafting…")
        #expect(drafting.buttonBranchSuffix == nil)
        #expect(!drafting.isButtonEnabled)
        #expect(!drafting.canCommit)
        #expect(drafting.isButtonProminent)
        #expect(drafting.disabledReason == "Wait for the draft to finish, or stop it.")
        #expect(presentation(stageable: 3, drafting: true).buttonTitle == "Drafting…")
    }

    @Test("A merge commits as Commit Merge, also with no file changes")
    func mergeState() {
        let merge = presentation(message: "Merge branch 'x'", staged: 2, merge: true)
        #expect(merge.buttonTitle == "Commit Merge")
        #expect(merge.buttonAccessibilityLabel == "Commit Merge to main")
        #expect(merge.canCommit)
        let empty = presentation(message: "Merge branch 'x'", merge: true)
        #expect(empty.buttonTitle == "Commit Merge")
        #expect(empty.canCommit)
        // Unstaged files and nothing staged: stage them first.
        #expect(presentation(message: "Merge", stageable: 1, merge: true).action == .stageAll)
    }

    @Test("A clean tree with a typed message has nothing to commit")
    func cleanTreeWithMessage() {
        let clean = presentation(message: "WIP")
        #expect(clean.isVisible)
        #expect(clean.buttonTitle == "Nothing to Commit")
        #expect(clean.buttonBranchSuffix == nil)
        #expect(!clean.isButtonEnabled)
        #expect(clean.disabledReason == "Stage files to commit.")
        // D4: Stage All is not available with nothing to stage.
        #expect(!clean.canStageAll)
    }

    @Test("A Git operation in flight disables Commit")
    func busyState() {
        let busy = presentation(message: "Fix", staged: 1, busy: true)
        #expect(!busy.canCommit)
        #expect(busy.disabledReason == "Wait for the current Git operation to finish.")
    }

    @Test("The section Stage All shows only for a partly staged tree")
    func sectionStageAll() {
        #expect(presentation(staged: 1, stageable: 2).showsSectionStageAll)
        #expect(!presentation(staged: 1).showsSectionStageAll)
        #expect(!presentation(stageable: 2).showsSectionStageAll)
        #expect(!presentation(staged: 1, stageable: 2, drafting: true).showsSectionStageAll)
    }

    // MARK: Counter

    @Test("The summary counter counts trimmed characters and warns above 72")
    func counter() {
        #expect(presentation(stageable: 1).summaryCount == nil)
        #expect(presentation(stageable: 1).summaryAccessibilityValue == "Empty")
        let short = presentation(message: "Fix  \n\nBody", stageable: 1)
        #expect(short.summaryCount == 3)
        #expect(!short.isSummaryTooLong)
        #expect(short.summaryAccessibilityValue == "3 characters")
        #expect(
            presentation(message: "X", stageable: 1).summaryAccessibilityValue == "1 character")
        let limit = presentation(message: String(repeating: "a", count: 72), stageable: 1)
        #expect(!limit.isSummaryTooLong)
        let long = presentation(message: String(repeating: "a", count: 73), stageable: 1)
        #expect(long.isSummaryTooLong)
        #expect(long.summaryAccessibilityValue == "73 characters, longer than 72")
        // Too long never blocks Commit.
        #expect(presentation(message: String(repeating: "a", count: 90), staged: 1).canCommit)
        #expect(presentation(message: "Fix", staged: 1, drafting: true).summaryCount == nil)
    }

    // MARK: Menu

    @Test("The Commit menu item is enabled only when Source Control can commit")
    func menuCommit() {
        #expect(!GitCommitMenuAvailability.canCommit(nil))
        #expect(!GitCommitMenuAvailability.canCommit(presentation()))
        #expect(!GitCommitMenuAvailability.canCommit(presentation(message: "Fix")))
        #expect(!GitCommitMenuAvailability.canCommit(presentation(staged: 2)))
        #expect(
            !GitCommitMenuAvailability.canCommit(
                presentation(message: "Fix", staged: 2, drafting: true)))
        #expect(
            !GitCommitMenuAvailability.canCommit(
                presentation(message: "Fix", staged: 2, busy: true)))
        #expect(GitCommitMenuAvailability.canCommit(presentation(message: "Fix", staged: 2)))
    }

    @Test("Command-Return stays with an Ensemble note in Edit mode")
    func commandReturnConflict() {
        let ready = presentation(message: "Fix", staged: 2)
        #expect(
            GitCommitMenuAvailability.commitOwnsShortcut(
                ready, isComposerFocused: true, isNoteEditing: false))
        // ⌘Return in a terminal, the editor or anywhere else never commits.
        #expect(
            !GitCommitMenuAvailability.commitOwnsShortcut(
                ready, isComposerFocused: false, isNoteEditing: false))
        // Format > Done Editing owns ⌘Return while a note is edited.
        #expect(
            !GitCommitMenuAvailability.commitOwnsShortcut(
                ready, isComposerFocused: true, isNoteEditing: true))
        // A disabled Commit item never claims ⌘Return.
        #expect(
            !GitCommitMenuAvailability.commitOwnsShortcut(
                presentation(staged: 2), isComposerFocused: true, isNoteEditing: false))
        #expect(
            !GitCommitMenuAvailability.commitOwnsShortcut(
                nil, isComposerFocused: true, isNoteEditing: false))
        // The note's own text view still leaves Edit mode on ⌘Return.
        #expect(
            CanvasNoteShortcuts.exitsEditing(
                keyCode: 36, command: true, shift: false, option: false, control: false))
    }

    @Test("Stage All and Draft Message menu items follow the Git state")
    func menuStageAllAndDraft() {
        #expect(!GitCommitMenuAvailability.canStageAll(nil, isHunkBusy: false))
        #expect(!GitCommitMenuAvailability.canStageAll(presentation(), isHunkBusy: false))
        #expect(
            GitCommitMenuAvailability.canStageAll(presentation(stageable: 2), isHunkBusy: false))
        #expect(
            !GitCommitMenuAvailability.canStageAll(presentation(stageable: 2), isHunkBusy: true))
        #expect(
            !GitCommitMenuAvailability.canStageAll(
                presentation(stageable: 2, busy: true), isHunkBusy: false))
        #expect(GitCommitMenuAvailability.canDraft(canGenerate: true, isBusy: false))
        #expect(!GitCommitMenuAvailability.canDraft(canGenerate: false, isBusy: false))
        #expect(!GitCommitMenuAvailability.canDraft(canGenerate: true, isBusy: true))
    }
}
