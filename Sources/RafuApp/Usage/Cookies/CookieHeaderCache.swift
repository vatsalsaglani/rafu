// Adapted from CodexBar's CookieHeaderCache/KeychainCacheStore, MIT License.
// Rafu's scope is intentionally smaller: one header per usage provider,
// in-memory memoization plus one item in Rafu's own Keychain, with no files,
// UserDefaults, logging, background revalidation, or legacy migration.

import Foundation
import Security
import Synchronization

nonisolated enum CookieHeaderCacheError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalidHeader
    case invalidStoredHeader
    case keychainFailure(status: OSStatus)

    var description: String {
        switch self {
        case .invalidHeader: "invalid cookie header"
        case .invalidStoredHeader: "invalid stored cookie header"
        case .keychainFailure(let status): "cookie Keychain failure (status \(status))"
        }
    }
}

/// Injectable persistence prevents tests from touching the real Keychain.
/// The production closures contain no log or error payload capable of
/// carrying a credential value.
nonisolated struct CookieHeaderPersistence: Sendable {
    let load: @Sendable (UsageProviderID) throws -> String?
    let store: @Sendable (String, UsageProviderID) throws -> Void
    let remove: @Sendable (UsageProviderID) throws -> Void

    static let keychain = CookieHeaderPersistence(
        load: Self.loadFromKeychain,
        store: Self.storeInKeychain,
        remove: Self.removeFromKeychain)

    private static func loadFromKeychain(for provider: UsageProviderID) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CookieHeaderCacheError.keychainFailure(status: status)
        }
        guard let data = result as? Data,
            data.count <= CookieHeaderCache.maximumHeaderBytes,
            let header = String(data: data, encoding: .utf8)
        else { throw CookieHeaderCacheError.invalidStoredHeader }
        return header
    }

    private static func storeInKeychain(
        _ header: String, for provider: UsageProviderID
    ) throws {
        let data = Data(header.utf8)
        var query = baseQuery(for: provider)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CookieHeaderCacheError.keychainFailure(status: updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(query as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw CookieHeaderCacheError.keychainFailure(status: insertStatus)
        }
    }

    private static func removeFromKeychain(for provider: UsageProviderID) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CookieHeaderCacheError.keychainFailure(status: status)
        }
    }

    private static func baseQuery(for provider: UsageProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: provider),
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static func serviceName(for provider: UsageProviderID) -> String {
        "rafu.usage.cookie.\(provider.rawValue)"
    }
}

/// Synchronous reads match UsageFetchContext.cookieHeader's binding seam.
/// The first miss hydrates from Rafu's Keychain; production usage refreshes
/// invoke this closure from their existing detached worker. Writes/removals
/// are `@concurrent` so Settings never blocks its actor on Security calls.
nonisolated final class CookieHeaderCache: Sendable {
    static let maximumHeaderBytes = 16 * 1_024
    static let shared = CookieHeaderCache()

    private struct State: Sendable {
        var loadedProviders: Set<UsageProviderID> = []
        var headers: [UsageProviderID: String] = [:]
        var generations: [UsageProviderID: UInt64] = [:]
    }

    private let persistence: CookieHeaderPersistence
    private let state = Mutex(State())
    private let mutationLock = Mutex<Void>(())

    init(persistence: CookieHeaderPersistence = .keychain) {
        self.persistence = persistence
    }

    /// Returns only a validated in-memory/own-Keychain header. Browser stores
    /// are never consulted here, which is what makes periodic refresh safe.
    func header(for provider: UsageProviderID) -> String? {
        let initial = state.withLock { state in
            (
                loaded: state.loadedProviders.contains(provider),
                header: state.headers[provider],
                generation: state.generations[provider, default: 0]
            )
        }
        if initial.loaded { return initial.header }

        let loadedHeader: String?
        do {
            if let candidate = try persistence.load(provider) {
                loadedHeader = try Self.validated(candidate, stored: true)
            } else {
                loadedHeader = nil
            }
        } catch CookieHeaderCacheError.invalidStoredHeader {
            return mutationLock.withLock { _ in
                let current = state.withLock { state in
                    (
                        generation: state.generations[provider, default: 0],
                        header: state.headers[provider]
                    )
                }
                guard current.generation == initial.generation else { return current.header }
                do {
                    try persistence.remove(provider)
                } catch {
                    return current.header
                }
                return state.withLock { state in
                    guard state.generations[provider, default: 0] == initial.generation else {
                        return state.headers[provider]
                    }
                    state.generations[provider, default: 0] &+= 1
                    state.loadedProviders.insert(provider)
                    state.headers.removeValue(forKey: provider)
                    return nil
                }
            }
        } catch {
            // A locked/unavailable Keychain is not authoritative absence.
            // Leave this provider unloaded so a later off-main refresh may
            // retry after the device is unlocked.
            return state.withLock { $0.headers[provider] }
        }

        return state.withLock { state in
            guard state.generations[provider, default: 0] == initial.generation else {
                return state.headers[provider]
            }
            state.loadedProviders.insert(provider)
            state.headers[provider] = loadedHeader
            return loadedHeader
        }
    }

    @concurrent
    func store(_ header: String, for provider: UsageProviderID) async throws {
        let validated = try Self.validated(header, stored: false)
        try mutationLock.withLock { _ in
            try persistence.store(validated, provider)
            state.withLock { state in
                state.generations[provider, default: 0] &+= 1
                state.loadedProviders.insert(provider)
                state.headers[provider] = validated
            }
        }
    }

    @concurrent
    func remove(for provider: UsageProviderID) async throws {
        try mutationLock.withLock { _ in
            try persistence.remove(provider)
            state.withLock { state in
                state.generations[provider, default: 0] &+= 1
                state.loadedProviders.insert(provider)
                state.headers.removeValue(forKey: provider)
            }
        }
    }

    private static func validated(_ rawHeader: String, stored: Bool) throws -> String {
        let header = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid =
            !header.isEmpty
            && header.utf8.count <= maximumHeaderBytes
            && header.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F && scalar != "\r"
                    && scalar != "\n" && scalar != "\0"
            }
        guard isValid else {
            throw stored ? CookieHeaderCacheError.invalidStoredHeader : .invalidHeader
        }
        return header
    }
}
