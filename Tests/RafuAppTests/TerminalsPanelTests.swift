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
@Test("Rows carry provider identity for Agent Terminals while plain shells stay unchanged")
func rowsCarryAgentTerminalIdentityOnly() throws {
    let workspace = WorkspaceSession()
    workspace.newTerminalTab()
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let option = AgentTerminalOption(
        id: .codex,
        displayName: ConductorCLIID.codex.displayName,
        icon: ConductorCLIIcons.icon(for: .codex),
        availability: .ready(URL(fileURLWithPath: "/usr/local/bin/codex")),
        curatedModels: [],
        defaultModel: nil,
        launchVerificationNote: nil)
    let spec = try AgentTerminalLaunchService(workspaceRoot: root).specification(
        option: option,
        model: nil,
        startingDirectory: root)
    workspace.openAgentTerminal(spec: spec)

    let rows = TerminalsPanelModel.rows(
        sessions: workspace.terminal.sessions,
        presentedIDs: workspace.presentedTerminalSessionIDs,
        workspaceRoot: root.path)

    #expect(rows.count == 2)
    #expect(rows[0].agentProvider == nil)
    #expect(rows[1].agentProvider == .codex)
    #expect(rows[1].displayName == "Codex")
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

// MARK: - B2: inline agent launcher (UX-03)

private func agentOption(
    _ id: ConductorCLIID,
    availability: AgentTerminalAvailability,
    note: String? = nil
) -> AgentTerminalOption {
    AgentTerminalOption(
        id: id,
        displayName: id.displayName,
        icon: ConductorCLIIcons.icon(for: id),
        availability: availability,
        curatedModels: [],
        defaultModel: nil,
        launchVerificationNote: note)
}

@Test("The launcher's pending state is one row per provider, never an empty list")
func agentLauncherProbingRowsCoverEveryProvider() {
    let rows = AgentLauncherModel.probingRows()

    #expect(!rows.isEmpty)
    #expect(rows.count == ConductorCLIID.allCases.count)
    #expect(rows.map(\.id) == ConductorCLIID.allCases)
    for row in rows {
        #expect(row.state == .probing)
        #expect(row.statusText == "Checking…")
        #expect(!row.isLaunchable)
        #expect(row.accessibilityLabel.contains(row.displayName))
        #expect(row.accessibilityLabel.contains("checking"))
    }
    // The count is withheld until the probe resolves: "0 of 7 ready" mid-probe
    // would be the same lie as an empty list.
    #expect(AgentLauncherModel.headerTitle(rows: rows, isProbing: true) == "Agents (checking…)")
}

@Test("Resolved rows carry name, state, and the availability reason as text")
func agentLauncherResolvedRowsCarryReasons() throws {
    let options = [
        agentOption(.claudeCode, availability: .ready(URL(fileURLWithPath: "/usr/bin/claude"))),
        agentOption(.codex, availability: .notInstalled),
        agentOption(
            .geminiCLI, availability: .notAuthenticated("Not logged in — run `gemini` once.")),
        agentOption(
            .kimi, availability: .ready(URL(fileURLWithPath: "/usr/bin/kimi")),
            note: "Launch shape unverified."),
    ]

    let rows = AgentLauncherModel.rows(options: options)

    #expect(rows.map(\.id) == [.claudeCode, .codex, .geminiCLI, .kimi])

    let ready = try #require(rows.first { $0.id == .claudeCode })
    #expect(ready.state == .ready)
    #expect(ready.isLaunchable)
    #expect(ready.statusText == "Ready")
    #expect(ready.accessibilityLabel == "Claude Code, ready")

    let missing = try #require(rows.first { $0.id == .codex })
    #expect(!missing.isLaunchable)
    #expect(missing.statusText == AgentTerminalAvailability.notInstalled.reason)
    #expect(missing.accessibilityLabel.hasPrefix("Codex, unavailable, "))
    #expect(missing.accessibilityLabel.contains("Not installed"))

    let unauthenticated = try #require(rows.first { $0.id == .geminiCLI })
    #expect(!unauthenticated.isLaunchable)
    #expect(unauthenticated.statusText == "Not logged in — run `gemini` once.")
    #expect(unauthenticated.accessibilityLabel.contains("Not logged in"))

    // A ready CLI with an unverified launch shape shows the caveat instead of
    // a bare "Ready" — AT-01's note is never suppressed by the new layout.
    let caveated = try #require(rows.first { $0.id == .kimi })
    #expect(caveated.isLaunchable)
    #expect(caveated.statusText == "Launch shape unverified.")
    #expect(caveated.accessibilityLabel == "Kimi CLI, ready, Launch shape unverified.")

    #expect(AgentLauncherModel.readyCount(rows) == 2)
    #expect(
        AgentLauncherModel.headerTitle(rows: rows, isProbing: false) == "Agents (2 of 4 ready)")
}

@Test("Named launch cells retain full provider help in every state")
func agentLauncherTooltipsAlwaysNameTheProvider() throws {
    // WP-30 restores a visible short provider name. Tooltip and accessibility
    // strings still carry the full provider plus readiness/reason, so neither
    // may ever reduce to a bare state string.
    for row in AgentLauncherModel.probingRows() {
        #expect(row.tooltip.contains(row.displayName))
        #expect(row.tooltip.contains("checking"))
        #expect(row.accessibilityLabel.contains(row.displayName))
    }

    let options = [
        agentOption(.claudeCode, availability: .ready(URL(fileURLWithPath: "/usr/bin/claude"))),
        agentOption(.codex, availability: .notInstalled),
        agentOption(
            .geminiCLI, availability: .notAuthenticated("Not logged in — run `gemini` once.")),
        agentOption(
            .kimi, availability: .ready(URL(fileURLWithPath: "/usr/bin/kimi")),
            note: "Launch shape unverified."),
    ]
    let rows = AgentLauncherModel.rows(options: options)
    for row in rows {
        #expect(row.tooltip.contains(row.displayName))
        #expect(row.accessibilityLabel.contains(row.displayName))
    }

    let ready = try #require(rows.first { $0.id == .claudeCode })
    #expect(ready.tooltip == "Launch Claude Code")

    // An unavailable card is dimmed and dashed on screen, but the REASON is
    // never left to that styling — it rides along in the tooltip.
    let missing = try #require(rows.first { $0.id == .codex })
    #expect(missing.tooltip.hasPrefix("Codex — "))
    #expect(missing.tooltip.contains(AgentTerminalAvailability.notInstalled.reason ?? ""))

    let unauthenticated = try #require(rows.first { $0.id == .geminiCLI })
    #expect(unauthenticated.tooltip.contains("Not logged in"))

    // AT-01's verification caveat survives the layout change too.
    let caveated = try #require(rows.first { $0.id == .kimi })
    #expect(caveated.tooltip == "Launch Kimi CLI — Launch shape unverified.")
}

@Test("Only a ready row yields a launchable option; pending and unavailable rows cannot launch")
func agentLauncherGatesUnavailableRows() throws {
    let options = [
        agentOption(.codex, availability: .ready(URL(fileURLWithPath: "/usr/local/bin/codex"))),
        agentOption(.cline, availability: .notInstalled),
    ]
    let rows = AgentLauncherModel.rows(options: options)
    let readyRow = try #require(rows.first { $0.id == .codex })
    let unavailableRow = try #require(rows.first { $0.id == .cline })

    #expect(AgentLauncherModel.launchableOption(for: readyRow, in: options)?.id == .codex)
    #expect(AgentLauncherModel.launchableOption(for: unavailableRow, in: options) == nil)

    // A pending row is not launchable either: the answer is still unknown.
    let pendingRow = try #require(AgentLauncherModel.probingRows().first { $0.id == .codex })
    #expect(AgentLauncherModel.launchableOption(for: pendingRow, in: options) == nil)

    // Nor can a stale ready row launch against a roster that has since gone
    // unavailable — the gate re-checks the option, not just the row.
    let staleOptions = [agentOption(.codex, availability: .notInstalled)]
    #expect(AgentLauncherModel.launchableOption(for: readyRow, in: staleOptions) == nil)
}

@MainActor
@Test("Launching a ready launcher row opens exactly one Agent Terminal for that provider")
func agentLauncherLaunchesOneSessionForThatProvider() throws {
    let workspace = WorkspaceSession()
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let options = [
        agentOption(.codex, availability: .ready(URL(fileURLWithPath: "/usr/local/bin/codex"))),
        agentOption(.cline, availability: .notInstalled),
    ]
    let rows = AgentLauncherModel.rows(options: options)
    let service = AgentTerminalLaunchService(workspaceRoot: root)

    let readyRow = try #require(rows.first { $0.id == .codex })
    let option = try #require(AgentLauncherModel.launchableOption(for: readyRow, in: options))
    let spec = try service.specification(
        option: option, model: option.defaultModel, startingDirectory: root)
    workspace.openAgentTerminal(spec: spec)

    #expect(workspace.terminal.sessions.count == 1)
    #expect(workspace.terminal.sessions.first?.agentProvider == .codex)

    // The disabled row's gate returns nil, so no second session can appear.
    let unavailableRow = try #require(rows.first { $0.id == .cline })
    #expect(AgentLauncherModel.launchableOption(for: unavailableRow, in: options) == nil)
    #expect(workspace.terminal.sessions.count == 1)
}

@MainActor
@Test("Agent identity stays wired to the shared catalog in panel rows and the Ctrl-Tab switcher")
func agentIdentityMatchesSharedCatalogAcrossSurfaces() throws {
    for id in ConductorCLIID.allCases {
        let expected = ConductorCLIIcons.icon(for: id)
        // Launcher rows, session rows, and the switcher must all resolve the
        // SAME catalog entry — no surface may grow its own mapping.
        let launcherRow = try #require(AgentLauncherModel.probingRows().first { $0.id == id })
        #expect(launcherRow.icon == expected)
        #expect(EditorTabSwitcherAgentIdentity.icon(for: id) == expected)
        #expect(expected.assetName?.hasPrefix("agent-") == true)
    }
    // A login shell has no provider and therefore no mark in either surface.
    #expect(EditorTabSwitcherAgentIdentity.icon(for: nil) == nil)

    let row = TerminalSessionRow(
        id: UUID(), displayName: "zsh", shellName: "zsh", directoryLabel: ".",
        status: .running, isParked: false, needsAttention: false, hasUserName: false,
        sessionColor: nil)
    #expect(row.agentProvider == nil)
}

// MARK: - C: reveal

@MainActor
@Test("Reveal on a parked session inserts exactly one tab and selects it")
func revealParkedInsertsAndSelectsOneTab() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let terminalGroupID = try #require(
        session.terminal.terminalGroupAndPane(containing: controller.id)?.0)
    session.hideTerminalSession(controller.id)
    #expect(session.parkedTerminalGroupIDs == [terminalGroupID])

    session.revealTerminalSession(controller.id)

    let group = session.editorLayout.group(id: session.editorLayout.focusedGroupID)
    #expect(group?.tabs.count == 1)
    #expect(group?.selectedTabID == group?.tabs.first?.id)
    #expect(group?.tabs.first?.resource == .terminalGroup(groupID: terminalGroupID))
    #expect(session.parkedTerminalGroupIDs.isEmpty)
    #expect(session.terminal.sessions.first?.id == controller.id)
}

// MARK: - D: hide/close

@MainActor
@Test("hideTerminalSession parks a presented session, leaving it alive")
func hideTerminalSessionParksPresentedSession() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let terminalGroupID = try #require(
        session.terminal.terminalGroupAndPane(containing: controller.id)?.0)

    session.hideTerminalSession(controller.id)

    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)
    #expect(session.parkedTerminalGroupIDs == [terminalGroupID])
    #expect(
        session.terminal.terminalGroup(terminalGroupID)?.panes.first?.sessionID == controller.id)
}

@MainActor
@Test("hideTerminalSession is a no-op for an already-parked or unknown session")
func hideTerminalSessionNoOpsForParkedOrUnknown() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let terminalGroupID = try #require(
        session.terminal.terminalGroupAndPane(containing: controller.id)?.0)
    session.hideTerminalSession(controller.id)
    #expect(session.parkedTerminalGroupIDs == [terminalGroupID])

    session.hideTerminalSession(controller.id)
    #expect(session.parkedTerminalGroupIDs == [terminalGroupID])

    session.hideTerminalSession(UUID())
    #expect(session.parkedTerminalGroupIDs == [terminalGroupID])
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

// MARK: - Identity in the icon slot

/// The panel row's icon well and the editor tab both showed a generic
/// terminal glyph, so five agent terminals were distinguishable only by a
/// name that middle-truncates at 20 characters. The well now carries the
/// vendor mark instead.
///
/// The risk this pins is not the icon — it is the STATUS the icon displaced.
/// Status used to live in that well as a shape-distinct glyph; it now leads
/// the caption line as a word. If a later edit drops that segment, status
/// loses its carrier entirely and nothing else fails, because no rendered
/// assertion can see a caption's composition. Hence a source contract.
@Suite("Terminal identity glyphs")
struct TerminalIdentityGlyphTests {
    @Test("The panel row wears the vendor mark and keeps status as caption text")
    func panelRowShowsIdentityAndKeepsStatusText() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")

        // Identity in the well, terminal glyph only as the login-shell fallback.
        #expect(panel.contains("if let provider = row.agentProvider {"))
        #expect(
            panel.contains("FileIconView(icon: ConductorCLIIcons.icon(for: provider), size: 15)"))
        #expect(panel.contains(#"Image(systemName: "terminal")"#))
        // Status survives as a WORD in the caption — the carrier that replaced
        // the glyph. Losing this line is the regression worth failing on.
        #expect(
            panel.contains(
                #"\(TerminalSessionPresentation.label(row.status)) · \(row.shellName)"#))
        // The status glyph now sits beside status text in the caption, not in
        // the identity well. This shape+text pair keeps attention and exit
        // legible without hue.
        #expect(
            panel.contains("Image(systemName: TerminalSessionPresentation.symbol(row.status))"))
        // And the mark must not ALSO sit beside the name — one row, one mark.
        #expect(!panel.contains("ConductorCLIIcons.icon(for: provider), size: 14"))
    }

    /// The mark is legitimate only because it is never alone: `agentProvider`
    /// is derived from the launch spec, and the row's accessibility text still
    /// names the session and its status independently of any icon.
    @MainActor
    @Test("A login shell has no provider, so the fallback path is real")
    func loginShellHasNoProvider() throws {
        let session = WorkspaceSession()
        session.newTerminalTab()
        let rows = TerminalsPanelModel.rows(
            sessions: session.terminal.sessions,
            presentedIDs: session.presentedTerminalSessionIDs,
            workspaceRoot: session.rootURL?.path
        )
        let row = try #require(rows.first)
        #expect(row.agentProvider == nil)
        #expect(!TerminalSessionPresentation.label(row.status).isEmpty)
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw TerminalIdentityGlyphError.repositoryRootNotFound
    }

    private enum TerminalIdentityGlyphError: Error {
        case repositoryRootNotFound
    }
}
