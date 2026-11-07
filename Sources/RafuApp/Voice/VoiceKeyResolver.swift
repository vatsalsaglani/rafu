import Foundation

/// Voice errors the user reads. Sentences carry no payload, key or transcript.
nonisolated enum VoiceError: Error, Equatable, LocalizedError {
    case noOpenAIKey
    case microphoneDenied
    case monthlyCapReached
    case startTimedOut
    case disconnected
    case audioUnavailable
    case refused(code: String)

    var errorDescription: String? { blobReason }

    /// A short reason for the blob and the status item.
    var blobReason: String {
        switch self {
        case .noOpenAIKey: "Add an OpenAI key in Settings ▸ AI"
        case .microphoneDenied: "Microphone access is off"
        case .monthlyCapReached: "Monthly voice cap reached"
        case .startTimedOut: "GPT-Live did not answer"
        case .disconnected: "Voice disconnected"
        case .audioUnavailable: "Audio is unavailable"
        case .refused(let code): "GPT-Live refused the session (\(code))"
        }
    }
}

/// Reads the OpenAI key through the existing AI provider store only: the
/// selected configuration when it is OpenAI, else the first OpenAI one. The
/// key goes from here into one request header and nowhere else.
enum VoiceKeyResolver {
    static func openAIKey(
        configurations: any AIProviderConfigurationStoring =
            UserDefaultsAIProviderConfigurationStore(),
        secrets: any AISecretStoring = KeychainAISecretStore()
    ) async throws -> String {
        let all = (try? await configurations.load()) ?? []
        let selected = await configurations.selectedConfigurationID()
        let openAI = all.filter { $0.kind == .openAI }
        guard
            let configuration = openAI.first(where: { $0.id == selected }) ?? openAI.first,
            let key = try? await secrets.secret(for: configuration.id), !key.isEmpty
        else { throw VoiceError.noOpenAIKey }
        return key
    }
}
