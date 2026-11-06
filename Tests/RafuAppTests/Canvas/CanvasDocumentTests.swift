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

    /// Saved shape of every live content case, written by the encoder before the
    /// Mac App kind was removed. A board saved by an older Rafu must keep loading.
    private static let groupID = TerminalGroupID(
        rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    private static let goldenContent: [(CanvasCardContent, String)] = [
        (.file(path: "a.txt"), #"{"file":{"path":"a.txt"}}"#),
        (.image(path: "b.png"), #"{"image":{"path":"b.png"}}"#),
        (.note(snapshot: "hi"), #"{"note":{"snapshot":"hi"}}"#),
        (
            .terminal(groupID: groupID),
            #"{"terminal":{"groupID":{"rawValue":"22222222-2222-2222-2222-222222222222"}}}"#
        ),
        (
            .web(destination: try! CanvasWebDestination("http://localhost:3000/")),
            #"{"web":{"destination":{"address":"http://localhost:3000/"}}}"#
        ),
        (.mermaid(source: "graph TD"), #"{"mermaid":{"source":"graph TD"}}"#),
        (
            .shape(CanvasShape(kind: .diamond, label: "Go")),
            #"{"shape":{"_0":{"dashed":false,"fill":"none","kind":"diamond","label":"Go","stroke":"primary","weight":"regular"}}}"#
        ),
        (
            .stroke(
                CanvasStroke(
                    kind: .line, points: [CanvasUnitPoint(x: 0, y: 0), CanvasUnitPoint(x: 1, y: 1)])
            ),
            #"{"stroke":{"_0":{"dashed":false,"endArrowhead":"none","ink":"primary","kind":"line","points":[[0,0],[10000,10000]],"startArrowhead":"none","weight":"regular"}}}"#
        ),
        (
            .text(CanvasText(text: "Hi")),
            #"{"text":{"_0":{"ink":"primary","size":"medium","text":"Hi"}}}"#
        ),
        (
            .frame(CanvasFrame(title: "Group")),
            #"{"frame":{"_0":{"memberIDs":[],"style":"neutral","title":"Group"}}}"#
        ),
        (
            .serviceIcon(CanvasServiceIcon(packID: "aws", iconID: "s3", label: "Bucket")),
            #"{"serviceIcon":{"_0":{"iconID":"s3","label":"Bucket","packID":"aws"}}}"#
        ),
    ]

    @Test("Every live content case keeps its saved JSON shape and round-trips")
    func liveContentKeepsSavedShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (content, golden) in Self.goldenContent {
            let encoded = try String(decoding: encoder.encode(content), as: UTF8.self)
            #expect(encoded == golden)
            let decoded = try JSONDecoder().decode(CanvasCardContent.self, from: Data(golden.utf8))
            #expect(decoded == content)
        }
    }

    private static let removedAppBoard = #"""
        {"agentControl":null,"cards":[{"content":{"note":{"snapshot":"keep"}},"id":{"rawValue":"00000000-0000-0000-0000-0000000000A1"},"rect":{"height":260,"width":380,"x":10,"y":20},"title":"Keep"},{"content":{"nativeApp":{"bundleID":"com.apple.finder"}},"id":{"rawValue":"00000000-0000-0000-0000-0000000000A2"},"rect":{"height":160,"width":220,"x":500,"y":40},"title":"Finder"}],"connections":[{"behavior":"related","from":{"rawValue":"00000000-0000-0000-0000-0000000000A1"},"id":"00000000-0000-0000-0000-0000000000B1","label":"Related to","to":{"rawValue":"00000000-0000-0000-0000-0000000000A2"}}],"id":{"rawValue":"00000000-0000-0000-0000-0000000000C1"},"revision":4,"title":"Old","version":1,"viewport":{"scale":1,"x":0,"y":0}}
        """#

    @Test("A saved Mac App card opens as a note that keeps its place, title, and links")
    func removedMacAppCardBecomesTombstoneNote() throws {
        let document = try JSONDecoder().decode(
            CanvasDocument.self, from: Data(Self.removedAppBoard.utf8))
        #expect(document.cards.count == 2)
        let card = document.cards[1]
        #expect(
            card.id
                == CanvasCardID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
        )
        #expect(card.title == "Finder")
        #expect(card.rect.x == 500 && card.rect.width == 220)
        #expect(
            card.content
                == .note(
                    snapshot:
                        "Mac App card: com.apple.finder\n\nMac App cards were removed from Rafu. "
                        + "This note keeps the card's place and links."))
        #expect(document.connections.count == 1)
        #expect(document.connections[0].from == document.cards[0].id)
        #expect(document.connections[0].to == card.id)
        #expect(document.revision == 4)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(decoding: try encoder.encode(document), as: UTF8.self)
        #expect(!reencoded.contains("nativeApp"))
        let reloaded = try JSONDecoder().decode(CanvasDocument.self, from: Data(reencoded.utf8))
        #expect(reloaded == document)
    }

    @Test("A forged bundle identifier never reaches the tombstone note")
    func removedMacAppCardIgnoresForgedIdentifier() throws {
        let json = Self.removedAppBoard.replacingOccurrences(
            of: "com.apple.finder", with: "x\\nINJECT")
        let document = try JSONDecoder().decode(CanvasDocument.self, from: Data(json.utf8))
        guard case .note(let text) = document.cards[1].content else {
            Issue.record("Expected a note")
            return
        }
        #expect(text.hasPrefix("Mac App card: unknown app\n"))
        #expect(!text.contains("INJECT"))
    }

    @Test("Canvas sources no longer contain the Mac App kind or Accessibility docking")
    func canvasSourcesHaveNoMacAppCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let canvas = root.appending(path: "Sources/RafuApp/Canvas", directoryHint: .isDirectory)
        let files = try #require(
            FileManager.default.enumerator(at: canvas, includingPropertiesForKeys: nil))
        var scanned = 0
        var violations: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in ["AXUIElement", "ApplicationServices", "CanvasAppDocking"]
            where text.contains(word) {
                violations.append("\(url.lastPathComponent): \(word)")
            }
            // The legacy decoder in CanvasDocument.swift is the one allowed mention.
            if text.contains("nativeApp"), url.lastPathComponent != "CanvasDocument.swift" {
                violations.append("\(url.lastPathComponent): nativeApp")
            }
        }
        #expect(scanned > 20)
        #expect(violations.isEmpty, "\(violations)")
    }
}
