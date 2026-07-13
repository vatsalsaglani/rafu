import Foundation

nonisolated struct AIProviderRequestBuilder: Sendable {
    static let maximumRequestBytes = 512 * 1_024
    static let requestTimeout: TimeInterval = 45
    static let anthropicVersion = "2023-06-01"

    func makeStreamingRequest(
        configuration: AIProviderConfiguration,
        apiKey: String,
        instructions: String,
        prompt: String
    ) throws -> URLRequest {
        let configuration = try configuration.validated()
        let apiKey = try validated(apiKey: apiKey)
        let endpoint = try endpoint(for: configuration)

        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any]
        switch configuration.kind {
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = openAIBody(
                transport: configuration.openAITransport,
                model: configuration.model,
                instructions: instructions,
                prompt: prompt,
                maxOutputTokens: configuration.maxOutputTokens,
                prefersModernChatTokenField: true
            )
        case .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = openAIBody(
                transport: configuration.openAITransport,
                model: configuration.model,
                instructions: instructions,
                prompt: prompt,
                maxOutputTokens: configuration.maxOutputTokens,
                prefersModernChatTokenField: false
            )
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body = [
                "model": configuration.model,
                "max_tokens": configuration.maxOutputTokens,
                "system": instructions,
                "messages": [["role": "user", "content": prompt]],
                "stream": true,
            ]
        case .google:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": configuration.maxOutputTokens],
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard data.count <= Self.maximumRequestBytes else {
            throw AIProviderError.requestTooLarge(maximumBytes: Self.maximumRequestBytes)
        }
        request.httpBody = data
        return request
    }

    private func validated(apiKey: String) throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProviderError.missingAPIKey }
        guard trimmed.utf8.count <= KeychainAISecretStore.maximumSecretBytes,
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw AIProviderError.invalidConfiguration("The API key has an invalid format.")
        }
        return trimmed
    }

    private func endpoint(for configuration: AIProviderConfiguration) throws -> URL {
        switch configuration.kind {
        case .openAI, .openAICompatible:
            switch configuration.openAITransport {
            case .responses:
                return appendingEndpoint(["responses"], to: configuration.baseURL)
            case .chatCompletions:
                return appendingEndpoint(["chat", "completions"], to: configuration.baseURL)
            }
        case .anthropic:
            return appendingEndpoint(["messages"], to: configuration.baseURL)
        case .google:
            var endpoint = appendingEndpoint(
                ["models", "\(configuration.model):streamGenerateContent"],
                to: configuration.baseURL
            )
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            else { throw AIProviderError.invalidConfiguration("The Google endpoint is invalid.") }
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            guard let streamedEndpoint = components.url else {
                throw AIProviderError.invalidConfiguration("The Google endpoint is invalid.")
            }
            endpoint = streamedEndpoint
            return endpoint
        }
    }

    private func appendingEndpoint(_ components: [String], to baseURL: URL) -> URL {
        let expectedSuffix = "/" + components.joined(separator: "/")
        if baseURL.path.hasSuffix(expectedSuffix) { return baseURL }
        return components.reduce(baseURL) { partialURL, component in
            partialURL.appending(path: component)
        }
    }

    private func openAIBody(
        transport: OpenAICompatibleTransport,
        model: String,
        instructions: String,
        prompt: String,
        maxOutputTokens: Int,
        prefersModernChatTokenField: Bool
    ) -> [String: Any] {
        switch transport {
        case .responses:
            return [
                "model": model,
                "instructions": instructions,
                "input": prompt,
                "max_output_tokens": maxOutputTokens,
                "stream": true,
                "store": false,
            ]
        case .chatCompletions:
            var body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": prompt],
                ],
                "stream": true,
            ]
            body[prefersModernChatTokenField ? "max_completion_tokens" : "max_tokens"] =
                maxOutputTokens
            return body
        }
    }
}
