import Foundation
import JSONRenderCore
import Testing

@testable import RafuApp

/// The 20-view board for the memory check (the user's manual check). It reads
/// the eight upstream example specs from the package checkout, so nothing
/// third-party is copied into Rafu. Set `RAFU_VIEW_FIXTURE_OUT` to a file path
/// to write the board as a `.rafuensemble` file:
///
///     RAFU_VIEW_FIXTURE_OUT=/tmp/twenty-views.rafuensemble \
///       swift test --filter GeneratedViewMemoryFixtureTests
@Suite("Generated view memory fixture")
@MainActor
struct GeneratedViewMemoryFixtureTests {
    static let specsFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: ".build/checkouts/swift-json-render/Tests/ParityFixtures/upstream/specs")

    @Test("Twenty views from the upstream examples fit one board and its budget")
    func twentyViews() throws {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: Self.specsFolder, includingPropertiesForKeys: nil)) ?? []
        let host = GeneratedViewActions()
        var specs: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.lastPathComponent != "index.json" {
            guard let data = try? Data(contentsOf: file),
                let text = String(data: data, encoding: .utf8),
                case .success(let checked) = host.check(Self.specPart(text))
            else { continue }
            specs.append(checked.text)
        }
        // A checkout without the fixtures (or specs that no longer validate)
        // falls back to Rafu's own sample, so the board still builds.
        if specs.isEmpty {
            specs = [GeneratedViewFixtures.formSpec, GeneratedViewFixtures.textSpec]
        }
        let board = CanvasBoardState(document: CanvasDocument(title: "Twenty views"))
        for index in 0..<20 {
            let rect = CanvasRect(
                x: Double(index % 5) * 460, y: Double(index / 5) * 340, width: 420, height: 300)
            _ = try host.create(
                specJSON: specs[index % specs.count], title: "View \(index + 1)", rect: rect,
                provenance: GeneratedViewFixtures.provenance(), on: board)
        }
        let document = try board.snapshot()
        #expect(document.cards.count == 20)
        #expect(GeneratedViewBudget.usedBytes(document.cards) <= GeneratedViewBudget.boardBytes)
        let data = try JSONEncoder().encode(document)
        #expect(data.count <= CanvasLimits.documentBytes)
        if let path = ProcessInfo.processInfo.environment["RAFU_VIEW_FIXTURE_OUT"] {
            let file = CanvasEnsembleFile(document: document)
            try JSONEncoder().encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Some example files wrap the spec (`{"spec": {...}}`); take the spec.
    static func specPart(_ text: String) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            object["root"] == nil, let spec = object["spec"],
            let data = try? JSONSerialization.data(withJSONObject: spec)
        else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
