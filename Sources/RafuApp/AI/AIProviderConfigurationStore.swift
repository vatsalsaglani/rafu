import Foundation

nonisolated protocol AIProviderConfigurationStoring: Sendable {
    func load() async throws -> [AIProviderConfiguration]
    func save(_ configurations: [AIProviderConfiguration]) async throws
    func selectedConfigurationID() async -> UUID?
    func setSelectedConfigurationID(_ id: UUID?) async
}

actor UserDefaultsAIProviderConfigurationStore: AIProviderConfigurationStoring {
    private let defaults: UserDefaults
    private let key: String
    private let selectedKey: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "aiProviderConfigurations.v1",
        selectedKey: String = "aiSelectedProviderID.v1"
    ) {
        self.defaults = defaults
        self.key = key
        self.selectedKey = selectedKey
    }

    init(
        suiteName: String,
        key: String = "aiProviderConfigurations.v1",
        selectedKey: String = "aiSelectedProviderID.v1"
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create the requested UserDefaults suite.")
        }
        self.defaults = defaults
        self.key = key
        self.selectedKey = selectedKey
    }

    func load() throws -> [AIProviderConfiguration] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([AIProviderConfiguration].self, from: data)
    }

    func save(_ configurations: [AIProviderConfiguration]) throws {
        let data = try JSONEncoder().encode(configurations)
        defaults.set(data, forKey: key)
    }

    func selectedConfigurationID() -> UUID? {
        defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
    }

    func setSelectedConfigurationID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectedKey)
    }
}
