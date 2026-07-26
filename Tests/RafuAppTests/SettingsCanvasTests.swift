import Foundation
import Testing

@testable import RafuApp

@Suite("Settings canvas")
struct SettingsCanvasTests {
    private typealias Inputs = EditorCanvasRoute.Inputs

    @Test("Settings resolves as a tabless editor canvas")
    func settingsRoute() {
        #expect(EditorCanvasRoute.resolve(Inputs(settingsVisible: true)) == .settings)
    }

    @MainActor
    @Test("Settings, run detail, and graph activators are mutually exclusive")
    func canvasMutualExclusion() {
        let session = WorkspaceSession()

        session.conductorRunCanvasID = "run-1"
        session.conductorGraphVisible = true
        session.showSettings()
        #expect(session.settingsVisible)
        #expect(session.conductorRunCanvasID == nil)
        #expect(!session.conductorGraphVisible)

        session.showConductorRunDetail("run-2")
        #expect(!session.settingsVisible)
        #expect(session.conductorRunCanvasID == "run-2")
        #expect(!session.conductorGraphVisible)

        session.showSettings()
        session.showConductorGraph()
        #expect(!session.settingsVisible)
        #expect(session.conductorRunCanvasID == nil)
        #expect(session.conductorGraphVisible)
    }

    @Test("A selected document beats Settings")
    func selectedDocumentBeatsSettings() {
        let inputs = Inputs(
            hasAnyEditorTabs: true,
            settingsVisible: true,
            hasSelectedDocument: true,
            hasSelectedDocumentID: true
        )

        #expect(EditorCanvasRoute.resolve(inputs) == .editor)
    }

    @MainActor
    @Test("Settings command opens the focused workspace canvas")
    func settingsCommandWithWorkspace() {
        let session = WorkspaceSession()
        var fallbackOpened = false

        SettingsCommandRouter.open(workspaceSession: session) {
            fallbackOpened = true
        }

        #expect(session.settingsVisible)
        #expect(!fallbackOpened)
    }

    @MainActor
    @Test("Settings command opens the native fallback without a workspace window")
    func settingsCommandWithoutWindow() {
        var fallbackOpened = false

        SettingsCommandRouter.open(workspaceSession: nil) {
            fallbackOpened = true
        }

        #expect(fallbackOpened)
    }

    @MainActor
    @Test("Settings canvas state is independent per window")
    func secondWindowIndependence() {
        let firstWindow = WorkspaceSession()
        let secondWindow = WorkspaceSession()

        firstWindow.showSettings()

        #expect(firstWindow.settingsVisible)
        #expect(!secondWindow.settingsVisible)
        #expect(
            EditorCanvasRoute.resolve(EditorCanvasRoute.Inputs(session: firstWindow))
                == .settings
        )
        #expect(
            EditorCanvasRoute.resolve(EditorCanvasRoute.Inputs(session: secondWindow))
                == .welcome
        )
    }

    @MainActor
    @Test("Settings canvas is omitted from restoration and starts closed after relaunch")
    func settingsIsNotRestored() throws {
        let runningSession = WorkspaceSession()
        runningSession.showSettings()
        #expect(runningSession.settingsVisible)

        let payload = RestorableWorkspace(
            bookmark: Data([1, 2, 3]),
            rootPath: "/tmp/example",
            openRelativePaths: ["README.md"],
            selectedRelativePath: "README.md",
            navigatorMode: .files,
            editorLayout: EditorLayoutRestoration(layout: EditorLayoutState())
        )
        let encoded = try JSONEncoder().encode(payload)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["settingsVisible"] == nil)

        let relaunchedSession = WorkspaceSession()
        #expect(!relaunchedSession.settingsVisible)
    }
}
