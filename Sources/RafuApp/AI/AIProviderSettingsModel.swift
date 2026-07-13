import Foundation
import Observation

@MainActor
@Observable
final class AIProviderSettingsModel {
    enum Status: Equatable {
        case idle
        case working(String)
        case success(String)
        case failure(String)
    }

    private(set) var configurations: [AIProviderConfiguration] = []
    var selectedID: UUID?
    var draftName = ""
    var draftKind = AIProviderKind.openAI
    var draftBaseURL = ""
    var draftModel = ""
    var draftModelAlias = ""
    var draftTransport = OpenAICompatibleTransport.responses
    var draftMaxOutputTokens = 256
    var apiKey = ""
    private(set) var hasStoredAPIKey = false
    private(set) var status = Status.idle

    @ObservationIgnored private let configurationStore: any AIProviderConfigurationStoring
    @ObservationIgnored private let secretStore: any AISecretStoring
    @ObservationIgnored private let client: AIProviderClient
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoaded = false

    init(
        configurationStore: any AIProviderConfigurationStoring =
            UserDefaultsAIProviderConfigurationStore(),
        secretStore: any AISecretStoring = KeychainAISecretStore(),
        client: AIProviderClient = AIProviderClient()
    ) {
        self.configurationStore = configurationStore
        self.secretStore = secretStore
        self.client = client
    }

    isolated deinit {
        operationTask?.cancel()
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            let stored = try await configurationStore.load()
            configurations =
                stored.isEmpty
                ? [AIProviderConfiguration.defaultConfiguration(for: .openAI)] : stored
            let preferredID = await configurationStore.selectedConfigurationID()
            let resolvedID =
                preferredID.flatMap { preferredID in
                    configurations.first(where: { $0.id == preferredID })?.id
                } ?? configurations[0].id
            await select(resolvedID)
        } catch {
            status = .failure(Self.message(for: error))
        }
    }

    func select(_ id: UUID) async {
        guard let configuration = configurations.first(where: { $0.id == id }) else { return }
        selectedID = id
        await configurationStore.setSelectedConfigurationID(id)
        apply(configuration)
        apiKey = ""
        do {
            hasStoredAPIKey = try await secretStore.secret(for: id) != nil
        } catch {
            hasStoredAPIKey = false
            status = .failure(Self.message(for: error))
        }
    }

    func add(_ kind: AIProviderKind) {
        var configuration = AIProviderConfiguration.defaultConfiguration(for: kind)
        if kind == .openAICompatible { configuration.model = "model-name" }
        configurations.append(configuration)
        selectedID = configuration.id
        apply(configuration)
        apiKey = ""
        hasStoredAPIKey = false
        status = .idle
    }

    func applyKindDefaults(_ kind: AIProviderKind) {
        draftBaseURL = kind.defaultBaseURL.absoluteString
        draftModel = kind.defaultModel
        if kind == .openAICompatible, draftModel.isEmpty { draftModel = "model-name" }
        if kind != .openAICompatible, kind != .openAI { draftTransport = .responses }
    }

    func beginSave() {
        startOperation { model in try await model.save() }
    }

    func beginSelect(_ id: UUID) {
        startOperation { model in await model.select(id) }
    }

    func beginTest() {
        startOperation { model in try await model.test() }
    }

    func beginDelete() {
        startOperation { model in try await model.deleteSelected() }
    }

    func beginRemoveAPIKey() {
        startOperation { model in try await model.removeAPIKey() }
    }

    private func startOperation(
        _ operation: @escaping @MainActor (AIProviderSettingsModel) async throws -> Void
    ) {
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(self)
            } catch is CancellationError {
                status = .idle
            } catch {
                status = .failure(Self.message(for: error))
            }
        }
    }

    private func save() async throws {
        status = .working("Saving…")
        let configuration = try draftConfiguration().validated()
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await secretStore.setSecret(apiKey, for: configuration.id)
            apiKey = ""
            hasStoredAPIKey = true
        }
        try await configurationStore.save(configurations)
        await configurationStore.setSelectedConfigurationID(configuration.id)
        status = .success("Provider saved.")
    }

    private func test() async throws {
        status = .working("Testing…")
        let configuration = try draftConfiguration().validated()
        let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key =
            enteredKey.isEmpty
            ? try await secretStore.secret(for: configuration.id) : enteredKey
        guard let key, !key.isEmpty else { throw AIProviderError.missingAPIKey }
        let result = try await client.testConnection(configuration: configuration, apiKey: key)
        status = .success(result.response)
    }

    private func deleteSelected() async throws {
        guard let selectedID else { return }
        configurations.removeAll { $0.id == selectedID }
        try await secretStore.removeSecret(for: selectedID)
        try await configurationStore.save(configurations)
        if let next = configurations.first {
            await select(next.id)
        } else {
            await configurationStore.setSelectedConfigurationID(nil)
            add(.openAI)
        }
        status = .success("Provider removed.")
    }

    private func removeAPIKey() async throws {
        guard let selectedID else { return }
        try await secretStore.removeSecret(for: selectedID)
        apiKey = ""
        hasStoredAPIKey = false
        status = .success("API key removed from Keychain.")
    }

    private func draftConfiguration() throws -> AIProviderConfiguration {
        guard let id = selectedID,
            let baseURL = URL(string: draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw AIProviderError.invalidConfiguration("Enter a valid base URL.")
        }
        return AIProviderConfiguration(
            id: id,
            name: draftName,
            kind: draftKind,
            baseURL: baseURL,
            model: draftModel,
            modelAlias: draftModelAlias,
            openAITransport: draftTransport,
            maxOutputTokens: draftMaxOutputTokens
        )
    }

    private func apply(_ configuration: AIProviderConfiguration) {
        draftName = configuration.name
        draftKind = configuration.kind
        draftBaseURL = configuration.baseURL.absoluteString
        draftModel = configuration.model
        draftModelAlias = configuration.modelAlias ?? ""
        draftTransport = configuration.openAITransport
        draftMaxOutputTokens = configuration.maxOutputTokens
    }

    private static func message(for error: Error) -> String {
        let value = (error as? LocalizedError)?.errorDescription ?? "The operation failed."
        return String(decoding: value.utf8.prefix(512), as: UTF8.self)
    }
}
