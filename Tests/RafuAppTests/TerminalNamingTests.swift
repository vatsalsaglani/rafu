import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal naming and wording")
struct TerminalNamingTests {
    @Test("Only Rafu-generated group names count as automatic")
    func automaticGroupNames() {
        #expect(TerminalNaming.isAutomaticGroupName("Terminal"))
        #expect(TerminalNaming.isAutomaticGroupName("Terminal Group 1"))
        #expect(TerminalNaming.isAutomaticGroupName("Terminal Group 42"))
        #expect(TerminalNaming.isAutomaticGroupName("  Terminal Group 7  "))
        #expect(!TerminalNaming.isAutomaticGroupName("Terminal Group"))
        #expect(!TerminalNaming.isAutomaticGroupName("Terminal Group 3 copy"))
        #expect(!TerminalNaming.isAutomaticGroupName("Terminal Group x"))
        #expect(!TerminalNaming.isAutomaticGroupName("Build"))
        #expect(!TerminalNaming.isAutomaticGroupName("My Terminal"))
        #expect(!TerminalNaming.isAutomaticGroupName(""))
    }

    @Test("A group title resolves user group name, then pane name, then agent title")
    func resolvedGroupTitles() {
        typealias N = TerminalNaming
        // A name the user gave the group always wins.
        #expect(
            N.resolvedGroupTitle(storedName: "Build", paneUserName: "ONe", agentTitle: "Claude")
                == "Build")
        // An automatic name gives way to the pane's user name first.
        #expect(
            N.resolvedGroupTitle(
                storedName: "Terminal Group 1", paneUserName: "ONe", agentTitle: "Claude Code")
                == "ONe")
        #expect(
            N.resolvedGroupTitle(storedName: "Terminal", paneUserName: " ONe ", agentTitle: nil)
                == "ONe")
        // Then to the agent title.
        #expect(
            N.resolvedGroupTitle(
                storedName: "Terminal Group 1", paneUserName: nil, agentTitle: "Claude Code")
                == "Claude Code")
        #expect(
            N.resolvedGroupTitle(
                storedName: "Terminal Group 1", paneUserName: "  ", agentTitle: "Codex")
                == "Codex")
        // Otherwise the stored name stays.
        #expect(
            N.resolvedGroupTitle(storedName: "Terminal Group 1", paneUserName: nil, agentTitle: "")
                == "Terminal Group 1")
    }

    @Test("Folder names come from the working directory, then the workspace root")
    func folderNames() {
        let root = "/Users/me/code/fixtures"
        #expect(TerminalNaming.folderName(path: "/Users/me/code/api", workspaceRoot: root) == "api")
        #expect(TerminalNaming.folderName(path: "\(root)/", workspaceRoot: root) == "fixtures")
        #expect(TerminalNaming.folderName(path: root, workspaceRoot: root) == "fixtures")
        #expect(TerminalNaming.folderName(path: ".", workspaceRoot: root) == "fixtures")
        #expect(TerminalNaming.folderName(path: nil, workspaceRoot: root) == "fixtures")
        #expect(TerminalNaming.folderName(path: "", workspaceRoot: root) == "fixtures")
        #expect(TerminalNaming.folderName(path: "src/api", workspaceRoot: root) == "api")
        #expect(TerminalNaming.folderName(path: ".", workspaceRoot: nil) == nil)
        #expect(TerminalNaming.folderName(path: nil, workspaceRoot: nil) == nil)
        #expect(TerminalNaming.folderName(path: "/", workspaceRoot: root) == "/")
        #expect(
            TerminalNaming.folderName(
                path: "/Users/me", workspaceRoot: root, homeDirectory: "/Users/me") == "~")
    }

    @Test("Automatic names join command and folder with an em dash")
    func automaticNames() {
        #expect(
            TerminalNaming.automaticName(command: "zsh", folder: "fixtures") == "zsh — fixtures")
        #expect(TerminalNaming.automaticName(command: "claude", folder: "api") == "claude — api")
        #expect(TerminalNaming.automaticName(command: "zsh", folder: nil) == "zsh")
        #expect(TerminalNaming.automaticName(command: "zsh", folder: "") == "zsh")
        #expect(TerminalNaming.automaticName(command: " ", folder: "api") == "api")
        #expect(TerminalNaming.automaticName(command: " zsh ", folder: "api") == "zsh — api")
    }

    @Test("Pane counts use the correct plural")
    func paneCounts() {
        #expect(TerminalNaming.paneCountLabel(0) == "0 panes")
        #expect(TerminalNaming.paneCountLabel(1) == "1 pane")
        #expect(TerminalNaming.paneCountLabel(2) == "2 panes")
        #expect(TerminalNaming.paneCountLabel(10) == "10 panes")
    }

    @Test("Group state is Running or Not running, never Parked")
    func groupState() {
        #expect(TerminalNaming.groupStateLabel(livePaneCount: 0) == "Not running")
        #expect(TerminalNaming.groupStateLabel(livePaneCount: 1) == "Running")
        #expect(TerminalNaming.groupStateLabel(livePaneCount: 3) == "Running")
        #expect(
            TerminalNaming.groupSummary(paneCount: 1, livePaneCount: 0, attentionCount: 0)
                == "1 pane · Not running")
        #expect(
            TerminalNaming.groupSummary(paneCount: 2, livePaneCount: 1, attentionCount: 0)
                == "2 panes · Running")
        #expect(
            TerminalNaming.groupSummary(paneCount: 2, livePaneCount: 2, attentionCount: 1)
                == "2 panes · Running · 1 needs attention")
        #expect(
            TerminalNaming.groupSummary(paneCount: 3, livePaneCount: 3, attentionCount: 2)
                == "3 panes · Running · 2 need attention")
    }

    @Test("Subtitles drop empty parts and the bare root dot")
    func subtitles() {
        #expect(TerminalNaming.subtitle(["Shell", "Stopped", "."]) == "Shell · Stopped")
        #expect(TerminalNaming.subtitle(["Shell", "Stopped", ""]) == "Shell · Stopped")
        #expect(TerminalNaming.subtitle(["Shell", "Running", "api"]) == "Shell · Running · api")
        #expect(TerminalNaming.subtitle(["", ".", " "]) == "")
        #expect(!TerminalNaming.subtitle(["Shell", "Stopped", "."]).hasSuffix("·"))
    }

    @Test("Shells with the same name get their path in the menu title")
    func shellMenuTitles() {
        let system = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: false)
        let brewed = TerminalShell(path: "/opt/homebrew/bin/zsh", name: "zsh", isDefault: false)
        let fish = TerminalShell(
            path: "/opt/homebrew/bin/fish", name: "Default (fish)", isDefault: true)
        let all = [fish, system, brewed]

        #expect(TerminalNaming.shellMenuTitle(for: fish, among: all) == "Default (fish)")
        #expect(TerminalNaming.shellMenuTitle(for: system, among: all) == "zsh — /bin/zsh")
        #expect(
            TerminalNaming.shellMenuTitle(for: brewed, among: all)
                == "zsh — /opt/homebrew/bin/zsh")
        #expect(TerminalNaming.shellMenuTitle(for: system, among: [system]) == "zsh")
    }

    @MainActor
    @Test("A default-named group shows an automatic name; a user-named group keeps its name")
    func hierarchyRowsUseAutomaticNames() throws {
        let manager = WorkspaceTerminalManager()
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let automatic = try manager.createLiveGroup(
            instantiation: .ordinaryShell(
                startingDirectory: "/tmp/fixtures", shell: shell, profile: profile))
        let named = try manager.createLiveGroup(
            name: TerminalGroupName("Build"),
            instantiation: .ordinaryShell(
                startingDirectory: "/tmp/fixtures", shell: shell, profile: profile))

        let rows = TerminalsPanelModel.hierarchyRows(
            groups: manager.terminalGroups,
            presentedGroupIDs: [automatic.id, named.id],
            currentGroupID: automatic.id,
            controllers: manager.sessions, presentedLegacySessionIDs: [],
            currentLegacySessionID: nil, workspaceRoot: "/tmp/fixtures")
        let groups = rows.compactMap { row -> TerminalsPanelModel.TerminalGroupRow? in
            guard case .group(let group) = row else { return nil }
            return group
        }
        let panes = rows.compactMap { row -> TerminalsPanelModel.TerminalPaneRow? in
            guard case .pane(let pane) = row else { return nil }
            return pane
        }

        let automaticRow = try #require(groups.first { $0.id == automatic.id })
        #expect(automaticRow.name.hasPrefix("Terminal Group"))
        #expect(automaticRow.displayName == "zsh — fixtures")
        #expect(automaticRow.summary == "1 pane · Running")

        let namedRow = try #require(groups.first { $0.id == named.id })
        #expect(namedRow.automaticName == nil)
        #expect(namedRow.displayName == "Build")

        // An unnamed pane reads "zsh — fixtures", and its subtitle has no
        // trailing separator.
        let pane = try #require(panes.first { $0.groupID == automatic.id })
        #expect(pane.name == "zsh — fixtures")
        #expect(!pane.subtitle.hasSuffix("·"))
        #expect(!pane.subtitle.contains("Parked"))
    }
}
