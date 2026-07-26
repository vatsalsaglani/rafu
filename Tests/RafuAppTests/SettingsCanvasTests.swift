import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Settings canvas")
struct SettingsCanvasTests {
    private typealias Inputs = EditorCanvasRoute.Inputs

    @Test("Settings resolves as a tabless editor canvas")
    func settingsRoute() {
        #expect(EditorCanvasRoute.resolve(Inputs(settingsVisible: true)) == .settings)
    }

    /// Every canvas activator must leave exactly one canvas showing.
    ///
    /// UX-01 (the two Ensemble creation canvases) and UX-02 (Settings) were
    /// built in parallel, so neither branch's activators cleared the other's
    /// flags; the cross-clears were added when they merged. Each branch was
    /// internally correct and the union was not — the failure mode is "the
    /// wrong screen appears" with no error, because the route tests assert
    /// the resolver's ordering rather than the invariant that keeps that
    /// ordering unreachable. This walks the whole matrix so the next parallel
    /// pair cannot reintroduce the gap.
    @MainActor
    @Test("Every canvas activator leaves exactly one canvas visible")
    func everyActivatorIsExclusive() {
        let flagsSet: (WorkspaceSession) -> Int = { session in
            [
                session.conductorRunCanvasID != nil,
                session.conductorGraphVisible,
                session.ensembleStartCanvasVisible,
                session.ensembleNewRunCanvasVisible,
                session.settingsVisible,
            ].filter { $0 }.count
        }

        let activators: [(String, (WorkspaceSession) -> Void)] = [
            ("showConductorRunDetail", { $0.showConductorRunDetail("run-x") }),
            ("showConductorGraph", { $0.showConductorGraph() }),
            ("showEnsembleStart", { $0.showEnsembleStart() }),
            ("showEnsembleNewRun", { $0.showEnsembleNewRun() }),
            ("showSettings", { $0.showSettings() }),
        ]

        // From every starting canvas, into every other canvas. The session
        // needs a descriptor: the Ensemble activators guard on an open
        // workspace (C8-07), so a bare session makes them no-op and the
        // matrix would pass vacuously.
        for (fromName, from) in activators {
            for (toName, to) in activators {
                let session = WorkspaceSession()
                session.descriptor = WorkspaceDescriptor(
                    displayName: "scratch",
                    location: .local(LocalWorkspaceReference(path: "/tmp/scratch")))
                from(session)
                to(session)
                #expect(
                    flagsSet(session) == 1,
                    "\(fromName) then \(toName) left \(flagsSet(session)) canvases visible")
            }
        }
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
