import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal Group restoration codec")
struct TerminalGroupRestorationTests {
    @Test("A shell snapshot saves safe metadata and opens with fresh identities")
    func shellRoundTripUsesFreshRuntimeIDs() throws {
        let original = try snapshot()
        let record = try TerminalGroupRestorationCodec().savedRecord(from: original)
        let first = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot
        let second = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot

        #expect(first.id != second.id)
        #expect(first.root.paneIDs != second.root.paneIDs)
        #expect(first.root.splitIDs != second.root.splitIDs)
        #expect(first.panes.allSatisfy { $0.sessionID == nil && $0.status == .stopped })
        #expect(first.savedLayoutID == record.id)
        #expect(first.name == original.name)
        #expect(first.panes.allSatisfy { $0.explicitUserName == TerminalPaneName("Explicit pane") })
    }

    @Test("Agent and Ensemble panes become fixed unavailable placeholders")
    func agentAndEnsemblePanesAreUnavailable() throws {
        let agent = try pane(runtimeKind: .directAgentTerminal(provider: .codex))
        let ensemble = try pane(runtimeKind: .ensembleRole)
        let root = TerminalGroupNode.split(
            id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5,
            first: .pane(agent.id), second: .pane(ensemble.id))
        let group = try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Safe")), root: root,
            focusedPaneID: agent.id, savedLayoutID: nil, panes: [agent, ensemble],
            retainedPaneCount: 2)

        let record = try TerminalGroupRestorationCodec().savedRecord(from: group)
        #expect(Set(record.panes.map(\.kind)) == [.unavailableAgentTerminal, .unavailableEnsemble])
        #expect(record.panes.allSatisfy { $0.launchProfile == nil })
        #expect(record.panes.allSatisfy { $0.kind.unavailableMessage != nil })
        #expect(
            SavedTerminalPaneKind.unavailableAgentTerminal.unavailableMessage
                == "Agent Terminal profiles are not saved in this version.")
        #expect(
            SavedTerminalPaneKind.unavailableEnsemble.unavailableMessage
                == "Ensemble terminal profiles are not saved in this version.")

        let opened = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot
        #expect(opened.panes.allSatisfy { $0.sessionID == nil && $0.status == .unavailable })
        #expect(opened.panes.allSatisfy { $0.launchProfile == nil })
        let decoded = try TerminalGroupRestorationCodec().openNamedLayout(record)
        #expect(decoded.paneValidation.values.contains(.unavailableAgentTerminal))
        #expect(decoded.paneValidation.values.contains(.unavailableEnsemble))
    }

    @Test("Open-instance restoration retains one tab identity but removes sessions")
    func openInstanceUsesItsExistingRuntimeIDs() throws {
        let groupID = TerminalGroupID()
        let paneID = TerminalPaneID()
        let record = try TerminalGroupOpenTabRestorationRecord(
            groupID: groupID, name: try #require(TerminalGroupName("Restored")),
            root: .pane(paneID),
            focusedPaneID: paneID, savedLayoutID: SavedTerminalGroupID(),
            panes: [
                try TerminalGroupOpenPaneRestorationRecord(
                    id: paneID, explicitUserName: nil, themeColor: .accent, kind: .ordinaryShell,
                    launchProfile: profile())
            ])

        let restored = try TerminalGroupRestorationCodec().restoreOpenInstance(record).snapshot
        #expect(restored.id == groupID)
        #expect(restored.root.paneIDs == [paneID])
        #expect(restored.panes.allSatisfy { $0.sessionID == nil && $0.status == .stopped })
    }

    @Test("Missing dependencies produce stopped recoverable panes without substitution")
    func missingDependenciesAreRecoverablePaneResults() throws {
        let record = try TerminalGroupRestorationCodec().savedRecord(from: snapshot())
        let codec = TerminalGroupRestorationCodec(validateProfile: { _ in .missingFolder })
        let decoded = try codec.openNamedLayout(record)
        let pane = try #require(decoded.snapshot.panes.first)

        #expect(decoded.paneValidation[pane.id] == .missingFolder)
        #expect(pane.status == .stopped)
        #expect(pane.startAvailability == .unavailable)
        #expect(pane.launchProfile == profile())
    }

    @Test("Missing shell approval remains a recoverable stopped-pane result")
    func missingShellApprovalIsRecoverable() throws {
        let record = try TerminalGroupRestorationCodec().savedRecord(from: snapshot())
        let codec = TerminalGroupRestorationCodec(validateProfile: { _ in .unapprovedShell })
        let decoded = try codec.openNamedLayout(record)
        let pane = try #require(decoded.snapshot.panes.first)

        #expect(decoded.paneValidation[pane.id] == .unapprovedShell)
        #expect(pane.status == .stopped)
        #expect(pane.startAvailability == .unavailable)
        #expect(pane.launchProfile == profile())
    }

    @Test("Traversal and absolute folder inputs are rejected by the safe profile type")
    func unsafeFolderInputsAreRejected() {
        #expect(TerminalWorkspaceRelativePath("../outside") == nil)
        #expect(TerminalWorkspaceRelativePath("/absolute") == nil)
        #expect(TerminalWorkspaceRelativePath("safe/../outside") == nil)
    }

    private func snapshot() throws -> TerminalGroupSnapshot {
        let firstPane = try pane(runtimeKind: .ordinaryShell)
        let secondPane = try pane(runtimeKind: .ordinaryShell)
        return try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Shell layout")),
            root: .split(
                id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                first: .pane(firstPane.id), second: .pane(secondPane.id)),
            focusedPaneID: firstPane.id, savedLayoutID: nil, panes: [firstPane, secondPane],
            retainedPaneCount: 2)
    }

    private func pane(runtimeKind: TerminalPaneRuntimeKind) throws -> TerminalPaneSnapshot {
        let ordinary = runtimeKind == .ordinaryShell
        return try TerminalPaneSnapshot(
            id: TerminalPaneID(), sessionID: ordinary ? UUID() : nil,
            explicitUserName: TerminalPaneName("Explicit pane"),
            reportedTitle: TerminalReportedTitle("OSC title must not persist"),
            runtimeKind: runtimeKind,
            themeColor: .info, status: ordinary ? .live : .idle,
            launchProfile: ordinary ? profile() : nil,
            startAvailability: ordinary ? .available : .notRestartable)
    }

    private func profile() -> TerminalPaneLaunchProfile {
        TerminalPaneLaunchProfile(
            shell: .approvedShellPath("/bin/zsh"),
            startingFolder: TerminalWorkspaceRelativePath("project")!)
    }
}
