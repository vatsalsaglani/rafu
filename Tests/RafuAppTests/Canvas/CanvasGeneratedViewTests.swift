import Foundation
import Testing

@testable import RafuApp

@Suite("Generated view card contract")
@MainActor
struct CanvasGeneratedViewTests {
    static let spec = #"{"elements":{"r":{"props":{"text":"x"},"type":"Text"}},"root":"r"}"#

    static func view(
        spec: String = spec, state: CanvasGeneratedViewState? = nil
    ) -> CanvasGeneratedView {
        CanvasGeneratedView(
            specJSON: spec, catalogVersion: RafuCatalog.version,
            provenance: CanvasGeneratedViewProvenance(
                creator: "Claude", provider: "claude", createdAt: Date(), admission: "allow",
                journal: []),
            state: state)
    }

    static func state(_ json: String = #"{"n":1}"#) -> CanvasGeneratedViewState {
        CanvasGeneratedViewState(
            specVersion: String(repeating: "a", count: 64), catalogVersion: RafuCatalog.version,
            savedAt: Date(), stateJSON: json)
    }

    @Test("A view needs a root string and an elements object within the byte cap")
    func viewValidation() throws {
        try Self.view().validate()
        try Self.view(state: Self.state()).validate()
        for spec in [
            "[]", "{}", #"{"root":1,"elements":{}}"#, #"{"root":"r","elements":[]}"#, "not json",
        ] {
            #expect(throws: CanvasError.invalidDocument) { try Self.view(spec: spec).validate() }
        }
        let padding = String(repeating: " ", count: CanvasLimits.generatedViewSpecBytes)
        #expect(throws: CanvasError.invalidDocument) {
            try Self.view(spec: Self.spec + padding).validate()
        }
        var badVersion = Self.state()
        badVersion.specVersion = "xyz"
        #expect(throws: CanvasError.invalidDocument) {
            try Self.view(state: badVersion).validate()
        }
        #expect(throws: CanvasError.invalidDocument) {
            try Self.view(state: Self.state("[1]")).validate()
        }
        var longJournal = Self.view()
        longJournal.provenance.journal = Array(
            repeating: "set /a", count: CanvasLimits.generatedViewJournalEntries + 1)
        #expect(throws: CanvasError.invalidDocument) { try longJournal.validate() }
    }

    @Test("A board holds at most the view cap")
    func viewCap() throws {
        var document = CanvasDocument(title: "Views")
        document.cards = (0..<CanvasLimits.generatedViewCards).map { index in
            CanvasCard(title: "View \(index)", content: .generatedView(Self.view()))
        }
        try document.validate()
        document.cards.append(CanvasCard(title: "One more", content: .generatedView(Self.view())))
        #expect(throws: CanvasError.capacity) { try document.validate() }
    }

    @Test("Permissions round-trip, stay absent by default, and never enter a shared file")
    func permissions() throws {
        var document = CanvasDocument(title: "Images")
        let plain = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        #expect(!plain.contains("permissions"))
        document.permissions = CanvasPermissions(
            remoteImages: CanvasRemoteImageConsent(
                allowed: true, grantedAt: Date(timeIntervalSinceReferenceDate: 10),
                grantedBy: "user"))
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: data)
        #expect(decoded.permissions == document.permissions)

        let shared = try CanvasEnsembleFile(document: document).document()
        #expect(shared.permissions == nil)

        document.permissions?.remoteImages?.grantedBy = "agent"
        #expect(throws: CanvasError.invalidDocument) { try document.validate() }
    }

    @Test("Saving folds a view's state snapshot in without an undo step")
    func stateSnapshotFold() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Views"))
        try board.add(title: "View", content: .generatedView(Self.view()))
        let id = try #require(board.cards.first?.id)
        let undoBefore = board.canUndo
        let state = Self.state()
        board.generatedViewStateSnapshots[id] = { state }
        board.markGeneratedViewStateEdited()
        #expect(board.isDirty)
        #expect(board.canUndo == undoBefore)
        let saved = try board.snapshot()
        guard case .generatedView(let view) = saved.cards.first?.content else {
            Issue.record("Expected a generated view")
            return
        }
        #expect(view.state == state)
    }

    @Test("The Rafu catalog builds from the standard and chart catalogs")
    func catalogBuilds() throws {
        let catalog = try RafuCatalog.buildThrowing()
        #expect(catalog.component(named: "Card") != nil)
        #expect(catalog.component(named: "LineChart") != nil)
        #expect(RafuCatalog.rafu.componentNames.count == catalog.componentNames.count)
    }
}
