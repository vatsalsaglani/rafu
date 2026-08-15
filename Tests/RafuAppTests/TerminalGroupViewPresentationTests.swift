import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal Group recursive renderer")
struct TerminalGroupViewPresentationTests {
    @Test("Snapshot tree preserves stable pane and nested split identities")
    func snapshotTreePreservesIdentity() throws {
        let first = TerminalPaneID()
        let second = TerminalPaneID()
        let third = TerminalPaneID()
        let outer = TerminalGroupSplitID()
        let inner = TerminalGroupSplitID()
        let snapshot = try makeSnapshot(
            root: .split(
                id: outer,
                axis: .columns,
                fraction: 0.35,
                first: .pane(first),
                second: .split(
                    id: inner,
                    axis: .rows,
                    fraction: 0.65,
                    first: .pane(second),
                    second: .pane(third)
                )
            ),
            focused: second,
            panes: [first, second, third]
        )

        #expect(snapshot.root.paneIDs == [first, second, third])
        #expect(snapshot.root.splitIDs == [outer, inner])
    }

    @Test("Pane chrome exposes stopped, exited, unavailable, and live labels")
    func paneStatesRemainTextual() {
        #expect(
            TerminalPanePresentation.statusLabel(
                for: terminalPane(status: .stopped), controllerStatus: nil) == "Stopped")
        #expect(
            TerminalPanePresentation.statusLabel(
                for: terminalPane(status: .exited), controllerStatus: nil) == "Exited")
        #expect(
            TerminalPanePresentation.statusLabel(
                for: terminalPane(status: .unavailable), controllerStatus: nil) == "Unavailable")
        #expect(
            TerminalPanePresentation.statusLabel(
                for: terminalPane(status: .live), controllerStatus: .running) == "Running")
    }

    @Test("Renderer neither owns a workspace nor creates terminal controllers in its body")
    func rendererOwnershipBoundary() throws {
        let source = try Self.source("Sources/RafuApp/Terminal/TerminalGroupView.swift")

        #expect(source.contains("struct TerminalGroupView: View"))
        #expect(source.contains("TerminalGroupSplitView("))
        #expect(source.contains(".id(paneID)"))
        #expect(source.contains(".id(id)"))
        #expect(source.contains("Agent Terminal profiles are not saved in this version."))
        #expect(!source.contains("WorkspaceSession"))
        #expect(!source.contains("WorkspaceTerminalController("))
        #expect(!source.contains("makeOrReuseView"))
        #expect(!source.contains(".clipShape("))
        #expect(!source.contains(".mask("))
    }

    private func makeSnapshot(
        root: TerminalGroupNode,
        focused: TerminalPaneID,
        panes: [TerminalPaneID]
    ) throws -> TerminalGroupSnapshot {
        try TerminalGroupSnapshot(
            id: TerminalGroupID(),
            name: try #require(TerminalGroupName("Renderer")),
            root: root,
            focusedPaneID: focused,
            savedLayoutID: nil,
            panes: panes.map { terminalPane(id: $0, status: .live) },
            retainedPaneCount: panes.count
        )
    }

    @Test("Provider, folder, focus, and accessibility presentation stay truthful")
    func paneMetadataPresentation() throws {
        let directAgent = try TerminalPaneSnapshot(
            id: TerminalPaneID(),
            sessionID: UUID(),
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .directAgentTerminal(provider: .codex),
            themeColor: nil,
            status: .live,
            launchProfile: nil,
            startAvailability: .notRestartable
        )
        let source = try Self.source("Sources/RafuApp/Terminal/TerminalGroupView.swift")

        #expect(TerminalPanePresentation.providerIdentity(for: directAgent.runtimeKind) == "Codex")
        #expect(TerminalPanePresentation.folderLabel(for: directAgent) == nil)
        #expect(source.contains("Label(\"Focused pane\""))
        #expect(source.contains("No saved starting folder"))
        #expect(source.contains("provider.displayName"))
        #expect(!source.contains("startingFolder.rawValue ?? \".\""))
    }

    @Test("Pane chrome provides only the permitted local actions")
    func paneChromeActionsStayTyped() throws {
        let source = try Self.source("Sources/RafuApp/Terminal/TerminalGroupView.swift")

        #expect(source.contains("case close(TerminalPaneID)"))
        #expect(source.contains("case restart(TerminalPaneID)"))
        #expect(source.contains("case start(TerminalPaneID)"))
        #expect(source.contains("Button(\"Restart\""))
        #expect(source.contains("Button(\"Start Pane\""))
        #expect(source.contains("Button(\"Close\""))
        #expect(!source.contains("shutdown()"))
        #expect(!source.contains("restart()"))
    }

    private func terminalPane(id: TerminalPaneID = TerminalPaneID(), status: TerminalPaneStatus)
        -> TerminalPaneSnapshot
    {
        try! TerminalPaneSnapshot(
            id: id,
            sessionID: status == .unavailable ? nil : UUID(),
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: status == .unavailable ? .unavailableAgentTerminal : .ordinaryShell,
            themeColor: nil,
            status: status,
            launchProfile: nil,
            startAvailability: status == .unavailable ? .unavailable : .notRestartable
        )
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
        throw TerminalGroupViewPresentationTestError.repositoryRootNotFound
    }

    private enum TerminalGroupViewPresentationTestError: Error {
        case repositoryRootNotFound
    }
}
