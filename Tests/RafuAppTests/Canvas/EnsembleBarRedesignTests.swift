import Foundation
import Testing

@testable import RafuApp

/// WP-B: the Ensemble bar and the Terminals panel redesign. Source-level
/// contracts only; no view is instantiated.
@Suite("Ensemble bar redesign")
struct EnsembleBarRedesignTests {
    @Test("The board is the only Ensemble surface; VoiceOver keeps a card list")
    func boardOnlySurface() throws {
        #expect(!Self.exists("Sources/RafuApp/Canvas/Views/CanvasListView.swift"))
        let canvas = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        #expect(!canvas.contains("CanvasListView("))
        // The rotor replaces the List's enumerable path through the cards.
        #expect(canvas.contains(".accessibilityRotor(\"Cards\")"))
        #expect(canvas.contains(".accessibilityRotorEntry(id: card.id, in: cardRotorNamespace)"))
        #expect(canvas.contains("Image(systemName: CanvasBoardState.ensembleSymbol)"))
        #expect(CanvasBoardState.ensembleSymbol == "circle.hexagongrid")
        let bar = try Self.source("Sources/RafuApp/Canvas/Views/CanvasBar.swift")
        #expect(!bar.contains("CanvasModeControl"))
        let commands = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCommands.swift")
        #expect(!commands.contains("Button(\"List\")"))
        let palette = try Self.source("Sources/RafuApp/Views/CommandPaletteView.swift")
        #expect(!palette.contains("Ensemble: Show List"))
    }

    private static func root(file: StaticString = #filePath) -> URL? {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func exists(_ path: String) -> Bool {
        guard let root = root() else { return false }
        return FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    static func source(_ path: String) throws -> String {
        guard let root = root() else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
