import Foundation
import Security

nonisolated protocol AISecretStoring: Sendable {
    func secret(for configurationID: UUID) async throws -> String?
    func setSecret(_ secret: String, for configurationID: UUID) async throws
    func removeSecret(for configurationID: UUID) async throws
}

actor KeychainAISecretStore: AISecretStoring {
    static let maximumSecretBytes = 16 * 1_024

    private let service: String

    init(service: String = "com.rafu.ai-provider-key") {
        self.service = service
    }

    func secret(for configurationID: UUID) throws -> String? {
        var query = baseQuery(for: configurationID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AIProviderError.keychainFailure(status: status)
        }
        guard let data = result as? Data, data.count <= Self.maximumSecretBytes,
            let value = String(data: data, encoding: .utf8)
        else {
            throw AIProviderError.keychainFailure(status: errSecDecode)
        }
        return value
    }

    func setSecret(_ secret: String, for configurationID: UUID) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        guard !data.isEmpty else { throw AIProviderError.missingAPIKey }
        guard data.count <= Self.maximumSecretBytes else {
            throw AIProviderError.invalidConfiguration("API keys may not exceed 16 KiB.")
        }

        let query = baseQuery(for: configurationID)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AIProviderError.keychainFailure(status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw AIProviderError.keychainFailure(status: insertStatus)
        }
    }

    func removeSecret(for configurationID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: configurationID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProviderError.keychainFailure(status: status)
        }
    }

    private func baseQuery(for configurationID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: configurationID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
