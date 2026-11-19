import Foundation
import Testing

@testable import RafuApp

@Suite("Ensembles navigator integration")
struct CanvasNavigatorPanelContractTests {
    @Test("The new rail mode has a title, symbol, and restorable raw value")
    func modeIdentity() throws {
        let mode = WorkspaceNavigatorMode.ensemble
        #expect(mode.title == "Ensembles")
        #expect(mode.symbolName == CanvasBoardState.ensembleSymbol)
        #expect(mode.rawValue == "ensemble")
        let encoded = try JSONEncoder().encode(mode)
        #expect(try JSONDecoder().decode(WorkspaceNavigatorMode.self, from: encoded) == mode)
    }

    @MainActor
    @Test("Show Ensembles selects the panel and expands the sidebar")
    func showsPanel() {
        let session = WorkspaceSession()
        session.isSidebarCollapsed = true

        session.showEnsembles()

        #expect(session.navigatorMode == .ensemble)
        #expect(!session.isSidebarCollapsed)
    }

    @Test("The delete sheet has a stable ID across revisions of one record")
    func deleteDialogID() {
        let id = CanvasID()
        let first = CanvasDialog.deleteSaved(.init(id: id, title: "First", revision: 1))
        let renamed = CanvasDialog.deleteSaved(.init(id: id, title: "Second", revision: 2))
        #expect(first.id == "delete-\(id.rawValue)")
        #expect(first.id == renamed.id)
    }

    @Test("The panel uses the shared header, top alignment, and task-based rows")
    func panelStructure() throws {
        let panel = try source("Canvas/Views/CanvasNavigatorPanelView.swift")
        #expect(panel.contains("RafuUtilityPanelHeader("))
        #expect(panel.contains("alignment: .top"))
        #expect(panel.contains(".task(id: inputs)"))
        #expect(panel.contains("CanvasCardCommands.agentCardStatus(pane: pane, in: session)"))
    }

    @Test("The menu and palette expose Show Ensembles and its key equivalent")
    func commandEntryPoints() throws {
        let commands = try source("App/RafuAppCommands.swift")
        let shortcut = #".keyboardShortcut("e", modifiers: [.command, .shift])"#
        #expect(commands.components(separatedBy: shortcut).count == 2)
        #expect(commands.contains(#"Button("Show Ensembles")"#))
        let palette = try source("Views/CommandPaletteView.swift")
        #expect(palette.contains(#"title: "Show Ensembles""#))
        #expect(palette.contains(#"shortcut: "⌘⇧E""#))
    }

    @Test("Panel and model string literals use the Ensemble terminology")
    func terminology() throws {
        for path in [
            "Canvas/Views/CanvasNavigatorPanelView.swift",
            "Canvas/Domain/CanvasNavigatorModel.swift",
        ] {
            let contents = try source(path)
            #expect(!contents.contains(#""Canvas"#))
            #expect(!contents.contains(#""Conductor"#))
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: "Sources/RafuApp/" + path), encoding: .utf8)
    }
}
