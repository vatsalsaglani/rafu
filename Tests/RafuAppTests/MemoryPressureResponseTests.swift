import Dispatch
import Foundation
import Testing

@testable import RafuApp

/// `DispatchSourceMemoryPressure` can't be triggered deterministically from a
/// test, so these exercise the two testable seams directly:
/// `WorkspaceSession.respondToMemoryPressure()` (the per-window response) and
/// `MemoryPressureMonitor.broadcast(_:)` (fan-out to every registered
/// session). Neither touches the kernel pressure source itself.
@MainActor
@Test(
    "respondToMemoryPressure hibernates non-visible non-dirty documents, leaves dirty/visible ones loaded, and sheds the file index"
)
func respondToMemoryPressureHibernatesEligibleDocumentsAndShedsIndex() throws {
    let session = WorkspaceSession()

    session.open(
        WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/rafu-pressure-doc-1.txt"),
            relativePath: "doc1.txt", isDirectory: false))
    session.open(
        WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/rafu-pressure-doc-2.txt"),
            relativePath: "doc2.txt", isDirectory: false))
    session.open(
        WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/rafu-pressure-doc-3.txt"),
            relativePath: "doc3.txt", isDirectory: false))

    let doc1 = try #require(
        session.openDocuments.first { $0.url.path == "/tmp/rafu-pressure-doc-1.txt" })
    let doc2 = try #require(
        session.openDocuments.first { $0.url.path == "/tmp/rafu-pressure-doc-2.txt" })
    let doc3 = try #require(
        session.openDocuments.first { $0.url.path == "/tmp/rafu-pressure-doc-3.txt" })
    doc2.isDirty = true

    // Before pressure: three open documents all sit inside the newest-8
    // grace, so nothing has hibernated yet.
    #expect(doc1.loadState == .loaded)
    #expect(doc2.loadState == .loaded)
    #expect(doc3.loadState == .loaded)

    let generationBeforePressure = session.fileIndexGeneration
    session.respondToMemoryPressure()

    #expect(doc1.loadState == .hibernated)  // non-visible, non-dirty: eligible
    #expect(doc2.loadState == .loaded)  // dirty: never hibernated
    #expect(doc3.loadState == .loaded)  // visible (last selected): never hibernated
    #expect(session.fileIndexState == .idle)
    #expect(session.fileIndexGeneration == generationBeforePressure + 1)
}

@MainActor
@Test("broadcast() forwards a pressure event to every registered session")
func broadcastForwardsToRegisteredSessions() throws {
    let session = WorkspaceSession()
    session.open(
        WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/rafu-pressure-broadcast-doc.txt"),
            relativePath: "doc.txt", isDirectory: false))
    let document = try #require(session.openDocuments.first)
    // A second, unselected document so there is a non-visible, non-dirty
    // document available to observe hibernating in response to the broadcast.
    session.open(
        WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/rafu-pressure-broadcast-doc-2.txt"),
            relativePath: "doc2.txt", isDirectory: false))
    #expect(document.loadState == .loaded)

    MemoryPressureMonitor.shared.register(session)
    MemoryPressureMonitor.shared.broadcast(.warning)

    #expect(document.loadState == .hibernated)
}

/// `resume()` on a `DispatchSourceMemoryPressure` crashes the process if
/// called twice on the same source. `start()` must guard against that for
/// every window's launch path — this simply calls it twice and relies on the
/// test process surviving as the regression signal.
@MainActor
@Test("start() is idempotent — a second call never double-resumes the source")
func monitorStartIsIdempotent() {
    MemoryPressureMonitor.shared.start()
    MemoryPressureMonitor.shared.start()
}
