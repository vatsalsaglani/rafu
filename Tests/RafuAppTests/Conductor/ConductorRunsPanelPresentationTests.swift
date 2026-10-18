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

        // Graph and "+" in the panel header; Close comes from the shared header.
        #expect(
            runsPanel.components(separatedBy: ".buttonStyle(RafuIconButtonStyle(size: 24))")
                .count - 1 >= 1
        )
        #expect(runsPanel.contains(".help(\"Show Ensemble Graph\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"Show Ensemble Graph\")"))
        #expect(runsPanel.contains(".help(\"New Run, Ensemble, or Workflow\")"))
        #expect(runsPanel.contains(".accessibilityLabel(\"New\")"))
        // The three creation verbs live in the one "+" pull-down.
        #expect(runsPanel.contains("Button(\"New Run…\""))
        #expect(runsPanel.contains("Button(\"New Ensemble…\""))
        #expect(runsPanel.contains("Menu(\"New Workflow from Template…\""))

        #expect(commands.contains("workspaceSession?.showConductorGraph()"))
        #expect(palette.contains("session.showConductorGraph()"))
        #expect(commands.contains("workspaceSession?.showEnsembleStart()"))
        #expect(palette.contains("session.showEnsembleStart()"))
        #expect(commands.contains("workspaceSession?.showEnsembleNewRun()"))
        #expect(palette.contains("session.showEnsembleNewRun()"))
    }

    @Test("The header has no flower glyph button and no wide text menu that clips the panel")
    func headerStaysNarrow() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )

        #expect(!runsPanel.contains("Menu(\"New from Template\""))
        #expect(!runsPanel.contains("Menu(\"Workflow Actions\""))
        // "Open" appears twice only: the "···" menu item and its context-menu twin.
        #expect(runsPanel.components(separatedBy: "Button(\"Open\"").count - 1 == 2)
        // The graph and "+" are the only header-specific icon buttons.
        #expect(runsPanel.components(separatedBy: "circle.hexagongrid").count - 1 == 1)
    }

    @Test("The section picker never wraps and falls back to icons with tooltips")
    func sectionPickerNeverWraps() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )

        #expect(runsPanel.contains("ViewThatFits(in: .horizontal)"))
        #expect(runsPanel.contains(".lineLimit(1)"))
        #expect(runsPanel.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(runsPanel.contains(".help(item.title)"))
        #expect(runsPanel.contains(".accessibilityLabel(item.title)"))
        #expect(runsPanel.contains("withAnimation(RafuMotion.selection)"))
    }

    @Test("Workflow rows show name and path, open on double click, and keep one Open")
    func workflowRowContract() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )

        #expect(runsPanel.contains(".onTapGesture(count: 2, perform: open)"))
        #expect(runsPanel.contains("Button(\"Reveal in Finder\""))
        #expect(runsPanel.contains("Button(\"Duplicate\""))
        #expect(runsPanel.contains(".truncationMode(.middle)"))
        // The only "Open" verb is in the menu (and its context-menu twin).
        #expect(runsPanel.contains("Button(\"Open\", systemImage: \"doc.text\", action: open)"))
    }

    @Test("Activity copy is plain, and a full-tab Ensemble surface switches the panel to Runs")
    func activityCopyAndDuplicateEmptyState() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )

        #expect(
            runsPanel.contains("Run events appear here while this workspace is open."))
        #expect(!runsPanel.contains("Bounded Ensemble lifecycle events"))
        #expect(runsPanel.contains("showsFullTabEnsembleSurface"))
        #expect(runsPanel.contains("session.conductorGraphVisible"))
        #expect(runsPanel.contains("if isOpen { section = .runs }"))
    }

    @Test("New Run uses theme surfaces, one label column, and a footer")
    func newRunFormUsesThemeSurfaces() throws {
        let root = try repositoryRoot()
        let runsPanel = try source(
            "Sources/RafuApp/Views/ConductorRunsPanelView.swift", root: root
        )
        let controls = try source(
            "Sources/RafuApp/Views/ConductorFormControls.swift", root: root
        )

        #expect(!runsPanel.contains(".formStyle(.grouped)"))
        #expect(runsPanel.contains("ConductorFormRow(\"Agent file\")"))
        #expect(runsPanel.contains("ConductorFormRow(\"Provider override\")"))
        #expect(runsPanel.contains("ConductorFormRow(\"Model override\""))
        #expect(runsPanel.contains("ConductorFormRow(\"Task prompt\""))
        #expect(runsPanel.contains("ConductorFormRow(\"Base reference\")"))
        #expect(runsPanel.contains("ConductorPromptEditor("))
        #expect(runsPanel.contains("ConductorBaseReferenceField("))
        #expect(runsPanel.contains("private var footer"))
        #expect(controls.contains("theme.palette.cardBackground"))
        #expect(controls.contains("theme.palette.fieldBackground"))
        #expect(controls.contains("theme.palette.borderSubtle"))
        #expect(!controls.contains("Color(nsColor"))
        #expect(!controls.contains("Color.gray"))
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
