import AppKit
import RafuCore
import Testing

@testable import RafuApp

/// Tab-click responsiveness: one-gesture click resolution, click-driven editor
/// focus, same-frame breadcrumbs, the cached commit graph layout, and the
/// input-latency signpost math.
@Suite("Tab interaction responsiveness")
@MainActor
struct TabInteractionResponsivenessTests {
    // MARK: Click intent

    private func mouseEvent(type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil,
                eventNumber: 1, clickCount: clicks, pressure: 0))
    }

    @Test("No event counts as one click and only selects")
    func noEventSelects() {
        #expect(TabClickIntent.resolve(clickCount: 1, eventType: nil) == .select)
        // A missing event never renames, whatever count it is paired with.
        #expect(TabClickIntent.resolve(clickCount: 2, eventType: nil) == .select)
    }

    @Test("A non-mouse event only selects")
    func keyboardEventSelects() throws {
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        #expect(TabClickIntent.resolve(clickCount: 1, eventType: key.type) == .select)
        #expect(TabClickIntent.resolve(clickCount: 2, eventType: .keyDown) == .select)
    }

    @Test("One click selects, a second click selects and renames")
    func clickCountsResolve() throws {
        let single = try mouseEvent(type: .leftMouseUp, clicks: 1)
        let double = try mouseEvent(type: .leftMouseUp, clicks: 2)
        #expect(
            TabClickIntent.resolve(clickCount: single.clickCount, eventType: single.type) == .select
        )
        #expect(
            TabClickIntent.resolve(clickCount: double.clickCount, eventType: double.type)
                == .selectAndRename)
        #expect(
            TabClickIntent.resolve(clickCount: 2, eventType: .leftMouseDown) == .selectAndRename)
        #expect(TabClickIntent.resolve(clickCount: 3, eventType: .leftMouseUp) == .selectAndRename)
    }

    @Test("A secondary-button double click never renames")
    func rightDoubleClickDoesNotRename() {
        #expect(TabClickIntent.resolve(clickCount: 2, eventType: .rightMouseUp) == .select)
        #expect(TabClickIntent.resolve(clickCount: 2, eventType: .otherMouseUp) == .select)
    }

    // MARK: Signpost math

    @Test("Input latency is the uptime minus the event timestamp, in milliseconds")
    func inputLatency() {
        #expect(
            InteractionSignpost.inputLatencyMilliseconds(eventTimestamp: 10.000, now: 10.250)
                == 250)
        // A timestamp from the future never yields a negative latency.
        #expect(
            InteractionSignpost.inputLatencyMilliseconds(eventTimestamp: 11, now: 10) == 0)
    }

    @Test("Only mouse events count as clicks")
    func mouseEventClassification() {
        #expect(InteractionSignpost.isMouseEvent(.leftMouseUp))
        #expect(InteractionSignpost.isMouseEvent(.rightMouseDown))
        #expect(!InteractionSignpost.isMouseEvent(.keyDown))
        #expect(!InteractionSignpost.isMouseEvent(.mouseMoved))
    }

    // MARK: Editor focus on click selection

    private func makeSession() -> WorkspaceSession {
        let suite = "dev.rafu.tab-interaction.\(UUID().uuidString)"
        let store = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        return WorkspaceSession(restorationStore: store)
    }

    private func twoDocumentTabs(
        _ session: WorkspaceSession
    ) throws -> (
        first: EditorDocument, second: EditorDocument, firstTab: EditorTabID,
        secondTab: EditorTabID, group: EditorGroupID
    ) {
        session.newUntitledDocument()
        session.newUntitledDocument()
        let groupID = session.editorLayout.focusedGroupID
        let group = try #require(session.editorLayout.group(id: groupID))
        #expect(group.tabs.count == 2)
        let firstTab = group.tabs[0]
        let secondTab = group.tabs[1]
        return (
            try #require(session.document(for: firstTab)),
            try #require(session.document(for: secondTab)),
            firstTab.id, secondTab.id, groupID
        )
    }

    @Test("A tab click asks the newly selected editor to take focus once")
    func clickSetsFocusIntentOnce() throws {
        let session = makeSession()
        let fixture = try twoDocumentTabs(session)
        // The second tab is selected after creation; click the first.
        session.selectEditorTabFromClick(fixture.firstTab, in: fixture.group)

        #expect(session.selectedDocument === fixture.first)
        #expect(fixture.first.focusEditorOnShow)
        #expect(!fixture.second.focusEditorOnShow)
        #expect(fixture.first.consumeFocusEditorOnShow())
        #expect(!fixture.first.consumeFocusEditorOnShow())
    }

    @Test("Selection that is not a click never asks for focus")
    func revealDoesNotSetFocusIntent() throws {
        let session = makeSession()
        let fixture = try twoDocumentTabs(session)

        session.selectEditorTab(fixture.firstTab, in: fixture.group)
        #expect(!fixture.first.focusEditorOnShow)
        #expect(!fixture.second.focusEditorOnShow)
    }

    @Test("Clicking the tab that is already selected sets no stale intent")
    func clickOnSelectedTabSetsNoIntent() throws {
        let session = makeSession()
        let fixture = try twoDocumentTabs(session)

        session.selectEditorTabFromClick(fixture.secondTab, in: fixture.group)
        #expect(!fixture.second.focusEditorOnShow)
    }

    @Test("A later non-click selection clears an unconsumed click intent")
    func laterSelectionClearsStaleIntent() throws {
        let session = makeSession()
        let fixture = try twoDocumentTabs(session)

        session.selectEditorTabFromClick(fixture.firstTab, in: fixture.group)
        #expect(fixture.first.focusEditorOnShow)
        session.selectEditorTab(fixture.secondTab, in: fixture.group)
        #expect(!fixture.first.focusEditorOnShow)
    }

    // MARK: Focus policy

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    @Test("The click focus policy moves focus only off an empty or hidden responder")
    func focusPolicy() throws {
        let window = makeWindow()
        let content = try #require(window.contentView)
        let target = RafuTextView.makeTextKit1()
        let otherEditor = RafuTextView.makeTextKit1()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        for view in [target, otherEditor, field] { content.addSubview(view) }

        window.makeFirstResponder(nil)
        #expect(CodeEditorView.EditorClickFocusPolicy.allowsTakingFocus(in: window, for: target))

        #expect(window.makeFirstResponder(otherEditor))
        #expect(CodeEditorView.EditorClickFocusPolicy.allowsTakingFocus(in: window, for: target))

        #expect(window.makeFirstResponder(target))
        #expect(!CodeEditorView.EditorClickFocusPolicy.allowsTakingFocus(in: window, for: target))

        // A text field (its field editor is a plain NSTextView) keeps focus.
        #expect(window.makeFirstResponder(field))
        #expect(!CodeEditorView.EditorClickFocusPolicy.allowsTakingFocus(in: window, for: target))
    }

    // MARK: Breadcrumb

    @Test("Breadcrumb segments follow the document on the first render")
    func breadcrumbSegmentsAreImmediate() {
        let first = EditorBreadcrumbPath.segments(
            forFileAt: "/work/app/Sources/A.swift", displayName: "A.swift",
            rootPath: "/work/app", workspaceName: "app")
        let second = EditorBreadcrumbPath.segments(
            forFileAt: "/work/app/Tests/B.swift", displayName: "B.swift",
            rootPath: "/work/app", workspaceName: "app")

        #expect(first.map(\.title) == ["app", "Sources", "A.swift"])
        #expect(second.map(\.title) == ["app", "Tests", "B.swift"])
    }

    @Test("Breadcrumb without a workspace shows only the file")
    func breadcrumbWithoutWorkspace() {
        let segments = EditorBreadcrumbPath.segments(
            forFileAt: "/tmp/Untitled.txt", displayName: "Untitled.txt",
            rootPath: nil, workspaceName: "")
        #expect(segments.map(\.title) == ["Untitled.txt"])
        #expect(segments.first?.kind == .file)
    }

    // MARK: Commit graph layout memo

    private func commit(_ id: String, parents: [String]) -> GitCommitSummary {
        GitCommitSummary(
            id: id, parentIDs: parents, authorName: "A", authorEmail: "a@example.com",
            authoredAt: Date(timeIntervalSince1970: 0), subject: "s \(id)", decorations: [])
    }

    @Test("The commit graph layout runs again only when the commit IDs change")
    func layoutMemoRecomputesOnlyOnIDChange() {
        let commits = [
            commit("c", parents: ["b"]), commit("b", parents: ["a"]), commit("a", parents: []),
        ]
        var memo = CommitGraphLayoutMemo()

        let didLayOutFirst = memo.update(for: commits)
        #expect(didLayOutFirst)
        #expect(memo.layoutRunCount == 1)
        #expect(memo.rowsByID.count == 3)
        #expect(memo.laneCount == 1)

        // Same IDs, for example after a search or a selection change.
        let didLayOutAgain = memo.update(for: commits)
        #expect(!didLayOutAgain)
        #expect(memo.layoutRunCount == 1)

        // Load More appends commits.
        let more = commits + [commit("z", parents: [])]
        let didLayOutMore = memo.update(for: more)
        #expect(didLayOutMore)
        #expect(memo.layoutRunCount == 2)
        #expect(memo.rowsByID.count == 4)
    }
}
