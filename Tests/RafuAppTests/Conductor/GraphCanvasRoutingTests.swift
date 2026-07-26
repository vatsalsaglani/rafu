import Testing

@testable import RafuApp

@MainActor
@Suite("Ensemble graph canvas routing")
struct GraphCanvasRoutingTests {
    @Test("Showing the graph clears document selection and reveals Runs")
    func showGraphRoutesCanvas() throws {
        let session = WorkspaceSession()
        session.newUntitledDocument()
        let document = try #require(session.openDocuments.first)
        session.select(document)

        session.showConductorGraph()

        #expect(session.conductorGraphVisible)
        #expect(session.conductorRunCanvasID == nil)
        #expect(session.navigatorMode == .runs)
        #expect(session.selectedDocumentID == nil)
        #expect(session.selectedTreePath == nil)
    }

    @Test("Showing run detail clears the graph")
    func runDetailReplacesGraph() {
        let session = WorkspaceSession()
        session.showConductorGraph()

        session.showConductorRunDetail("run-1")

        #expect(!session.conductorGraphVisible)
        #expect(session.conductorRunCanvasID == "run-1")
    }

    @Test("Revealing a terminal clears the graph")
    func terminalReplacesGraph() throws {
        let session = WorkspaceSession()
        session.newTerminalTab()
        let terminal = try #require(session.terminal.sessions.first)
        session.showConductorGraph()

        session.revealTerminalSession(terminal.id)

        #expect(!session.conductorGraphVisible)
        #expect(session.terminal.selectedID == terminal.id)
    }

    @Test("Closing the graph restores the last document")
    func closeGraphRestoresDocument() throws {
        let session = WorkspaceSession()
        session.newUntitledDocument()
        let document = try #require(session.openDocuments.first)
        session.showConductorGraph()

        session.closeConductorGraph()

        #expect(!session.conductorGraphVisible)
        #expect(session.selectedDocumentID == document.id)
    }

    @Test("Graph visibility belongs to one workspace window")
    func secondWindowIndependence() {
        let first = WorkspaceSession()
        let second = WorkspaceSession()

        first.showConductorGraph()
        #expect(first.conductorGraphVisible)
        #expect(!second.conductorGraphVisible)

        second.showConductorGraph()
        first.closeConductorGraph()
        #expect(!first.conductorGraphVisible)
        #expect(second.conductorGraphVisible)
    }
}
