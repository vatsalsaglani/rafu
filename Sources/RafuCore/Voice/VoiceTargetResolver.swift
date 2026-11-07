import Foundation

public nonisolated enum VoiceTargetError: Error, Equatable, Sendable {
    /// More than one node matches; the titles let the model ask.
    case ambiguous([String])
    case notFound

    /// The tool output for the backend.
    public var agentJSON: String {
        switch self {
        case .ambiguous(let titles):
            let list = titles.prefix(8).map { "\"\(VoiceTargetResolver.jsonEscaped($0))\"" }
            return
                "{\"candidates\":[\(list.joined(separator: ","))],\"error\":\"ambiguous\",\"message\":\"More than one node matches. Ask the user which one.\"}"
        case .notFound:
            return
                "{\"error\":\"not_found\",\"message\":\"No node matches. Call ensemble_describe and use a node id.\"}"
        }
    }
}

/// Turns what the backend passed as a node reference into one node id. It
/// stops at exactly one match and never guesses (VPLAN section 10).
public nonisolated enum VoiceTargetResolver {
    public static let deictic: Set<String> = ["selected", "this", "this one", "it", "focused"]

    public static func resolve(
        ref: String, nodes: [CanvasAgentNodeSummary], selection: [String], focus: String?
    ) -> Result<String, VoiceTargetError> {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) {
            let id = uuid.uuidString
            return nodes.contains { $0.id.uppercased() == id } ? .success(id) : .failure(.notFound)
        }
        let key = trimmed.lowercased()
        if deictic.contains(key) {
            if selection.count == 1 { return .success(selection[0]) }
            if selection.count > 1 {
                return .failure(.ambiguous(titles(selection, in: nodes)))
            }
            if let focus { return .success(focus) }
            return .failure(.notFound)
        }
        guard !key.isEmpty else { return .failure(.notFound) }
        let exact = nodes.filter { $0.title.lowercased() == key }
        if exact.count == 1 { return .success(exact[0].id) }
        if exact.count > 1 { return .failure(.ambiguous(exact.map(\.title))) }
        let prefix = nodes.filter { $0.title.lowercased().hasPrefix(key) }
        if prefix.count == 1 { return .success(prefix[0].id) }
        if prefix.count > 1 { return .failure(.ambiguous(prefix.map(\.title))) }
        return .failure(.notFound)
    }

    private static func titles(_ ids: [String], in nodes: [CanvasAgentNodeSummary]) -> [String] {
        ids.compactMap { id in nodes.first { $0.id == id }?.title }
    }

    static func jsonEscaped(_ value: String) -> String {
        let single = CanvasAgentText.singleLine(value, limit: 60)
        guard let data = try? JSONEncoder().encode(single),
            let text = String(data: data, encoding: .utf8), text.count >= 2
        else { return "" }
        return String(text.dropFirst().dropLast())
    }
}
