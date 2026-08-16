import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
private func terminalPresentationSession() -> WorkspaceSession {
    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: "Terminal presentation",
        location: .local(LocalWorkspaceReference(path: "/tmp/terminal-presentation"))
    )
    return session
}

@MainActor
@Test("No editor focus and a selected file produce no current terminal")
func currentTerminalRequiresFocusedVisibleTerminal() throws {
    let session = terminalPresentationSession()
    #expect(session.currentTerminalSessionID == nil)

    session.newTerminalTab()
    let terminalID = try #require(session.terminal.sessions.first?.id)
    let fileURL = URL(fileURLWithPath: "/tmp/terminal-presentation/README.md")
    let fileTab = EditorTabState(resource: .file(fileURL))
    let groupID = session.editorLayout.focusedGroupID
    session.editorLayout.insert(fileTab, in: groupID)
    session.editorLayout.select(fileTab.id, in: groupID)

    #expect(session.currentTerminalSessionID == nil)
    // The manager's historical selection may still point at a terminal, but
    // it is intentionally not a presentation input for the current row.
    #expect(session.terminal.selectedID == terminalID)
}

@MainActor
@Test("One focused visible terminal is current without mounting SwiftTerm")
func oneVisibleTerminalIsCurrentWithoutMountingShell() throws {
    let session = terminalPresentationSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    #expect(session.currentTerminalSessionID == controller.id)
    #expect(controller.status == .idle)
}

@MainActor
@Test("Two terminal groups expose only the focused group's selected terminal")
func twoTerminalGroupsHaveOneCurrentTerminal() throws {
    let session = terminalPresentationSession()
    session.newTerminalTab()
    session.newTerminalTab()
    let first = try #require(session.terminal.sessions.first)
    let second = try #require(session.terminal.sessions.last)
    let originalGroupID = session.editorLayout.focusedGroupID
    let secondTerminalGroupID = try #require(
        session.terminal.terminalGroupAndPane(containing: second.id)?.0)
    let secondTab = try #require(
        session.editorLayout.tab(matching: .terminalGroup(groupID: secondTerminalGroupID)))
    let splitGroupID = session.editorLayout.split(
        group: originalGroupID,
        at: .trailing,
        moving: secondTab.id
    )
    let secondGroupID = try #require(splitGroupID)

    #expect(session.currentTerminalSessionID == second.id)
    session.editorLayout.focus(originalGroupID)
    #expect(session.currentTerminalSessionID == first.id)
    session.editorLayout.focus(secondGroupID)
    #expect(session.currentTerminalSessionID == second.id)

    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )
    #expect(rows.count { $0.id == session.currentTerminalSessionID } == 1)
}

@MainActor
@Test("Parked and hidden terminals are never current even when manager-selected")
func parkedTerminalIsNotCurrent() throws {
    let session = terminalPresentationSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    session.hideTerminalSession(controller.id)

    let terminalGroupID = try #require(
        session.terminal.terminalGroupAndPane(containing: controller.id)?.0)
    #expect(session.parkedTerminalGroupIDs == [terminalGroupID])
    #expect(session.terminal.selectedID == controller.id)
    #expect(session.currentTerminalSessionID == nil)
}

@MainActor
@Test("A visible exited terminal remains current until hidden or focus moves")
func exitedVisibleTerminalRemainsCurrent() throws {
    let session = terminalPresentationSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    controller.processDidTerminate(exitCode: 7)

    #expect(controller.status == .exited(code: 7))
    #expect(session.currentTerminalSessionID == controller.id)
}

@MainActor
@Test("Standalone diff and tabless canvases suppress the terminal current row")
func nonEditorCanvasesSuppressCurrentTerminal() throws {
    let session = terminalPresentationSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    #expect(session.currentTerminalSessionID == controller.id)

    session.gitOpenDiff = GitOpenDiff(
        title: "Diff",
        subtitle: "",
        diff: GitFileDiff(
            path: "README.md",
            originalPath: nil,
            isBinary: false,
            hunks: [],
            rawPatch: ""
        ),
        identity: "working:README.md",
        scope: .workingTree
    )
    #expect(session.currentTerminalSessionID == nil)

    session.gitOpenDiff = nil
    session.settingsVisible = true
    #expect(session.currentTerminalSessionID == nil)
}

@Test("Manager border inputs keep current, attention, identity, status, and parking separate")
func managerPresentationInputsStaySeparate() {
    let current = TerminalSurfaceBorderStyle.resolve(
        context: .managerRow(isCurrent: true, needsAttention: false),
        identity: .none,
        contrast: .normal
    )
    let attentionWithMatchingIdentity = TerminalSurfaceBorderStyle.resolve(
        context: .managerRow(isCurrent: false, needsAttention: true),
        identity: .assigned(matchesEditorBackground: true),
        contrast: .normal
    )

    #expect(current.emphasis == .managerCurrent)
    #expect(current.rowFill == .current)
    #expect(!current.showsIdentityAccent)
    #expect(attentionWithMatchingIdentity.emphasis == .managerAttention)
    #expect(attentionWithMatchingIdentity.rowFill == .none)
    #expect(attentionWithMatchingIdentity.showsIdentityAccent)
    #expect(attentionWithMatchingIdentity.neutralWidth == 1)
    #expect(attentionWithMatchingIdentity.identityWidth == 2)
    #expect(attentionWithMatchingIdentity.identityInset == 1)
    #expect(attentionWithMatchingIdentity.emphasisWidth == 1)
    #expect(attentionWithMatchingIdentity.identityAndEmphasisDoNotOverlap)
}

@Suite("Terminal manager source contract")
struct TerminalManagerSourceContractTests {
    @Test("The panel uses one shared header, adaptive named launch cells, and 48 point rows")
    func compactTerminalManagerGeometry() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")

        #expect(panel.contains("RafuUtilityPanelHeader("))
        #expect(panel.contains(#"title: "Terminals""#))
        #expect(panel.contains("GridItem(.adaptive(minimum: 86, maximum: 160), spacing: 6"))
        #expect(panel.contains("Text(row.displayName)"))
        #expect(panel.contains("base: 34"))
        #expect(panel.contains("LazyVStack(spacing: 6)"))
        #expect(panel.contains("base: 48"))
        #expect(panel.contains("RafuPanelEmptyState("))
    }

    @Test("The header keeps one direct default action and adds a two-shell picker affordance")
    func headerUsesSplitTerminalAction() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        let header = try Self.section(
            named: "private func header(count: Int) -> some View",
            until: "/// The launcher's only path to a spawn",
            in: panel
        )

        #expect(header.components(separatedBy: "session.newTerminalTab()").count - 1 == 1)
        #expect(header.contains("if session.availableTerminalShells.count >= 2"))
        #expect(header.contains(#"Label("Choose Terminal Shell", systemImage: "chevron.down")"#))
        #expect(header.contains("TerminalShellPickerView("))
        #expect(header.contains("session.newTerminalTab(shell: shell)"))
        #expect(header.contains("isShellPickerPresented = false"))
        #expect(!header.contains("Menu(\"New Terminal With Shell\")"))
    }

    @Test("Launcher help and accessibility carry provider readiness and unavailable reasons")
    func launcherStateRemainsTextualAndAccessible() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")

        #expect(panel.contains(".help(row.tooltip)"))
        #expect(panel.contains(".accessibilityLabel(row.accessibilityLabel)"))
        #expect(panel.contains(#"Image(systemName: "checkmark")"#))
        #expect(panel.contains(#"Image(systemName: "exclamationmark.triangle")"#))
        #expect(panel.contains("ProgressView()"))
    }

    @Test("Current derives from focus, not selectedID, and drives the shared manager-row resolver")
    func currentRowUsesSharedPresentationContract() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")

        #expect(panel.contains("currentGroupID: session.selectedTerminalGroupID"))
        #expect(panel.contains("currentLegacySessionID: session.currentTerminalSessionID"))
        #expect(!panel.contains("session.terminal.selectedID"))
        #expect(panel.contains(".managerRow("))
        #expect(panel.contains("needsAttention: row.needsAttention"))
        #expect(panel.contains("identityColor: identityColor"))
        #expect(panel.contains(#"parts.append("Current terminal")"#))
        #expect(panel.contains(".isSelected"))
    }

    @Test("The SwiftTerm body stays presentation-free and unclipped")
    func swiftTermBodyRemainsUnclipped() throws {
        let body = try Self.source("Sources/RafuApp/Terminal/EditorTerminalTabContent.swift")

        #expect(!body.contains("rafuTerminalSurfaceBorder"))
        #expect(!body.contains(".clipShape"))
        #expect(!body.contains(".mask"))
        #expect(!body.contains("CornerCutoutOverlay"))
        #expect(!body.contains("EditorGroupSurface"))
        #expect(body.contains("controller.makeOrReuseView(theme: theme)"))
        #expect(body.contains("controller.applyTheme(theme, to: nsView)"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw TerminalManagerSourceContractError.repositoryRootNotFound
    }

    private static func section(named start: String, until end: String, in source: String) throws
        -> String
    {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }

    private enum TerminalManagerSourceContractError: Error {
        case repositoryRootNotFound
    }
}
