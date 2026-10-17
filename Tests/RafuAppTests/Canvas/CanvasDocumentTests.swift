import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas document and destination contracts")
struct CanvasDocumentTests {
    @Test("Existing Canvas links decode as visual relationships")
    func legacyConnectionBehavior() throws {
        let source = CanvasCardID()
        let target = CanvasCardID()
        let edge = CanvasConnection(from: source, to: target)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(edge)) as? [String: Any])
        json.removeValue(forKey: "behavior")
        let decoded = try JSONDecoder().decode(
            CanvasConnection.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == edge)
        #expect(decoded.behavior == .related)
    }

    @Test(arguments: [
        "https://example.com", "file:///tmp/app", "http://localhost.evil/",
        "http://127.0.0.1.evil/", "http://user:password@localhost/", "javascript:alert(1)",
        "http://0.0.0.0/", "http://localhost:0/", "http://localhost:65536/",
    ])
    func invalidDestination(_ value: String) {
        #expect(throws: CanvasError.invalidURL) { try CanvasWebDestination(value) }
    }

    @Test(arguments: ["http://localhost:3000/path", "http://127.0.0.1:8080/", "https://[::1]/"])
    func approvedDestination(_ value: String) throws {
        let destination = try CanvasWebDestination(value + "?token=discarded#fragment")
        #expect(!destination.address.contains("discarded"))
        #expect(!destination.address.contains("fragment"))
        #expect(destination.permitsNavigation(to: try #require(URL(string: value))))
        #expect(
            !destination.permitsNavigation(to: try #require(URL(string: "http://localhost:9999/"))))
        #expect(
            !destination.permitsNavigation(to: try #require(URL(string: "https://example.com/"))))
    }

    @Test("Decode rejects geometry, duplicate identity, unknown schemas, and excess cards")
    func decodingBounds() throws {
        var document = CanvasDocument(title: "Task")
        let card = CanvasCard(title: "Note", content: .note(snapshot: "check"))
        document.cards = [card, card]
        #expect(throws: CanvasError.invalidDocument) { try document.validate() }
        document.cards = [card]
        document.cards[0].rect.width = .infinity
        #expect(throws: CanvasError.invalidDocument) { try document.validate() }
        document.cards[0].rect = CanvasRect()
        document.version = 2
        #expect(throws: CanvasError.unsupportedVersion) {
            try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(document))
        }
        document.version = 1
        document.cards = (0...CanvasLimits.cards).map { _ in card }
        #expect(throws: CanvasError.invalidDocument) {
            try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(document))
        }
    }

    @Test("A decoded destination cannot bypass validation")
    func forgedDestination() throws {
        let data = Data(#"{"address":"https://example.com/"}"#.utf8)
        let destination = try JSONDecoder().decode(CanvasWebDestination.self, from: data)
        #expect(throws: CanvasError.invalidURL) { try destination.validate() }
        #expect(
            !destination.permitsNavigation(to: try #require(URL(string: "https://example.com/"))))
    }

    @Test("File paths, notes, and connections stay bounded and refer to existing cards")
    func resourceBounds() throws {
        for path in ["/tmp/file", "../file", "a/../file", "a//file", "a/./file", ""] {
            #expect(!CanvasCardContent.validRelativePath(path))
        }
        #expect(CanvasCardContent.validRelativePath("Sources/My File.swift"))
        #expect(throws: CanvasError.noteTooLarge) {
            try CanvasCardContent.note(
                snapshot: String(repeating: "a", count: CanvasLimits.noteBytes + 1)
            ).validate()
        }
        var document = CanvasDocument(title: "Task")
        document.cards = [CanvasCard(title: "Note", content: .note(snapshot: "saved text"))]
        document.connections = [.init(from: document.cards[0].id, to: CanvasCardID())]
        #expect(throws: CanvasError.invalidDocument) { try document.validate() }
        document.connections = []
        let decoded = try JSONDecoder().decode(
            CanvasDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded == document)
    }
}
