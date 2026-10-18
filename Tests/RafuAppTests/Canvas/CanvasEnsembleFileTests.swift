import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble file format")
struct CanvasEnsembleFileTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    static func sampleDocument() throws -> CanvasDocument {
        var document = CanvasDocument(title: "Plan")
        document.revision = 4
        let note = CanvasCard(title: "Note", content: .note(snapshot: "Hello"))
        let image = CanvasCard(title: "Shot", content: .image(path: "docs/shot.png"))
        let again = CanvasCard(title: "Shot 2", content: .image(path: "docs/shot.png"))
        let file = CanvasCard(title: "Readme", content: .file(path: "README.md"))
        let diagram = CanvasCard(title: "Flow", content: .mermaid(source: "graph TD\nA-->B"))
        document.cards = [note, image, again, file, diagram]
        document.connections = [CanvasConnection(from: note.id, to: diagram.id)]
        document.viewport = CanvasViewport(scale: 0.5, x: 10, y: -20)
        return document
    }

    @Test("A board round-trips through the file with one asset per path")
    func roundTrip() throws {
        let document = try Self.sampleDocument()
        let file = CanvasEnsembleFile(document: document, embedded: ["docs/shot.png": Self.png])
        #expect(file.assets.map(\.path) == ["docs/shot.png", "README.md"])
        #expect(file.assets[0].mediaType == "image/png")
        #expect(file.assets[1].data == nil)
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format" : "dev.rafu.ensemble""#))
        #expect(text.contains(#""formatVersion" : 1"#))
        let decoded = try CanvasEnsembleFile.decode(data)
        #expect(decoded == file)
        #expect(try decoded.document() == document)
        #expect(decoded.embeddedImages == ["docs/shot.png": Self.png])
        #expect(CanvasEnsembleFile.fingerprint(data) == CanvasEnsembleFile.fingerprint(data))
        #expect(CanvasEnsembleFile.fingerprint(data) != CanvasEnsembleFile.fingerprint(data + [0]))
    }

    @Test("A newer format version is refused before its body is read")
    func newerVersion() throws {
        let future = #"{"format":"dev.rafu.ensemble","formatVersion":2,"nodes":"new shape"}"#
        #expect(throws: CanvasError.unsupportedVersion) {
            try CanvasEnsembleFile.decode(Data(future.utf8))
        }
    }

    @Test("Foreign, malformed, and oversized data is rejected")
    func rejected() throws {
        let document = try Self.sampleDocument()
        var file = CanvasEnsembleFile(document: document)
        file.format = "com.example.other"
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasEnsembleFile.decode(
                try JSONEncoder().encode(file))
        }
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasEnsembleFile.decode(Data("not json".utf8))
        }
        #expect(throws: CanvasError.invalidDocument) {
            try CanvasEnsembleFile.decode(Data(count: CanvasLimits.ensembleFileBytes + 1))
        }
        file = CanvasEnsembleFile(document: document)
        file.assets.append(.init(path: "../secret.png", kind: .image))
        #expect(throws: CanvasError.invalidDocument) { try file.validate() }
        file = CanvasEnsembleFile(document: document)
        file.assets[0].data = Data("plain text".utf8)
        #expect(throws: CanvasError.invalidDocument) { try file.validate() }
        file = CanvasEnsembleFile(document: document)
        file.board.revision = 0
        #expect(throws: CanvasError.invalidDocument) { try file.validate() }
    }

    @Test("Embedding skips unknown types and images over the caps")
    func embeddingCaps() throws {
        let document = try Self.sampleDocument()
        let big = Self.png + Data(count: CanvasLimits.embeddedAssetBytes)
        let file = CanvasEnsembleFile(document: document, embedded: ["docs/shot.png": big])
        #expect(file.assets[0].data == nil)
        let text = CanvasEnsembleFile(
            document: document, embedded: ["docs/shot.png": Data("text".utf8)])
        #expect(text.assets[0].data == nil)
        #expect(CanvasEnsembleFile.mediaType(of: Data([0xFF, 0xD8, 0xFF, 0])) == "image/jpeg")
        #expect(CanvasEnsembleFile.mediaType(of: Data("GIF89a..".utf8)) == "image/gif")
    }

    @Test("Optional keys default and unknown keys are ignored")
    func tolerantReading() throws {
        let id = UUID().uuidString
        let json = #"""
            {"format":"dev.rafu.ensemble","formatVersion":1,"extra":true,
             "board":{"id":{"rawValue":"\#(id)"},"title":"Mini","revision":1},
             "cards":[],"connections":[]}
            """#
        let file = try CanvasEnsembleFile.decode(Data(json.utf8))
        #expect(file.assets.isEmpty)
        #expect(file.viewport == CanvasViewport())
        #expect(try file.document().title == "Mini")
    }
}
