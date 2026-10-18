import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Settings opens only as the standard Settings window. The editor-canvas
/// routes below are internal leftovers: no UI or command reaches them (see
/// `SettingsPresentationTests.settingsOpensOnlyTheSettingsScene`), but their
/// exclusivity invariants stay covered until the routes are removed.
@Suite("Settings canvas (internal routes)")
struct SettingsCanvasTests {
    private typealias Inputs = EditorCanvasRoute.Inputs

    @Test("Settings resolves as a tabless editor canvas")
    func settingsRoute() {
        #expect(EditorCanvasRoute.resolve(Inputs(settingsVisible: true)) == .settings)
    }

    @MainActor
    @Test("Showing and closing Settings toggles only the Settings canvas")
    func settingsActivatorIsExclusive() {
        let session = WorkspaceSession()

        session.showSettings()
        #expect(session.settingsVisible)
        #expect(session.selectedAuxiliaryTab == .settings)

        session.closeSettings()
        #expect(!session.settingsVisible)
        #expect(session.selectedAuxiliaryTab == nil)
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
