import Foundation
import Testing

@testable import RafuApp

/// terminal-manager.md T-B: the terminals panel's mode/persistence, row
/// derivation, reveal/hide/close wiring, and rail-badge attention counting.
/// New tests here must call `newTerminalTab()` with NO shell argument —
/// passing an explicit `shell` records it to the real
/// `UserDefaults.standard` via `PreferredShellStore`, which would pollute
/// the developer's actual preferred-shell setting and interact badly under
/// `swift test --no-parallel`.

// MARK: - A: mode/decode

@Test(".terminals round-trips through Codable")
func terminalsModeRoundTrips() throws {
    let encoded = try JSONEncoder().encode(WorkspaceNavigatorMode.terminals)
    let decoded = try JSONDecoder().decode(WorkspaceNavigatorMode.self, from: encoded)
    #expect(decoded == .terminals)
}

@Test("An unknown persisted raw value decodes to .files rather than throwing")
func unknownRawValueFallsBackToFiles() throws {
    let data = Data("\"quantum\"".utf8)
    let decoded = try JSONDecoder().decode(WorkspaceNavigatorMode.self, from: data)
    #expect(decoded == .files)
}

@Test(
    "A full RestorableWorkspace payload with navigatorMode string-replaced to an unknown value still decodes, falling back to .files"
)
func restorableWorkspaceUnknownModeFallsBackToFiles() throws {
    let layout = EditorLayoutState()
    let payload = RestorableWorkspace(
        bookmark: Data([1, 2, 3]),
        rootPath: "/tmp",
        openRelativePaths: ["README.md"],
        selectedRelativePath: "README.md",
        navigatorMode: .files,
        editorLayout: EditorLayoutRestoration(layout: layout)
    )
    let encoded = try JSONEncoder().encode(payload)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json.contains("\"navigatorMode\":\"files\""))
    let mutated = json.replacingOccurrences(
        of: "\"navigatorMode\":\"files\"", with: "\"navigatorMode\":\"quantum\"")
    let mutatedData = try #require(mutated.data(using: .utf8))

    let decoded = try JSONDecoder().decode(RestorableWorkspace.self, from: mutatedData)

    #expect(decoded.navigatorMode == .files)
    #expect(decoded.rootPath == "/tmp")
    #expect(decoded.openRelativePaths == ["README.md"])
}

// MARK: - B: row derivation

@MainActor
@Test("Rows are one per session, in creation order, with matching name/shell")
func rowsMatchSessionsInCreationOrder() {
    let session = WorkspaceSession()
    session.newTerminalTab()
    session.newTerminalTab()

    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )

    #expect(rows.count == session.terminal.sessions.count)
    #expect(rows.map(\.id) == session.terminal.sessions.map(\.id))
    for (row, controller) in zip(rows, session.terminal.sessions) {
        #expect(row.displayName == controller.displayName)
        #expect(row.shellName == controller.shellDisplayName)
    }
}

@MainActor
@Test("isParked is true exactly for sessions with no presented tab")
func isParkedMatchesPresentedIDs() {
    let session = WorkspaceSession()
    session.newTerminalTab()
    session.newTerminalTab()

    // Both tabs live in the same focused group with the second selected;
    // toggling parks that selected terminal tab, leaving one parked.
    session.toggleTerminal()

    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )

    #expect(rows.filter(\.isParked).count == 1)
    #expect(rows.filter { !$0.isParked }.count == 1)
}

@Test(
    "directoryLabel derivation: relative under root, '.' at root, tilde under home, raw otherwise"
)
func directoryLabelDerivation() {
    #expect(
        TerminalSessionPresentation.directoryLabel(
            path: "/Users/dev/project/src", workspaceRoot: "/Users/dev/project") == "src")
    #expect(
        TerminalSessionPresentation.directoryLabel(
            path: "/Users/dev/project", workspaceRoot: "/Users/dev/project") == ".")
    let homeSubpath = NSHomeDirectory() + "/Downloads"
    #expect(
        TerminalSessionPresentation.directoryLabel(
            path: homeSubpath, workspaceRoot: "/Users/dev/project") == "~/Downloads")
    #expect(
        TerminalSessionPresentation.directoryLabel(path: homeSubpath, workspaceRoot: nil)
            == "~/Downloads")
    #expect(
        TerminalSessionPresentation.directoryLabel(path: "/opt/other", workspaceRoot: nil)
            == "/opt/other")
}

@Test("label formats each TerminalSessionStatus; symbol is shape-distinct per status")
func labelAndSymbolPerStatus() {
    #expect(TerminalSessionPresentation.label(.idle) == "Idle")
    #expect(TerminalSessionPresentation.label(.running) == "Running")
    #expect(TerminalSessionPresentation.label(.bell) == "Needs attention")
    #expect(TerminalSessionPresentation.label(.exited(code: nil)) == "Exited")
    #expect(TerminalSessionPresentation.label(.exited(code: 1)) == "Exited (1)")

    let symbols = Set([
        TerminalSessionPresentation.symbol(.idle),
        TerminalSessionPresentation.symbol(.running),
        TerminalSessionPresentation.symbol(.bell),
        TerminalSessionPresentation.symbol(.exited(code: nil)),
    ])
    #expect(symbols.count == 4)
}

@MainActor
@Test("A session that exits naturally still produces a row with the exited label")
func exitedSessionStillProducesRow() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    controller.processDidTerminate(exitCode: 1)

    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )
    let row = try #require(rows.first { $0.id == controller.id })
    #expect(TerminalSessionPresentation.label(row.status) == "Exited (1)")
}

// MARK: - C: reveal

@MainActor
@Test("Reveal on a parked session inserts exactly one tab and selects it")
func revealParkedInsertsAndSelectsOneTab() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    session.hideTerminalSession(controller.id)
    #expect(session.parkedTerminalSessions.count == 1)

    session.revealTerminalSession(controller.id)

    let group = session.editorLayout.group(id: session.editorLayout.focusedGroupID)
    #expect(group?.tabs.count == 1)
    #expect(group?.selectedTabID == group?.tabs.first?.id)
    #expect(session.parkedTerminalSessions.isEmpty)
}

// MARK: - D: hide/close

@MainActor
@Test("hideTerminalSession parks a presented session, leaving it alive")
func hideTerminalSessionParksPresentedSession() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    session.hideTerminalSession(controller.id)

    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)
    #expect(session.parkedTerminalSessions.first?.id == controller.id)
}

@MainActor
@Test("hideTerminalSession is a no-op for an already-parked or unknown session")
func hideTerminalSessionNoOpsForParkedOrUnknown() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    session.hideTerminalSession(controller.id)
    #expect(session.parkedTerminalSessions.count == 1)

    session.hideTerminalSession(controller.id)
    #expect(session.parkedTerminalSessions.count == 1)

    session.hideTerminalSession(UUID())
    #expect(session.parkedTerminalSessions.count == 1)
}

@MainActor
@Test("closeTerminalSession on a presented session removes the session and its tab")
func closeTerminalSessionRemovesPresentedSessionAndTab() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    #expect(session.hasAnyEditorTabs)

    session.closeTerminalSession(controller.id)

    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.isEmpty)
}

// MARK: - E: attention

@MainActor
@Test("attentionCount is 0 for rows built from every current TerminalSessionStatus")
func attentionCountZeroForCurrentStatuses() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    session.newTerminalTab()
    let secondController = try #require(session.terminal.sessions.last)
    secondController.processDidTerminate(exitCode: 0)

    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )

    #expect(TerminalsPanelModel.attentionCount(rows) == 0)
    #expect(TerminalsPanelModel.attentionCount(sessions: session.terminal.sessions) == 0)
}

@Test("attentionCount reflects hand-built rows with needsAttention true")
func attentionCountCountsHandBuiltRows() {
    let rows = [
        TerminalSessionRow(
            id: UUID(), displayName: "A", shellName: "zsh", directoryLabel: ".",
            status: .running, isParked: false, needsAttention: false, hasUserName: false,
            sessionColor: nil),
        TerminalSessionRow(
            id: UUID(), displayName: "B", shellName: "zsh", directoryLabel: ".",
            status: .bell, isParked: false, needsAttention: true, hasUserName: false,
            sessionColor: nil),
        TerminalSessionRow(
            id: UUID(), displayName: "C", shellName: "zsh", directoryLabel: ".",
            status: .exited(code: nil), isParked: true, needsAttention: true, hasUserName: true,
            sessionColor: .accent),
    ]
    #expect(TerminalsPanelModel.attentionCount(rows) == 2)
}
