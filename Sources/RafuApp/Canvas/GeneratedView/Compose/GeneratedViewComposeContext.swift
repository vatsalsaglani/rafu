import Foundation
import JSONRenderCore
import RafuCore

/// The `context` a composition sends to the Decisions API as it is: the
/// Ensemble title, counts, and the user's extra words from the tool call,
/// scrubbed. Never file contents, terminal text, state or a key.
nonisolated enum GeneratedViewComposeContext {
    static let maximumUserContext = 1_000

    static func make(facts: GeneratedViewComposeFacts, userContext: String?)
        -> JSONRenderCore.JSONValue
    {
        var object: [String: JSONRenderCore.JSONValue] = [
            "ensemble": .string(facts.ensemble),
            "cards": .number(Double(facts.cards)),
            "terminals": .number(Double(facts.terminals.count)),
            "running_terminals": .number(Double(facts.runningTerminals)),
            "agents": .number(Double(facts.agents)),
            "files": .number(Double(facts.files.count)),
            "terminal_output_shared": .bool(facts.tail != nil),
        ]
        if let text = userContext.map(scrubbed), !text.isEmpty {
            object["user_context"] = .string(text)
        }
        return .object(object)
    }

    /// Secrets redacted, control characters removed, one line per input line,
    /// at most `maximumUserContext` bytes.
    static func scrubbed(_ text: String) -> String {
        VoiceOutputScrubber.scrub(
            lines: text.components(separatedBy: .newlines), maxLines: 40,
            maxLineBytes: maximumUserContext, maxBytes: maximumUserContext)
    }
}
