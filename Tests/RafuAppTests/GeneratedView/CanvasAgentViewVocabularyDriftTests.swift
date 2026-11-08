import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Generated-view vocabulary drift")
struct CanvasAgentViewVocabularyDriftTests {
    /// Where a failing run writes the new text. Paste it into
    /// `CanvasAgentViewVocabulary.text` (Sources/RafuCore/CanvasBridge).
    static let regeneratedPath = FileManager.default.temporaryDirectory
        .appending(path: "rafu-view-vocabulary.txt").path

    @Test("The RafuCore vocabulary constant equals the text generated from the Rafu catalog")
    func vocabularyMatchesCatalog() throws {
        let generated = CanvasAgentViewVocabularyGenerator.generate()
        #expect(generated.utf8.count <= CanvasAgentViewVocabularyGenerator.maximumBytes)
        if generated != CanvasAgentViewVocabulary.text {
            try generated.write(toFile: Self.regeneratedPath, atomically: true, encoding: .utf8)
        }
        #expect(
            generated == CanvasAgentViewVocabulary.text,
            """
            The view vocabulary drifted from RafuCatalog. The new text is in \
            \(Self.regeneratedPath). Paste it into CanvasAgentViewVocabulary.text, then run \
            swift test --filter CanvasAgentViewVocabularyDriftTests.
            """)
    }

    @Test("The generator is deterministic and lists charts by name only")
    func generatorShape() {
        let first = CanvasAgentViewVocabularyGenerator.generate()
        #expect(first == CanvasAgentViewVocabularyGenerator.generate())
        #expect(first.contains("CHARTS (props: see the json-render-swift-use skill): "))
        #expect(!first.contains("- LineChart:"))
        #expect(first.contains("LineChart"))
        #expect(first.contains("- Card:"))
    }

    @Test("Trimming keeps names, drops prose descriptions and fits the byte bound")
    func trimmer() {
        let prompt = """
            AVAILABLE COMPONENTS (3):

            - Card: { title?: string } - A card. [accepts children]
            - Text: { text: string } - Plain text.
            - BarChart: { data: array } - Bars.

            AVAILABLE ACTIONS:

            - setState: Set a value [built-in]
            - toggleState: Flip a flag [built-in]

            DYNAMIC PROPS:
               Available functions:
               - sum — Adds numbers

            RULES:
            """
        let text = CanvasAgentViewVocabularyGenerator.trim(
            prompt: prompt, chartNames: ["BarChart"], catalogVersion: "test")
        #expect(text.contains("- Card: { title?: string } [accepts children]"))
        #expect(text.contains("- Text: { text: string }"))
        #expect(!text.contains("A card."))
        #expect(text.contains("CHARTS (props: see the json-render-swift-use skill): BarChart"))
        #expect(text.contains("ACTIONS (on.<event>: {action, params}): setState, toggleState"))
        #expect(text.contains("with sum."))
        #expect(text.utf8.count <= CanvasAgentViewVocabularyGenerator.maximumBytes)
    }

    @Test("Every component the rafu-view skill names exists in the Rafu catalog")
    @MainActor
    func skillNamesExist() throws {
        // The Rafu components arrive with the card (jr-4a) and the document
        // components (jr-4d). Until both are registered this check is skipped.
        guard !RafuCatalog.boardEntries.isEmpty, !RafuCatalog.documentEntries.isEmpty else {
            return
        }
        let catalog = try ConductorBundledSkillCatalog.bundledSkills()
        let view = try #require(catalog.first { $0.skill == "rafu-view" })
        let text = String(
            decoding: try view.data(for: .init(pathComponents: ["SKILL.md"])), as: UTF8.self)
        let names = Set(RafuCatalog.rafu.componentNames)
        for name in Self.componentNames(inSkill: text) {
            #expect(names.contains(name), Comment(rawValue: name))
        }
    }

    /// The `Name{` entries of the skill's "Rafu components" line.
    static func componentNames(inSkill text: String) -> [String] {
        guard
            let line = text.split(separator: "\n").first(where: {
                $0.hasPrefix("FileLink{")
            })
        else { return [] }
        return line.components(separatedBy: " · ").map {
            String($0.prefix { $0.isLetter || $0.isNumber })
        }
    }

    @Test("The skill's component line parses")
    @MainActor
    func skillLineParses() throws {
        let catalog = try ConductorBundledSkillCatalog.bundledSkills()
        let view = try #require(catalog.first { $0.skill == "rafu-view" })
        let text = String(
            decoding: try view.data(for: .init(pathComponents: ["SKILL.md"])), as: UTF8.self)
        let names = Self.componentNames(inSkill: text)
        #expect(names.contains("FileLink"))
        #expect(names.contains("Stat"))
        #expect(text.split(separator: "\n").count <= 100)
    }
}
