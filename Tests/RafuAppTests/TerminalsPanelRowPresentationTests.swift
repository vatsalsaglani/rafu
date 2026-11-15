import Foundation
import Testing

@testable import RafuApp

/// The Terminals panel "tuned rows" (sidebar redesign): each line has its own
/// job, look-alike rows get an ordinal, and a status word appears only when
/// the state is not the normal one.
@Suite("Terminals panel row presentation")
struct TerminalsPanelRowPresentationTests {
    typealias N = TerminalNaming

    // MARK: Title

    @Test("The title is the user name, then the agent title, then the agent or shell")
    func titlePrecedence() {
        // A group name the user typed wins over everything.
        #expect(
            N.panelTitle(
                storedGroupName: "api", paneUserName: "server", agentTitle: "Fix tests",
                providerOrShell: "zsh") == "api")
        // An automatic group name gives way to the pane's user name.
        #expect(
            N.panelTitle(
                storedGroupName: "Terminal Group 2", paneUserName: "server",
                agentTitle: "Fix tests", providerOrShell: "zsh") == "server")
        // Then the agent's session title.
        #expect(
            N.panelTitle(
                storedGroupName: "Terminal Group 2", paneUserName: nil,
                agentTitle: "Fix flaky tests", providerOrShell: "Claude Code")
                == "Fix flaky tests")
        // Then the agent or shell name; never "Terminal Group 2", never a folder.
        #expect(
            N.panelTitle(
                storedGroupName: "Terminal Group 2", paneUserName: nil, agentTitle: nil,
                providerOrShell: "fish") == "fish")
        #expect(
            N.panelTitle(
                storedGroupName: "Terminal", paneUserName: "  ", agentTitle: nil,
                providerOrShell: "Claude Code") == "Claude Code")
    }

    @Test("Look-alike rows get an ordinal in creation order; user names never change")
    func duplicateOrdinals() {
        let titles = N.disambiguatedTitles([
            ("Claude Code", "rafu", false),
            ("fish", "rafu", false),
            ("Claude Code", "rafu", false),
            ("Claude Code", "docs", false),
            ("Claude Code", "rafu", false),
            ("api", "zsh · rafu", true),
            ("api", "zsh · rafu", true),
        ])
        #expect(
            titles == [
                "Claude Code", "fish", "Claude Code 2", "Claude Code", "Claude Code 3", "api",
                "api",
            ])
    }

    // MARK: Second line

    @Test("The context never repeats the title and carries the folder")
    func contextLine() {
        #expect(
            N.panelContext(
                title: "Fix flaky tests", providerOrShell: "Claude Code", folder: "rafu",
                paneCount: 1) == "Claude Code · rafu")
        #expect(
            N.panelContext(
                title: "Claude Code", providerOrShell: "Claude Code", folder: "rafu", paneCount: 1)
                == "rafu")
        #expect(
            N.panelContext(title: "fish", providerOrShell: "fish", folder: nil, paneCount: 1)
                == "")
        #expect(
            N.panelContext(title: "fish", providerOrShell: "fish", folder: "rafu", paneCount: 4)
                == "4 panes · rafu")
    }

    @Test("The subtitle leads with an abnormal word and ends with the placement")
    func subtitleComposition() {
        #expect(
            N.panelSubtitle(
                statusWord: "Needs approval", context: "Claude Code · rafu", placement: "Ensemble")
                == "Needs approval · Claude Code · rafu · Ensemble")
        #expect(N.panelSubtitle(statusWord: nil, context: "rafu", placement: nil) == "rafu")
        #expect(N.panelPlacement(isCanvasOwned: true, isParked: true) == "Ensemble")
        #expect(N.panelPlacement(isCanvasOwned: false, isParked: true) == "Hidden")
        #expect(N.panelPlacement(isCanvasOwned: false, isParked: false) == nil)
    }

    // MARK: Status word rule

    @Test("Normal states have no word; abnormal states always do")
    func statusWordRule() {
        // Normal: a running or idle shell, a working, done or inactive agent.
        #expect(
            N.abnormalStatusWord(agentStatus: nil, paneStatus: .live, hasAttention: false) == nil)
        #expect(
            N.abnormalStatusWord(agentStatus: nil, paneStatus: .idle, hasAttention: false) == nil)
        for status in [AgentCardStatus.working, .done, .doneUnread, .inactive] {
            #expect(
                N.abnormalStatusWord(agentStatus: status, paneStatus: .live, hasAttention: false)
                    == nil)
        }
        // Abnormal: the word leads the second line.
        #expect(
            N.abnormalStatusWord(agentStatus: nil, paneStatus: .live, hasAttention: true)
                == "Needs attention")
        #expect(
            N.abnormalStatusWord(agentStatus: nil, paneStatus: .exited, hasAttention: false)
                == "Exited")
        #expect(
            N.abnormalStatusWord(agentStatus: nil, paneStatus: .stopped, hasAttention: false)
                == "Stopped")
        #expect(
            N.abnormalStatusWord(agentStatus: nil, paneStatus: .unavailable, hasAttention: false)
                == "Unavailable")
        #expect(
            N.abnormalStatusWord(
                agentStatus: .needsYou(.approval), paneStatus: .live, hasAttention: true)
                == "Needs approval")
        #expect(
            N.abnormalStatusWord(agentStatus: .failed, paneStatus: .live, hasAttention: false)
                == "Failed")
        #expect(
            N.abnormalStatusWord(agentStatus: .stopped, paneStatus: .exited, hasAttention: false)
                == "Stopped")
        #expect(
            N.abnormalStatusWord(agentStatus: .working, paneStatus: .live, hasAttention: true)
                == "Needs attention")
    }

    @Test("Group and ungrouped-session words follow the same rule")
    func groupAndSessionWords() {
        #expect(N.abnormalGroupStatusWord(attentionCount: 0, livePaneCount: 2) == nil)
        #expect(N.abnormalGroupStatusWord(attentionCount: 0, livePaneCount: 0) == "Not running")
        #expect(
            N.abnormalGroupStatusWord(attentionCount: 2, livePaneCount: 3) == "2 need attention")
        #expect(N.abnormalSessionStatusWord(.running) == nil)
        #expect(N.abnormalSessionStatusWord(.idle) == nil)
        #expect(N.abnormalSessionStatusWord(.bell) == "Needs attention")
        #expect(N.abnormalSessionStatusWord(.exited(code: 1)) == "Exited (1)")
    }

    @Test("Every shell state has its own glyph shape")
    func shellGlyphsAreShapeDistinct() {
        let statuses: [TerminalPaneStatus] = [.idle, .live, .exited, .stopped, .unavailable]
        let symbols = statuses.map { N.shellStatusSymbol(paneStatus: $0, hasAttention: false) }
        #expect(Set(symbols).count == statuses.count)
        #expect(N.shellStatusSymbol(paneStatus: .live, hasAttention: true) == "bell.fill")
        #expect(!symbols.contains("bell.fill"))
    }

    // MARK: Pane rows

    @Test("A pane row is the user name, a real title, or the shell name")
    func paneRowTitles() {
        #expect(
            N.paneRowTitle(
                userName: "server", reportedTitle: "npm run dev", providerOrShell: "zsh",
                shellName: "zsh", provider: nil) == "server")
        #expect(
            N.paneRowTitle(
                userName: nil, reportedTitle: "npm run dev", providerOrShell: "zsh",
                shellName: "zsh", provider: nil) == "npm run dev")
        // A path, the shell itself, or a bare agent name is not a title.
        #expect(
            N.paneRowTitle(
                userName: nil, reportedTitle: "~/src/rafu", providerOrShell: "zsh",
                shellName: "zsh", provider: nil) == "zsh")
        #expect(
            N.paneRowTitle(
                userName: nil, reportedTitle: "zsh", providerOrShell: "zsh", shellName: "zsh",
                provider: nil) == "zsh")
        #expect(
            N.paneRowTitle(
                userName: nil, reportedTitle: "✳ Claude Code", providerOrShell: "Claude Code",
                shellName: "zsh", provider: .claudeCode) == "Claude Code")
    }

    // MARK: Saved section

    @Test("The Saved section starts collapsed when empty; the user's choice wins")
    func savedSectionExpansion() {
        typealias S = TerminalGroupSavedLayoutsPresentation
        #expect(!S.isExpanded(userChoice: nil, state: .empty))
        #expect(!S.isExpanded(userChoice: nil, state: .loading))
        #expect(S.isExpanded(userChoice: nil, state: .records))
        #expect(S.isExpanded(userChoice: true, state: .empty))
        #expect(!S.isExpanded(userChoice: false, state: .records))
        // An error is never hidden behind a collapsed header.
        #expect(S.isExpanded(userChoice: false, state: .error("Disk unavailable")))
        #expect(S.userChoice(fromStored: "") == nil)
        #expect(S.userChoice(fromStored: "open") == true)
        #expect(S.userChoice(fromStored: "closed") == false)
    }

    // MARK: Model integration

    @MainActor
    @Test("Two look-alike shells in one folder read zsh and zsh 2, with no folder in the title")
    func hierarchyRowsDisambiguate() throws {
        let manager = WorkspaceTerminalManager()
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let first = try manager.createLiveGroup(
            name: TerminalGroupName("Terminal Group 1"),
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        let second = try manager.createLiveGroup(
            name: TerminalGroupName("Terminal Group 2"),
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        let named = try manager.createLiveGroup(
            name: TerminalGroupName("Build"),
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )

        let rows = TerminalsPanelModel.hierarchyRows(
            groups: manager.terminalGroups,
            presentedGroupIDs: [first.id, second.id, named.id],
            currentGroupID: nil,
            controllers: manager.sessions, presentedLegacySessionIDs: [],
            currentLegacySessionID: nil, workspaceRoot: "/tmp")
        let groups = rows.compactMap { row -> TerminalsPanelModel.TerminalGroupRow? in
            guard case .group(let group) = row else { return nil }
            return group
        }
        let panes = rows.compactMap { row -> TerminalsPanelModel.TerminalPaneRow? in
            guard case .pane(let pane) = row else { return nil }
            return pane
        }

        #expect(groups.first { $0.id == first.id }?.rowTitle == "zsh")
        #expect(groups.first { $0.id == second.id }?.rowTitle == "zsh 2")
        #expect(groups.first { $0.id == first.id }?.context == "tmp")
        #expect(groups.first { $0.id == first.id }?.isUserNamed == false)
        #expect(groups.first { $0.id == named.id }?.rowTitle == "Build")
        #expect(groups.first { $0.id == named.id }?.context == "zsh · tmp")
        #expect(groups.first { $0.id == named.id }?.isUserNamed == true)
        #expect(groups.first { $0.id == first.id }?.fullPath == "/tmp")
        // The stored name and rename seed do not change.
        #expect(groups.first { $0.id == second.id }?.name == "Terminal Group 2")
        // Pane ordinals start at 1 in pane order.
        #expect(panes.allSatisfy { $0.ordinal == 1 })
        #expect(panes.allSatisfy { $0.rowTitle == "zsh" })
        #expect(panes.allSatisfy { $0.folderIfDifferent == nil })
    }
}
