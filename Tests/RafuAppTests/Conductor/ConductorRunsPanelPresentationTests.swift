import Foundation
import Testing

@testable import RafuApp

/// Utility-owned source contracts split from `EnsembleStartCanvasTests` before
/// the presentation fan-out. No assertion is duplicated or weakened: this
/// suite exclusively reads Runs, window-presentation, command, and palette
/// sources.
@Suite("Ensemble runs panel presentation")
struct ConductorRunsPanelPresentationTests {
    @Test("Every entry point uses the canvas seams and no Ensemble sheet is presented")
    func entryPointsUseCanvasSeams() throws {
        let root = try repositoryRoot()
        let commands = try source("Sources/RafuApp/App/RafuAppCommands.swift", root: root)
        let palette = try source("Sources/RafuApp/Views/CommandPaletteView.swift", root: root)
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )
        let presentations = try source(
            "Sources/RafuApp/Views/WorkspaceWindowView.swift", root: root
        )

        #expect(commands.contains("workspaceSession?.showEnsembleStart()"))
        #expect(commands.contains(".keyboardShortcut(\"e\", modifiers: [.command, .shift])"))
        #expect(palette.contains("session.showEnsembleStart()"))
        #expect(runsPanel.contains("session.showEnsembleStart()"))

        #expect(commands.contains("workspaceSession?.showEnsembleNewRun()"))
        #expect(palette.contains("session.showEnsembleNewRun()"))
        #expect(runsPanel.contains("session.showEnsembleNewRun()"))

        #expect(!presentations.contains("EnsembleStart"))
        #expect(!runsPanel.contains(".sheet("))
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appending(
                    path: "Sources/RafuApp/Views/EnsembleStartSheet.swift"
                ).path
            )
        )
    }

    @Test("New Run exposes close and Esc and keeps its bounded canvas width")
    func newRunCanvasCloseAndWidthContract() throws {
        let root = try repositoryRoot()
        let runCanvas = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )

        #expect(runCanvas.contains(".onExitCommand(perform: session.closeEnsembleNewRun)"))
        #expect(runCanvas.contains(".frame(maxWidth: 600"))
        #expect(runCanvas.contains("AttachedWorkbenchTab(isSelected: true"))
        #expect(runCanvas.contains("AttachedWorkbenchTabCloseButton("))
        #expect(runCanvas.contains("accessibilityLabel: \"Close New Ensemble Run\""))
        #expect(runCanvas.contains("help: \"Close New Ensemble Run\""))
    }

    @Test("Runs uses one Ensemble header, three real modes, and shared empty states")
    func runsPanelHierarchyContract() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )

        #expect(runsPanel.components(separatedBy: "RafuUtilityPanelHeader(").count - 1 == 1)
        #expect(runsPanel.contains("title: \"Ensemble\""))
        #expect(runsPanel.contains("items: ConductorRunsPanelSection.allCases"))
        #expect(runsPanel.contains("RafuPanelEmptyState("))
        #expect(runsPanel.contains(".buttonStyle(RafuProminentButtonStyle())"))
        #expect(
            runsPanel.range(
                of: #""[^"\n]*Conductor[^"\n]*""#,
                options: .regularExpression
            ) == nil
        )
    }

    @Test("Runs header icons have labels, tooltips, and menu/palette equivalents")
    func runsHeaderIconContract() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )
        let commands = try source("Sources/RafuApp/App/RafuAppCommands.swift", root: root)
        let palette = try source("Sources/RafuApp/Views/CommandPaletteView.swift", root: root)

        #expect(
            runsPanel.components(separatedBy: ".buttonStyle(RafuIconButtonStyle(size: 24))")
                .count - 1 >= 3
        )
        #expect(runsPanel.contains(".help(\"Show Ensemble Graph\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"Show Ensemble Graph\")"))
        #expect(runsPanel.contains(".help(\"New Ensemble…\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"New Ensemble\")"))
        #expect(runsPanel.contains(".help(\"New Run…\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"New Ensemble Run\")"))

        #expect(commands.contains("workspaceSession?.showConductorGraph()"))
        #expect(palette.contains("session.showConductorGraph()"))
        #expect(commands.contains("workspaceSession?.showEnsembleStart()"))
        #expect(palette.contains("session.showEnsembleStart()"))
        #expect(commands.contains("workspaceSession?.showEnsembleNewRun()"))
        #expect(palette.contains("session.showEnsembleNewRun()"))
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ConductorRunsPanelPresentationTestError.repositoryRootNotFound
    }

    private func source(_ path: String, root: URL) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private enum ConductorRunsPanelPresentationTestError: Error {
        case repositoryRootNotFound
    }
}
