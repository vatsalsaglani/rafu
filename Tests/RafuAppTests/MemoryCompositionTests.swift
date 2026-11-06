import Testing

@testable import RafuApp

@Suite("Memory composition Ensemble rows")
struct MemoryCompositionTests {
    @Test("Each Ensemble is one row after the terminal sessions")
    func rowPerEnsemble() {
        var metrics = WorkspaceContentMetrics()
        metrics.terminalSessions = 2
        let mebibyte: UInt64 = 1_024 * 1_024
        metrics.ensembles = [
            EnsembleContentMetric(
                id: "a", title: "Rafu AI",
                contents: [
                    .image(path: "a.png"), .image(path: "b.png"),
                    .terminal(groupID: TerminalGroupID()), .note(snapshot: ""),
                ],
                liveWebSurfaces: 1, reservedImageBytes: 4 * mebibyte, imagePoolIsShared: true),
            EnsembleContentMetric(id: "b", title: "Empty"),
        ]
        let rows = MemoryComposition.contentRows(for: metrics)
        #expect(rows.map(\.id) == ["terminals", "ensemble-a", "ensemble-b"])
        let first = rows[1]
        #expect(first.label == "Rafu AI")
        #expect(first.value == "4 cards")
        #expect(first.symbol == "circle.hexagongrid")
        #expect(first.note == "2 images · 1 terminal · 1 web live · ≈ 4.0 MB images (shared)")
        // A zero-card Ensemble still appears: it is an open tab.
        #expect(rows[2].value == "0 cards")
        #expect(rows[2].note.isEmpty)
    }

    @Test("Zero parts are left out; an unshared pool says nothing more")
    func noteParts() {
        var metric = EnsembleContentMetric(id: "x", title: "One")
        metric.cards = 1
        metric.webCards = 1
        #expect(metric.value == "1 card")
        #expect(metric.note == "1 web")
        metric.reservedImageBytes = 1_024 * 1_024
        #expect(metric.note == "1 web · ≈ 1.0 MB images")
    }
}
