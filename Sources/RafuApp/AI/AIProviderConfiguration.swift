import Foundation

nonisolated enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case anthropic
    case google
    case openAICompatible

    var id: Self { self }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    var defaultBaseURL: URL {
        switch self {
        case .openAI:
            URL(string: "https://api.openai.com/v1")!
        case .anthropic:
            URL(string: "https://api.anthropic.com/v1")!
        case .google:
            URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        case .openAICompatible:
            URL(string: "https://example.com/v1")!
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5.1"
        case .anthropic: "claude-opus-4-20250514"
        case .google: "gemini-3.5-flash"
        case .openAICompatible: ""
        }
    }
}

nonisolated enum OpenAICompatibleTransport: String, CaseIterable, Codable, Identifiable, Sendable {
    case responses
    case chatCompletions

    var id: Self { self }

    var title: String {
        switch self {
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        }
    }
}

nonisolated struct AIProviderConfiguration: Codable, Hashable, Identifiable, Sendable {
    static let allowedOutputTokenRange = 16...2_048

    var id: UUID
    var name: String
    var kind: AIProviderKind
    var baseURL: URL
    var model: String
    /// Optional human-friendly label for the model (the wire `model` stays the
    /// provider's exact identifier).
    var modelAlias: String?
    var openAITransport: OpenAICompatibleTransport
    var maxOutputTokens: Int

    init(
        id: UUID = UUID(),
        name: String,
        kind: AIProviderKind,
        baseURL: URL? = nil,
        model: String? = nil,
        modelAlias: String? = nil,
        openAITransport: OpenAICompatibleTransport = .responses,
        maxOutputTokens: Int = 256
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.defaultModel
        self.modelAlias = modelAlias
        self.openAITransport = openAITransport
        self.maxOutputTokens = maxOutputTokens
    }

    /// Label shown in pickers and status text.
    var displayModelName: String {
        let alias = (modelAlias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return alias.isEmpty ? model : alias
    }

    static func defaultConfiguration(for kind: AIProviderKind) -> Self {
        Self(name: kind.title, kind: kind)
    }

    func validated() throws -> Self {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 128 else {
            throw AIProviderError.invalidConfiguration("Enter a provider name up to 128 bytes.")
        }
        guard !trimmedModel.isEmpty, trimmedModel.utf8.count <= 256 else {
            throw AIProviderError.invalidConfiguration("Enter a model name up to 256 bytes.")
        }
        guard !trimmedModel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw AIProviderError.invalidConfiguration(
                "Model names cannot contain control characters."
            )
        }
        if kind == .google,
            trimmedModel.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" })
        {
            throw AIProviderError.invalidConfiguration(
                "Google model names cannot contain '/', '?', or '#'."
            )
        }
        guard Self.allowedOutputTokenRange.contains(maxOutputTokens) else {
            throw AIProviderError.invalidConfiguration(
                "Maximum output tokens must be between 16 and 2,048."
            )
        }
        try Self.validate(baseURL: baseURL, kind: kind)

        let trimmedAlias = (modelAlias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAlias.utf8.count <= 128 else {
            throw AIProviderError.invalidConfiguration("Model aliases can be up to 128 bytes.")
        }

        var copy = self
        copy.name = trimmedName
        copy.model = trimmedModel
        copy.modelAlias = trimmedAlias.isEmpty ? nil : trimmedAlias
        return copy
    }

    private static func validate(baseURL: URL, kind: AIProviderKind) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw AIProviderError.invalidConfiguration(
                "Base URL must be an absolute endpoint without credentials, query, or fragment."
            )
        }

        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (kind == .openAICompatible && scheme == "http" && isLoopback)
        else {
            throw AIProviderError.invalidConfiguration(
                "Use HTTPS. Plain HTTP is allowed only for a loopback custom endpoint."
            )
        }
    }
}

nonisolated enum AIProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case missingAPIKey
    case selectedDiffsRequired
    case requestTooLarge(maximumBytes: Int)
    case responseTooLarge(maximumBytes: Int)
    case malformedResponse
    case invalidHTTPResponse
    case providerRejected(statusCode: Int, requestID: String?)
    case providerStreamError(String)
    case connectionTestMismatch
    case keychainFailure(status: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .missingAPIKey: "Enter an API key before connecting."
        case .selectedDiffsRequired: "Select at least one changed file."
        case .requestTooLarge(let maximumBytes):
            "The inference request exceeds the \(maximumBytes)-byte limit."
        case .responseTooLarge(let maximumBytes):
            "The provider response exceeds the \(maximumBytes)-byte limit."
        case .malformedResponse: "The provider returned an unreadable response."
        case .invalidHTTPResponse: "The provider did not return an HTTP response."
        case .providerRejected(let statusCode, let requestID):
            if let requestID {
                "The provider rejected the request (HTTP \(statusCode), request \(requestID))."
            } else {
                "The provider rejected the request (HTTP \(statusCode))."
            }
        case .providerStreamError(let message): message
        case .connectionTestMismatch:
            "The provider responded, but did not reply with exactly ‘Rafu live!’."
        case .keychainFailure(let status): "Keychain operation failed (status \(status))."
        }
    }
}
