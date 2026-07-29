import Foundation
import Testing

@testable import RafuApp

@MainActor
@Suite("Goal-first Ensemble presentation")
struct EnsemblePresentationTests {
    @Test("New Ensemble source order follows the common task")
    func sourceOrderAndGeometry() throws {
        let startCanvas = try source("Sources/RafuApp/Views/EnsembleStartCanvas.swift")

        let name = try #require(startCanvas.range(of: "private var nameField"))
        let guidedDoor = try #require(startCanvas.range(of: "private var guidedDoor"))
        let goal = try #require(startCanvas.range(of: "EnsembleGoalPane(text: $model.goal)"))
        let lead = try #require(startCanvas.range(of: "private var coordinatorSection"))
        let budget = try #require(startCanvas.range(of: "private var budgetSection"))
        let allowed = try #require(startCanvas.range(of: "private var allowedCLISection"))
        let footer = try #require(startCanvas.range(of: "private var footer"))

        #expect(name.lowerBound < guidedDoor.lowerBound)
        #expect(goal.lowerBound < lead.lowerBound)
        #expect(lead.lowerBound < budget.lowerBound)
        #expect(budget.lowerBound < allowed.lowerBound)
        #expect(allowed.lowerBound < footer.lowerBound)
        #expect(startCanvas.contains("nonisolated static let goalPaneMinimumWidth: CGFloat = 420"))
        #expect(
            startCanvas.contains("nonisolated static let configurationRailWidth: CGFloat = 300"))
        #expect(startCanvas.contains(".frame(width: RafuMetrics.workbenchInset)"))
        #expect(EnsembleStartCanvas.headerTargetHeight < 100)
        #expect(startCanvas.contains("nonisolated static let footerMinimumHeight: CGFloat = 52"))
        #expect(startCanvas.contains(".frame(minHeight: Self.footerMinimumHeight)"))
    }

    @Test("Selection rows retain truth and accessible lead and allowed semantics")
    func selectionRowsRetainTruth() throws {
        let startCanvas = try source("Sources/RafuApp/Views/EnsembleStartCanvas.swift")
        let list = try source("Sources/RafuApp/Views/EnsembleCLISelectionList.swift")
        let modelField = try source("Sources/RafuApp/Views/EnsembleModelField.swift")

        #expect(startCanvas.contains("selection: .lead(isSelected: isSelected)"))
        #expect(startCanvas.contains("selection: .allowed(isSelected: isAllowed)"))
        #expect(startCanvas.contains("Lead coordinator, single selection"))
        #expect(startCanvas.contains("Allowed CLIs, multiple selection"))
        #expect(startCanvas.contains("unavailableReason: model.disableReason(option.id)"))
        #expect(list.contains("Text(option.isReady ? \"Ready\" : \"Unavailable\")"))
        #expect(list.contains("Label(\"Unavailable — \\(unavailableReason)\""))
        #expect(
            list.contains(
                "accessibilityValue(selection.isSelected ? \"Selected\" : \"Not selected\")"))
        #expect(modelField.contains("ConductorModelResolution.unsetLabel"))
        #expect(modelField.contains("Text(\"Custom…\")"))
        #expect(modelField.contains("if inheritedCaption != nil"))
    }

    @Test("All owned canvases use the shared attached tab without a visible Conductor label")
    func ownedCanvasesShareAttachedTabs() throws {
        let paths = [
            "Sources/RafuApp/Views/EnsembleStartCanvas.swift",
            "Sources/RafuApp/Views/ConductorGraphCanvas.swift",
            "Sources/RafuApp/Views/ConductorRunDetailCanvas.swift",
        ]

        for path in paths {
            let canvas = try source(path)
            #expect(canvas.contains("AttachedWorkbenchTab(isSelected: true)"))
            #expect(!canvas.contains("\"Conductor"))
        }
    }

    private func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw EnsemblePresentationTestError.repositoryRootNotFound
    }

    private enum EnsemblePresentationTestError: Error {
        case repositoryRootNotFound
    }
}
