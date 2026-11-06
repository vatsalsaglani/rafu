import Foundation
import Testing

@testable import RafuApp

/// UX Round C: the Icon Library bolds the matched part of a name and lays
/// out five 72 pt columns.
@Suite("Icon Library names and metrics")
struct CanvasIconNameHighlightTests {
    @Test("A query word bolds its match, case-insensitively")
    func singleToken() {
        let name = "Kubernetes Cluster"
        let ranges = CanvasIconNameHighlight.ranges(in: name, query: "kube")
        #expect(ranges.map { String(name[$0]) } == ["Kube"])
    }

    @Test("Two words bold two parts, in name order")
    func twoTokens() {
        let name = "Amazon Simple Queue Service"
        let ranges = CanvasIconNameHighlight.ranges(in: name, query: "queue simple")
        #expect(ranges.map { String(name[$0]) } == ["Simple", "Queue"])
    }

    @Test("Diacritics fold, and an empty query bolds nothing")
    func diacriticsAndEmpty() {
        let name = "Café Service"
        #expect(CanvasIconNameHighlight.ranges(in: name, query: "cafe").count == 1)
        #expect(CanvasIconNameHighlight.ranges(in: name, query: "").isEmpty)
        #expect(CanvasIconNameHighlight.ranges(in: name, query: "  ").isEmpty)
        #expect(CanvasIconNameHighlight.ranges(in: name, query: "zzz").isEmpty)
    }

    @Test("The attributed name marks only the match as strongly emphasized")
    func attributedRuns() {
        let text = CanvasIconNameHighlight.attributed("Kubernetes Cluster", query: "kube")
        let bold = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.count == 1)
        if let run = bold.first {
            #expect(String(text[run.range].characters) == "Kube")
        }
        #expect(String(text.characters) == "Kubernetes Cluster")
    }

    @Test("Five 72 pt columns set the panel width")
    func metrics() {
        #expect(CanvasIconLibraryMetrics.columns == 5)
        #expect(CanvasIconLibraryMetrics.tile == 72)
        #expect(CanvasIconLibraryMetrics.panelWidth == 416)
        #expect(CanvasIconLibraryNavigation.columns == CanvasIconLibraryMetrics.columns)
    }
}
