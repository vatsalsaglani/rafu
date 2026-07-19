import Foundation

nonisolated enum AIProviderDecodedEvent: Equatable, Sendable {
    case text(String)
    case done
    case ignored
}

nonisolated struct AIProviderStreamDecoder: Sendable {
    func decode(
        _ event: ServerSentEvent,
        configuration: AIProviderConfiguration
    ) throws -> AIProviderDecodedEvent {
        if event.data == "[DONE]" { return .done }
        // Tolerate empty and non-JSON data lines instead of failing the whole
        // stream: providers interleave keep-alives, bare "ping"/"OK" lines,
        // and empty `data:` fields with real deltas, and one junk line used
        // to surface as "the provider returned an unreadable response" even
        // though the rest of the reply was fine. An entirely junk stream
        // still fails downstream via the caller's empty-accumulation check.
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard let data = trimmed.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .ignored
        }

        if let error = object["error"] as? [String: Any] {
            throw AIProviderError.providerStreamError(
                boundedMessage(error["message"] as? String)
            )
        }

        switch configuration.kind {
        case .openAI, .openAICompatible:
            return try decodeOpenAI(object, transport: configuration.openAITransport)
        case .anthropic:
            return try decodeAnthropic(object)
        case .google:
            return decodeGoogle(object)
        }
    }

    private func decodeOpenAI(
        _ object: [String: Any],
        transport: OpenAICompatibleTransport
    ) throws -> AIProviderDecodedEvent {
        switch transport {
        case .responses:
            let type = object["type"] as? String
            if type == "response.output_text.delta", let delta = object["delta"] as? String {
                return delta.isEmpty ? .ignored : .text(delta)
            }
            if type == "response.completed" { return .done }
            if type == "error" {
                throw AIProviderError.providerStreamError(
                    boundedMessage(object["message"] as? String)
                )
            }
            if type == "response.failed",
                let response = object["response"] as? [String: Any],
                let error = response["error"] as? [String: Any]
            {
                throw AIProviderError.providerStreamError(
                    boundedMessage(error["message"] as? String)
                )
            }
            return .ignored
        case .chatCompletions:
            guard let choices = object["choices"] as? [[String: Any]],
                let choice = choices.first
            else { return .ignored }
            if choice["finish_reason"] as? String != nil { return .done }
            guard let delta = choice["delta"] as? [String: Any],
                let content = delta["content"] as? String,
                !content.isEmpty
            else { return .ignored }
            return .text(content)
        }
    }

    private func decodeAnthropic(_ object: [String: Any]) throws -> AIProviderDecodedEvent {
        let type = object["type"] as? String
        if type == "message_stop" { return .done }
        if type == "error", let error = object["error"] as? [String: Any] {
            throw AIProviderError.providerStreamError(
                boundedMessage(error["message"] as? String)
            )
        }
        guard type == "content_block_delta",
            let delta = object["delta"] as? [String: Any],
            delta["type"] as? String == "text_delta",
            let text = delta["text"] as? String,
            !text.isEmpty
        else { return .ignored }
        return .text(text)
    }

    private func decodeGoogle(_ object: [String: Any]) -> AIProviderDecodedEvent {
        guard let candidates = object["candidates"] as? [[String: Any]],
            let candidate = candidates.first,
            let content = candidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return .ignored }

        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .ignored : .text(text)
    }

    private func boundedMessage(_ message: String?) -> String {
        let fallback = "The provider reported a streaming error."
        guard let message else { return fallback }
        let cleaned = message.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return fallback }
        let prefix = cleaned.utf8.prefix(512)
        return String(decoding: prefix, as: UTF8.self)
    }
}
