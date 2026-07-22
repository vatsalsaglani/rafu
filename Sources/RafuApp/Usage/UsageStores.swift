import Foundation
import Security

/// Per-provider enable state (usage-providers/W0-shim.md `UsageStores`).
/// Mirrors `NotchCompanionPreferenceStore`/`TerminalAttentionSurfaceStore`'s
/// suite-name idiom exactly: the SUITE NAME is stored, not a `UserDefaults`
/// instance (`UserDefaults` is not `Sendable` on this toolchain), so tests
/// inject an isolated suite instead of polluting the developer's real
/// defaults.
nonisolated struct UsageEnableStore: Sendable {
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static func key(for id: UsageProviderID) -> String {
        "usageProviderEnabled.\(id.rawValue)"
    }

    /// `defaultValue` is the provider's `UsageProviderDescriptor
    /// .defaultEnabled` — callers always pass it explicitly rather than
    /// this store hardcoding a value, so the store stays provider-agnostic.
    func isEnabled(_ id: UsageProviderID, default defaultValue: Bool) -> Bool {
        let key = Self.key(for: id)
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    func setEnabled(_ value: Bool, for id: UsageProviderID) {
        defaults.set(value, forKey: Self.key(for: id))
    }
}

/// The user's front-line ordering for the companion peek panel's usage
/// strip (agent-usage-providers.md, "Multi-provider display in the notch":
/// "up to 4 tiles the user picks and orders in Settings"). Defaults to the
/// shipped local providers in detection order — Claude, then Codex — so a
/// fresh install renders exactly what the pre-W0 strip always showed.
nonisolated struct UsageStripOrderStore: Sendable {
    static let defaultsKey = "usageStripOrder"
    static let defaultOrder: [UsageProviderID] = [.claude, .codex]

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// An unset value, or one that decodes to no known provider IDs, falls
    /// back to `defaultOrder` — never an empty front line by accident.
    func order() -> [UsageProviderID] {
        guard let rawValues = defaults.array(forKey: Self.defaultsKey) as? [String] else {
            return Self.defaultOrder
        }
        let ids = rawValues.compactMap(UsageProviderID.init(rawValue:))
        return ids.isEmpty ? Self.defaultOrder : ids
    }

    func setOrder(_ order: [UsageProviderID]) {
        defaults.set(order.map(\.rawValue), forKey: Self.defaultsKey)
    }
}

/// Failure modes for `UsageCredentialStore`, deliberately as bare as
/// `AIProviderError.keychainFailure`'s shape but scoped to this store (the
/// AI domain's error type is not reused here — usage credentials are a
/// separate concern with their own service namespace).
nonisolated enum UsageCredentialStoreError: Error, Sendable {
    case keychainFailure(status: OSStatus)
    case invalidStoredValue
    case emptySecret
}

/// User-entered API keys/imported cookies for usage providers, stored in
/// Rafu's OWN Keychain (AGENTS: "Store secrets in Keychain, never
/// `UserDefaults`") — never another app's token, which strategies read
/// live via `UsageFetchContext.credential`/`cookieHeader` instead. One
/// generic-password item per provider, `service = "rafu.usage.<id>"`,
/// mirroring `KeychainAISecretStore` (`AISecretStore.swift`) exactly.
///
/// W0 wires this into `UsageRegistryReader`'s production defaults but no
/// W0 strategy (the local Claude/Codex readers) ever calls it — the first
/// real consumer is whichever phase adds a credentialed strategy (W2's
/// Claude OAuth is the likely first). Tests must never construct or invoke
/// this actor.
actor UsageCredentialStore {
    static let maximumSecretBytes = 16 * 1_024

    private let servicePrefix: String

    init(servicePrefix: String = "rafu.usage") {
        self.servicePrefix = servicePrefix
    }

    func credential(for id: UsageProviderID) throws -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw UsageCredentialStoreError.keychainFailure(status: status)
        }
        guard let data = result as? Data, data.count <= Self.maximumSecretBytes,
            let value = String(data: data, encoding: .utf8)
        else {
            throw UsageCredentialStoreError.invalidStoredValue
        }
        return value
    }

    func setCredential(_ value: String, for id: UsageProviderID) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        guard !data.isEmpty else { throw UsageCredentialStoreError.emptySecret }
        guard data.count <= Self.maximumSecretBytes else {
            throw UsageCredentialStoreError.invalidStoredValue
        }

        let query = baseQuery(for: id)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw UsageCredentialStoreError.keychainFailure(status: updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw UsageCredentialStoreError.keychainFailure(status: insertStatus)
        }
    }

    func removeCredential(for id: UsageProviderID) throws {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UsageCredentialStoreError.keychainFailure(status: status)
        }
    }

    private func service(for id: UsageProviderID) -> String {
        "\(servicePrefix).\(id.rawValue)"
    }

    private func baseQuery(for id: UsageProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: id.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
