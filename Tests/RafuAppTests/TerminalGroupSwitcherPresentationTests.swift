import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal Group switcher presentation")
struct TerminalGroupSwitcherPresentationTests {
    @Test("Group switcher presentation includes aggregate attention and focused pane")
    func groupSwitcherPresentationIncludesRequiredDetail() {
        let presentation = EditorTerminalGroupSwitcherPresentation(
            name: "Build", paneCount: 3, focusedPaneName: "Server", attentionCount: 2,
            isParked: true)
        #expect(presentation.title == "Build")
        #expect(presentation.detail == "Parked · 3 panes · Focused: Server · 2 need attention")
    }

    @MainActor
    @Test("Switcher lists visible and parked groups once, preserves files, and commits only once")
    func switcherUsesOneCandidatePerGroup() throws {
        let session = WorkspaceSession()
        let fileURL = URL(fileURLWithPath: "/tmp/switcher-file.swift")
        let file = EditorTabState(resource: .file(fileURL))
        session.openDocuments = [EditorDocument(url: fileURL)]
        session.editorLayout.insert(file, in: session.editorLayout.focusedGroupID)
        session.newTerminalGroup()
        let visible = try #require(session.selectedTerminalGroupID)
        let visiblePane = try #require(session.terminal.terminalGroup(visible)?.focusedPaneID)
        session.newTerminalGroup()
        let parked = try #require(session.selectedTerminalGroupID)
        let parkedPane = try #require(session.terminal.terminalGroup(parked)?.focusedPaneID)
        session.hideTerminalGroup(parked)

        let candidates = session.editorTabSwitcherCandidates.map(\.destination)
        #expect(
            candidates.contains(
                .editorTab(tabID: file.id, groupID: session.editorLayout.focusedGroupID)))
        #expect(candidates.filter { $0 == .terminalGroup(groupID: visible) }.count == 1)
        #expect(candidates.filter { $0 == .terminalGroup(groupID: parked) }.count == 1)
        #expect(candidates.count == 3)

        session.cycleEditorTabSwitcher(.forward)
        let selectedBeforeCancel = session.editorLayout.focusedGroupID
        session.moveEditorTabSwitcherSelection(.backward)
        session.cancelEditorTabSwitcher()
        #expect(session.editorLayout.focusedGroupID == selectedBeforeCancel)
        #expect(session.terminal.terminalGroup(visible)?.focusedPaneID == visiblePane)

        session.cycleEditorTabSwitcher(.forward)
        session.commitEditorTabSwitcher(to: .terminalGroup(groupID: parked))
        #expect(session.terminal.terminalGroup(parked)?.focusedPaneID == parkedPane)
        #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: parked)) != nil)
        #expect(session.editorTabSwitcherState == nil)
    }

    @Test("Group candidate has a distinct destination identity")
    func groupCandidateIdentityIsDistinct() {
        let groupID = TerminalGroupID()
        let candidate = EditorTabSwitcherCandidate(destination: .terminalGroup(groupID: groupID))
        #expect(candidate.id == .terminalGroup(groupID: groupID))
    }

    @Test("Switcher source presents group focus, pane count, parked state, and attention")
    func switcherSourcePresentsGroupSummary() throws {
        let viewSource = try source("Sources/RafuApp/Views/EditorTabSwitcherView.swift")
        #expect(viewSource.contains("case .terminalGroup(let groupID)"))
        #expect(viewSource.contains("group.panes.count"))

        let presentationSource = try source("Sources/RafuApp/Editor/EditorTabSwitcher.swift")
        #expect(presentationSource.contains("Focused:"))
        #expect(presentationSource.contains("Parked"))
        #expect(presentationSource.contains("need attention"))
    }

    private func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
