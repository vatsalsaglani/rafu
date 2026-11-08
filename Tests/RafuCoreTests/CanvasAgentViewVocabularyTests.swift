import Foundation
import Testing

@testable import RafuCore

@Suite("Generated-view vocabulary")
struct CanvasAgentViewVocabularyTests {
    @Test("The spec schema is valid JSON with the required keys and a closed top level")
    func specSchemaShape() throws {
        let schema = CanvasAgentViewVocabulary.specSchema
        #expect(JSONSerialization.isValidJSONObject(schema))
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["required"] as? [String] == ["root", "elements"])
        #expect(decoded["additionalProperties"] as? Bool == false)
        let properties = try #require(decoded["properties"] as? [String: Any])
        let elements = try #require(properties["elements"] as? [String: Any])
        let element = try #require(elements["additionalProperties"] as? [String: Any])
        #expect(element["required"] as? [String] == ["type"])
        #expect(
            (CanvasAgentViewVocabulary.elementsSchema["additionalProperties"] as? [String: Any])?[
                "required"] as? [String] == ["type"])
    }

    @Test("Both MCP view tools and show_view embed the vocabulary text")
    func toolsEmbedText() {
        let text = CanvasAgentViewVocabulary.text
        let definitions = CanvasAgentToolCatalog.definitions
        let render = definitions.first { $0["name"] as? String == "view_render" }
        #expect((render?["description"] as? String)?.contains(text) == true)
        #expect(VoiceToolSchema.showViewTool.description.contains(text))
    }

    @Test("The vocabulary text fits 6 KiB and names the core components")
    func textBounds() {
        let text = CanvasAgentViewVocabulary.text
        #expect(text.utf8.count <= 6 * 1_024)
        for name in ["Card", "Table", "Text", "Stack"] {
            #expect(text.contains("- \(name):"), Comment(rawValue: name))
        }
        #expect(text.contains("ACTIONS"))
        #expect(text.contains("setState"))
    }

}
