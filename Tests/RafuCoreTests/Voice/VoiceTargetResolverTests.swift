import Foundation
import Testing

@testable import RafuCore

@Suite("Voice target resolver")
struct VoiceTargetResolverTests {
    private static let lead = UUID().uuidString
    private static let leadTests = UUID().uuidString
    private static let review = UUID().uuidString

    private static func node(_ id: String, _ title: String) -> CanvasAgentNodeSummary {
        CanvasAgentNodeSummary(
            id: id, kind: "terminal", title: title, x: 0, y: 0, width: 10, height: 10)
    }

    private let nodes = [
        node(lead, "Lead"), node(leadTests, "Lead tests"), node(review, "Review"),
    ]

    private func resolve(_ ref: String, selection: [String] = [], focus: String? = nil)
        -> Result<String, VoiceTargetError>
    {
        VoiceTargetResolver.resolve(ref: ref, nodes: nodes, selection: selection, focus: focus)
    }

    @Test("A UUID resolves to itself only when the node exists")
    func uuid() {
        #expect(resolve(Self.review) == .success(Self.review))
        #expect(resolve(Self.review.lowercased()) == .success(Self.review))
        #expect(resolve(UUID().uuidString) == .failure(.notFound))
    }

    @Test("\"this\" means the single selection, else the focus")
    func deixis() {
        #expect(resolve("this", selection: [Self.review]) == .success(Self.review))
        #expect(resolve("selected", focus: Self.lead) == .success(Self.lead))
        #expect(resolve("this") == .failure(.notFound))
        #expect(
            resolve("this", selection: [Self.lead, Self.review])
                == .failure(.ambiguous(["Lead", "Review"])))
    }

    @Test("An exact title wins over a prefix; a shared prefix is ambiguous")
    func titles() {
        #expect(resolve("lead") == .success(Self.lead))
        #expect(resolve("Rev") == .success(Self.review))
        #expect(resolve("Le") == .failure(.ambiguous(["Lead", "Lead tests"])))
        #expect(resolve("Payments") == .failure(.notFound))
        #expect(resolve("  ") == .failure(.notFound))
    }

    @Test("Errors read as tool output")
    func errorJSON() throws {
        let ambiguous = VoiceTargetError.ambiguous(["Lead", "Lead \"tests\""]).agentJSON
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(ambiguous.utf8)) as? [String: Any])
        #expect(object["error"] as? String == "ambiguous")
        #expect(object["candidates"] as? [String] == ["Lead", "Lead \"tests\""])
        #expect(VoiceTargetError.notFound.agentJSON.contains("not_found"))
    }
}
