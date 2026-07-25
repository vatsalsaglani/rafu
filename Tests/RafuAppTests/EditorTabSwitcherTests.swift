import Foundation
import Testing

@testable import RafuApp

@Test("Tab switcher state starts after the active destination and wraps both directions")
func editorTabSwitcherStateWraps() throws {
    let groupID = EditorGroupID()
    let candidates = (0..<3).map { _ in
        EditorTabSwitcherCandidate(
            destination: .editorTab(tabID: EditorTabID(), groupID: groupID)
        )
    }

    var forward = try #require(
        EditorTabSwitcherState(
            candidates: candidates,
            current: candidates[2].destination,
            direction: .forward
        )
    )
    #expect(forward.selectedCandidate == candidates[0])

    forward.move(.backward)
    #expect(forward.selectedCandidate == candidates[2])

    let backward = try #require(
        EditorTabSwitcherState(
            candidates: candidates,
            current: candidates[0].destination,
            direction: .backward
        )
    )
    #expect(backward.selectedCandidate == candidates[2])
}

@Test("Tab switcher state requires at least two destinations")
func editorTabSwitcherStateRejectsSingleCandidate() {
    let candidate = EditorTabSwitcherCandidate(
        destination: .terminal(sessionID: UUID())
    )
    #expect(
        EditorTabSwitcherState(
            candidates: [candidate],
            current: candidate.destination,
            direction: .forward
        ) == nil
    )
}

@MainActor
@Test("Switcher candidates contain open tabs and parked terminals exactly once")
func editorTabSwitcherIncludesTabsAndParkedTerminals() throws {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/switcher.swift")
    let fileTab = EditorTabState(resource: .file(url))
    session.openDocuments = [EditorDocument(url: url)]
    session.editorLayout.insert(fileTab, in: session.editorLayout.focusedGroupID)

    session.newTerminalTab()
    let presentedController = try #require(session.terminal.sessions.first)
    session.newTerminalTab()
    let parkedController = try #require(session.terminal.sessions.last)
    let parkedTab = try #require(
        session.editorLayout.tab(matching: .terminal(sessionID: parkedController.id))
    )
    session.hideTerminalTab(parkedTab.id)

    let destinations = session.editorTabSwitcherCandidates.map(\.destination)
    #expect(
        destinations
            == [
                .editorTab(tabID: fileTab.id, groupID: session.editorLayout.focusedGroupID),
                .terminal(sessionID: presentedController.id),
                .terminal(sessionID: parkedController.id),
            ])
    #expect(Set(destinations).count == destinations.count)
    #expect(session.canCycleEditorTabs)
}

@MainActor
@Test("Ctrl-Tab previews without changing selection, then reveals a parked terminal on commit")
func editorTabSwitcherCommitsParkedTerminal() throws {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/switcher.swift")
    let fileTab = EditorTabState(resource: .file(url))
    session.openDocuments = [EditorDocument(url: url)]
    session.editorLayout.insert(fileTab, in: session.editorLayout.focusedGroupID)

    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let terminalTab = try #require(
        session.editorLayout.tab(matching: .terminal(sessionID: controller.id))
    )
    session.hideTerminalTab(terminalTab.id)

    let groupID = session.editorLayout.focusedGroupID
    #expect(session.editorLayout.group(id: groupID)?.selectedTabID == fileTab.id)

    session.cycleEditorTabSwitcher(.forward)

    #expect(
        session.editorTabSwitcherState?.selectedCandidate.destination
            == .terminal(sessionID: controller.id)
    )
    // Browsing the overlay does not churn editor selection or persistence.
    #expect(session.editorLayout.group(id: groupID)?.selectedTabID == fileTab.id)

    session.commitEditorTabSwitcher()

    #expect(session.editorTabSwitcherState == nil)
    let selectedTab = try #require(
        session.editorLayout.group(id: groupID)?.tabs.first(where: {
            $0.id == session.editorLayout.group(id: groupID)?.selectedTabID
        })
    )
    #expect(selectedTab.resource == .terminal(sessionID: controller.id))
    #expect(session.parkedTerminalSessions.isEmpty)
}

@MainActor
@Test("Cancelling the Ctrl-Tab switcher leaves the focused tab unchanged")
func editorTabSwitcherCancelPreservesSelection() {
    let session = WorkspaceSession()
    let firstURL = URL(fileURLWithPath: "/tmp/first.swift")
    let secondURL = URL(fileURLWithPath: "/tmp/second.swift")
    let firstTab = EditorTabState(resource: .file(firstURL))
    let secondTab = EditorTabState(resource: .file(secondURL))
    let group = EditorGroupState(
        tabs: [firstTab, secondTab],
        selectedTabID: firstTab.id
    )
    session.openDocuments = [EditorDocument(url: firstURL), EditorDocument(url: secondURL)]
    session.editorLayout = EditorLayoutState(
        root: .group(group),
        focusedGroupID: group.id
    )

    session.cycleEditorTabSwitcher(.forward)
    #expect(
        session.editorTabSwitcherState?.selectedCandidate.destination
            == .editorTab(tabID: secondTab.id, groupID: group.id))

    session.cancelEditorTabSwitcher()

    #expect(session.editorTabSwitcherState == nil)
    #expect(session.editorLayout.group(id: group.id)?.selectedTabID == firstTab.id)
}

@MainActor
@Test("Committing a tab in another split focuses its group")
func editorTabSwitcherCommitFocusesDestinationGroup() {
    let session = WorkspaceSession()
    let firstURL = URL(fileURLWithPath: "/tmp/first.swift")
    let secondURL = URL(fileURLWithPath: "/tmp/second.swift")
    let firstTab = EditorTabState(resource: .file(firstURL))
    let secondTab = EditorTabState(resource: .file(secondURL))
    let firstGroup = EditorGroupState(tabs: [firstTab])
    let secondGroup = EditorGroupState(tabs: [secondTab])
    session.openDocuments = [EditorDocument(url: firstURL), EditorDocument(url: secondURL)]
    session.editorLayout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(),
            axis: .horizontal,
            fraction: 0.5,
            first: .group(firstGroup),
            second: .group(secondGroup)
        ),
        focusedGroupID: firstGroup.id
    )

    session.cycleEditorTabSwitcher(.forward)
    session.commitEditorTabSwitcher()

    #expect(session.editorLayout.focusedGroupID == secondGroup.id)
    #expect(session.selectedDocumentID == session.openDocuments[1].id)
}
