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

/// Per-provider permission for credential-bearing usage requests. This is
/// deliberately separate from `UsageEnableStore`: local usage stays enabled
/// when the user disconnects a provider, while network access defaults to
/// denied until an explicit successful Connect action.
nonisolated struct UsageNetworkConsentStore: Sendable {
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static func key(for id: UsageProviderID) -> String {
        "usageProviderNetworkConsent.\(id.rawValue)"
    }

    func hasConsent(for id: UsageProviderID) -> Bool {
        defaults.bool(forKey: Self.key(for: id))
    }

    func setConsent(_ value: Bool, for id: UsageProviderID) {
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

/// The complete external-credential value that may cross the async registry
/// bridge into `UsageFetchContext.credential`. Unknown keys are rejected so a
/// refresh token, ID token, scopes, or provider metadata cannot accidentally
/// hitch a ride with the access token.
nonisolated struct UsageExternalCredentialEnvelope: Codable, Equatable, Sendable {
    static let maximumEncodedBytes = 16 * 1_024

    let accessToken: String
    let accountID: String?
    let expiresAt: Date?

    func encoded() -> String? {
        guard let normalized = normalized() else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(normalized),
            data.count <= Self.maximumEncodedBytes
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ value: String) -> UsageExternalCredentialEnvelope? {
        let data = Data(value.utf8)
        guard !data.isEmpty, data.count <= Self.maximumEncodedBytes,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys).isSubset(of: ["accessToken", "accountID", "expiresAt"])
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let decoded = try? decoder.decode(Self.self, from: data) else { return nil }
        return decoded.normalized()
    }

    func isUsable(for id: UsageProviderID, at now: Date) -> Bool {
        switch id {
        case .claude:
            guard let expiresAt else { return false }
            return expiresAt > now
        case .codex:
            return expiresAt.map { $0 > now } ?? true
        default:
            return false
        }
    }

    private func normalized() -> UsageExternalCredentialEnvelope? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let account = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccount = account.flatMap { $0.isEmpty ? nil : $0 }
        guard expiresAt?.timeIntervalSinceReferenceDate.isFinite != false else { return nil }

        return UsageExternalCredentialEnvelope(
            accessToken: token, accountID: normalizedAccount, expiresAt: expiresAt)
    }
}

/// Bounded parsers for the two CLI-owned credential files. Only the fields
/// needed by the read-only usage endpoints are copied into the minimal
/// envelope; refresh/ID tokens and all other metadata are discarded.
nonisolated enum UsageExternalCredentialParser {
    static let maximumSourceBytes = 16 * 1_024

    static func claude(contents: String) -> UsageExternalCredentialEnvelope? {
        guard let data = boundedData(contents),
            let root = try? JSONDecoder().decode(ClaudeRoot.self, from: data),
            let oauth = root.claudeAiOauth,
            let token = oauth.accessToken,
            let expiresAtMilliseconds = oauth.expiresAt,
            expiresAtMilliseconds.isFinite
        else { return nil }

        let envelope = UsageExternalCredentialEnvelope(
            accessToken: token,
            accountID: nil,
            expiresAt: Date(timeIntervalSince1970: expiresAtMilliseconds / 1_000))
        return envelope.encoded().flatMap(UsageExternalCredentialEnvelope.parse)
    }

    static func codex(contents: String) -> UsageExternalCredentialEnvelope? {
        guard let data = boundedData(contents),
            let root = try? JSONDecoder().decode(CodexRoot.self, from: data),
            let tokens = root.tokens,
            let accessToken = tokens.accessToken
        else { return nil }

        let envelope = UsageExternalCredentialEnvelope(
            accessToken: accessToken,
            accountID: tokens.accountID,
            expiresAt: jwtExpiration(accessToken: accessToken))
        return envelope.encoded().flatMap(UsageExternalCredentialEnvelope.parse)
    }

    private static func boundedData(_ contents: String) -> Data? {
        let data = Data(contents.utf8)
        return if !data.isEmpty, data.count <= maximumSourceBytes { data } else { nil }
    }

    private static func jwtExpiration(accessToken: String) -> Date? {
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[1].utf8.count <= maximumSourceBytes else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.utf8.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload), data.count <= maximumSourceBytes,
            let claims = try? JSONDecoder().decode(JWTClaims.self, from: data),
            let expiration = claims.exp, expiration.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: expiration)
    }

    private struct ClaudeRoot: Decodable {
        let claudeAiOauth: ClaudeOAuth?
    }

    private struct ClaudeOAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
    }

    private struct CodexRoot: Decodable {
        let tokens: CodexTokens?
    }

    private struct CodexTokens: Decodable {
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessTokenSnake = "access_token"
            case accessTokenCamel = "accessToken"
            case accountIDSnake = "account_id"
            case accountIDCamel = "accountId"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken =
                try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
            accountID =
                try container.decodeIfPresent(String.self, forKey: .accountIDSnake)
                ?? container.decodeIfPresent(String.self, forKey: .accountIDCamel)
        }
    }

    private struct JWTClaims: Decodable {
        let exp: Double?
    }
}

nonisolated enum UsageOAuthConnectionIssue: Equatable, Sendable {
    case credentialsUnavailable
    case credentialsInvalid
    case credentialsExpired
    case credentialAccessDenied
    case unsupportedProvider
    case cancelled
}

nonisolated enum UsageOAuthConnectionOutcome: Equatable, Sendable {
    case connected
    case failed(UsageOAuthConnectionIssue)
}

nonisolated enum UsageOAuthCredentialLoadResult: Equatable, Sendable {
    case credential(UsageExternalCredentialEnvelope, cacheTransiently: Bool)
    case failed(UsageOAuthConnectionIssue)
}

nonisolated enum UsageClaudeKeychainReadResult: Equatable, Sendable {
    case credential(String)
    case unavailable
    case accessDenied
}

/// The persistent methods store only user-entered API keys/imported cookies
/// in Rafu's OWN Keychain (AGENTS: "Store secrets in Keychain, never
/// `UserDefaults`"). External agent tokens never enter those methods; the
/// separate bounded cache below may hold a Claude Code token only in process
/// memory after explicit Connect. Persistent items use one generic-password
/// item per provider, `service = "rafu.usage.<id>"`, mirroring
/// `KeychainAISecretStore` (`AISecretStore.swift`) exactly.
///
/// Focused tests may inject this actor to exercise the transient in-memory
/// cache, but never invoke its persistent Keychain methods.
actor UsageCredentialStore {
    static let maximumSecretBytes = 16 * 1_024
    static let shared = UsageCredentialStore()

    private let servicePrefix: String
    private var transientExternalCredentials: [UsageProviderID: String] = [:]

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

    /// External Claude/Codex tokens never enter Rafu's Keychain. This cache
    /// exists only for a Claude credential explicitly read from Claude Code's
    /// Keychain during Connect, and disappears with this process.
    func transientExternalCredential(for id: UsageProviderID) -> String? {
        transientExternalCredentials[id]
    }

    @discardableResult
    func setTransientExternalCredential(_ value: String, for id: UsageProviderID) -> Bool {
        guard id == .claude || id == .codex,
            UsageExternalCredentialEnvelope.parse(value) != nil
        else { return false }
        transientExternalCredentials[id] = value
        return true
    }

    func removeTransientExternalCredential(for id: UsageProviderID) {
        transientExternalCredentials[id] = nil
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

/// Explicit, no-network OAuth connection workflow. Production reads the CLI
/// credential file first; only Claude may fall back to Claude Code's
/// Keychain, and only from this Connect path. Injected readers/loaders keep
/// tests away from the user's home directory and Keychain.
nonisolated struct UsageOAuthConnector: Sendable {
    typealias CredentialFileReader = @Sendable (UsageProviderID) -> String?
    typealias ClaudeKeychainReader = @Sendable () -> UsageClaudeKeychainReadResult
    typealias CredentialLoader =
        @Sendable (UsageProviderID, Date) async -> UsageOAuthCredentialLoadResult

    private let credentialStore: UsageCredentialStore
    private let consentStore: UsageNetworkConsentStore
    private let credentialLoader: CredentialLoader

    init(
        credentialFileReader: @escaping CredentialFileReader = Self.productionCredentialFile,
        claudeKeychainReader: @escaping ClaudeKeychainReader = Self
            .productionClaudeKeychainCredential,
        credentialStore: UsageCredentialStore = .shared,
        consentStore: UsageNetworkConsentStore = UsageNetworkConsentStore()
    ) {
        self.credentialStore = credentialStore
        self.consentStore = consentStore
        credentialLoader = { id, now in
            Self.loadCredential(
                for: id, now: now, credentialFileReader: credentialFileReader,
                claudeKeychainReader: claudeKeychainReader)
        }
    }

    init(
        credentialLoader: @escaping CredentialLoader,
        credentialStore: UsageCredentialStore,
        consentStore: UsageNetworkConsentStore
    ) {
        self.credentialStore = credentialStore
        self.consentStore = consentStore
        self.credentialLoader = credentialLoader
    }

    func hasConsent(for id: UsageProviderID) -> Bool {
        consentStore.hasConsent(for: id)
    }

    @concurrent
    func connect(
        _ id: UsageProviderID, now: Date = Date()
    ) async -> UsageOAuthConnectionOutcome {
        consentStore.setConsent(false, for: id)
        await credentialStore.removeTransientExternalCredential(for: id)
        guard !Task.isCancelled else { return .failed(.cancelled) }

        let result = await credentialLoader(id, now)
        guard !Task.isCancelled else { return .failed(.cancelled) }
        switch result {
        case .failed(let issue):
            return .failed(issue)
        case .credential(let envelope, let cacheTransiently):
            guard envelope.isUsable(for: id, at: now) else {
                return .failed(.credentialsExpired)
            }
            guard let encoded = envelope.encoded() else { return .failed(.credentialsInvalid) }
            if cacheTransiently {
                guard await credentialStore.setTransientExternalCredential(encoded, for: id) else {
                    return .failed(.credentialsInvalid)
                }
                guard !Task.isCancelled else {
                    await credentialStore.removeTransientExternalCredential(for: id)
                    return .failed(.cancelled)
                }
            }
            consentStore.setConsent(true, for: id)
            return .connected
        }
    }

    func disconnect(_ id: UsageProviderID) async {
        consentStore.setConsent(false, for: id)
        await credentialStore.removeTransientExternalCredential(for: id)
    }

    static func productionCredentialFile(for id: UsageProviderID) -> String? {
        guard
            let url = credentialFileURL(
                for: id, environment: ProcessInfo.processInfo.environment)
        else { return nil }
        return boundedContents(of: url)
    }

    static func credentialFileURL(
        for id: UsageProviderID, environment: [String: String]
    ) -> URL? {
        switch id {
        case .claude:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json", isDirectory: false)
        case .codex:
            if let configured = codexAuthURL(environment: environment) { return configured }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json", isDirectory: false)
        default:
            return nil
        }
    }

    static func codexAuthURL(environment: [String: String]) -> URL? {
        guard
            let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !configuredHome.isEmpty
        else { return nil }
        return URL(
            fileURLWithPath: (configuredHome as NSString).expandingTildeInPath,
            isDirectory: true
        ).appendingPathComponent("auth.json", isDirectory: false)
    }

    static func productionClaudeKeychainCredential() -> UsageClaudeKeychainReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .unavailable }
        guard status == errSecSuccess else { return .accessDenied }
        guard
            let data = result as? Data,
            !data.isEmpty, data.count <= UsageExternalCredentialParser.maximumSourceBytes
        else { return .unavailable }
        guard let credential = String(data: data, encoding: .utf8) else {
            return .unavailable
        }
        return .credential(credential)
    }

    private static func loadCredential(
        for id: UsageProviderID,
        now: Date,
        credentialFileReader: CredentialFileReader,
        claudeKeychainReader: ClaudeKeychainReader
    ) -> UsageOAuthCredentialLoadResult {
        switch id {
        case .claude:
            let fileResult = classify(
                credentialFileReader(.claude), for: .claude, now: now,
                cacheTransiently: false)
            if case .credential = fileResult { return fileResult }
            switch claudeKeychainReader() {
            case .credential(let contents):
                return classify(
                    contents, for: .claude, now: now, cacheTransiently: true)
            case .unavailable:
                return .failed(.credentialsUnavailable)
            case .accessDenied:
                return .failed(.credentialAccessDenied)
            }
        case .codex:
            return classify(
                credentialFileReader(.codex), for: .codex, now: now,
                cacheTransiently: false)
        default:
            return .failed(.unsupportedProvider)
        }
    }

    private static func classify(
        _ contents: String?,
        for id: UsageProviderID,
        now: Date,
        cacheTransiently: Bool
    ) -> UsageOAuthCredentialLoadResult {
        guard let contents else { return .failed(.credentialsUnavailable) }
        let envelope: UsageExternalCredentialEnvelope?
        switch id {
        case .claude:
            envelope = UsageExternalCredentialParser.claude(contents: contents)
        case .codex:
            envelope = UsageExternalCredentialParser.codex(contents: contents)
        default:
            return .failed(.unsupportedProvider)
        }
        guard let envelope else { return .failed(.credentialsInvalid) }
        guard envelope.isUsable(for: id, at: now) else {
            return .failed(.credentialsExpired)
        }
        return .credential(envelope, cacheTransiently: cacheTransiently)
    }

    private static func boundedContents(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(
                upToCount: UsageExternalCredentialParser.maximumSourceBytes + 1),
            !data.isEmpty,
            data.count <= UsageExternalCredentialParser.maximumSourceBytes
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
