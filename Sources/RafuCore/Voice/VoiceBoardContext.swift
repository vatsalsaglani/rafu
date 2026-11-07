import Foundation

/// The whole-board read for the voice backend: what `ensemble_describe`
/// returns to an agent, plus selection, focus, persona and, in Allow mode
/// only, scrubbed terminal tails. The execution boundary stays: this is
/// context, not a way to run anything (VPLAN section 4).
public nonisolated struct VoiceBoardContext: Codable, Equatable, Sendable {
    public var ensemble: String
    public var ensembleID: String
    public var mode: String
    public var nodes: [CanvasAgentNodeSummary]
    public var edges: [CanvasAgentEdgeSummary]
    public var selection: [String]
    public var focus: String?
    public var persona: String
    /// Node id → scrubbed viewport lines. Present only in Allow mode with the
    /// Settings toggle on.
    public var terminalTails: [String: String]?
    public var truncated: Bool?

    public static let maximumBytes = 24 * 1_024

    public init(
        ensemble: String, ensembleID: String, mode: CanvasAgentControlMode,
        nodes: [CanvasAgentNodeSummary], edges: [CanvasAgentEdgeSummary], selection: [String],
        focus: String?, persona: String, terminalTails: [String: String]? = nil
    ) {
        self.ensemble = ensemble
        self.ensembleID = ensembleID
        self.mode = mode.rawValue
        self.nodes = nodes
        self.edges = edges
        self.selection = selection
        self.focus = focus
        self.persona = persona
        self.terminalTails = terminalTails
    }

    /// Snake_case, sorted keys.
    public func agentJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    /// Keeps the encoding under `maximumBytes`: tails go first, then trailing
    /// edges, then trailing nodes; `truncated` is set when anything went.
    public func bounded(maximumBytes: Int = VoiceBoardContext.maximumBytes) -> VoiceBoardContext {
        func size(_ value: VoiceBoardContext) -> Int { value.agentJSON()?.count ?? .max }
        var value = self
        guard size(value) > maximumBytes else { return value }
        value.truncated = true
        value.terminalTails = nil
        while size(value) > maximumBytes {
            if !value.edges.isEmpty {
                value.edges.removeLast(max(1, value.edges.count / 4))
            } else if !value.nodes.isEmpty {
                value.nodes.removeLast(max(1, value.nodes.count / 4))
            } else {
                break
            }
        }
        return value
    }

    /// Lines and bytes of tail text, for the timeline ("tail: n lines, m bytes").
    public var tailMeasure: (lines: Int, bytes: Int) {
        let tails = Array((terminalTails ?? [:]).values)
        let lines = tails.reduce(0) { $0 + $1.split(separator: "\n").count }
        let bytes = tails.reduce(0) { $0 + $1.utf8.count }
        return (lines, bytes)
    }
}
