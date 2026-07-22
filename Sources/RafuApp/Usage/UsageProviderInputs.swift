import Foundation

/// Provider-scoped browser import requests. Keeping the bounded domain/name
/// allowlists here gives Settings one source of truth without exposing a
/// browser's full cookie jar or asking provider strategies to trigger imports.
nonisolated struct UsageCookieImportRequest: Equatable, Sendable {
    let domains: [String]
    let names: [String]?
}

nonisolated enum UsageCookieImportCatalog {
    static let factoryDroidCookieNames = [
        "wos-session",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "__Secure-authjs.session-token",
        "__Host-authjs.csrf-token",
        "authjs.session-token",
        "session",
        "access-token",
    ]

    static func request(
        for provider: UsageProviderID,
        qoderRegion: QoderRegion = QoderRegionPreference.load()
    ) -> UsageCookieImportRequest? {
        switch provider {
        case .grokBuild:
            UsageCookieImportRequest(domains: ["grok.com"], names: ["sso", "sso-rw"])
        case .factoryDroid:
            UsageCookieImportRequest(
                domains: ["factory.ai", "app.factory.ai", "auth.factory.ai"],
                names: factoryDroidCookieNames)
        case .qoder:
            UsageCookieImportRequest(
                domains: qoderRegion.cookieImportDomains,
                names: nil)
        default:
            nil
        }
    }
}

/// Redacted outcomes that may cross back to the Settings model. Cookie values
/// never enter observable state or user-facing errors.
nonisolated enum UsageCookieImportResult: Equatable, Sendable {
    case imported(browser: Browser)
    case needsFullDiskAccess
    case noMatchingCookies
    case browserUnavailable
    case storageFailed
    case invalidRequest
    case cancelled
}

nonisolated enum UsageAPIKeyTestResult: Equatable, Sendable {
    case succeeded(identity: String?)
    case failed
    case cancelled
}

/// Runs one explicit provider resolution against an injected HTTP client.
/// Local files and imported cookies are absent so an API-key provider's test
/// cannot accidentally validate a different authentication path.
nonisolated struct UsageAPIKeyTestService: Sendable {
    private let http: UsageHTTPClient

    init(http: UsageHTTPClient = UsageHTTPClient()) {
        self.http = http
    }

    @concurrent
    func test(
        _ id: UsageProviderID, credential: String, now: Date
    ) async -> UsageAPIKeyTestResult {
        guard !Task.isCancelled,
            let descriptor = UsageProviderRegistry.descriptor(for: id),
            case .apiKey = descriptor.authPattern
        else { return Task.isCancelled ? .cancelled : .failed }

        let context = UsageFetchContext(
            now: now,
            readFile: { _ in nil },
            http: http,
            credential: { requestedID in requestedID == id ? credential : nil },
            cookieHeader: { _ in nil })
        let snapshot = await resolveUsageSnapshot(
            strategies: descriptor.makeStrategies(context), context: context)
        guard !Task.isCancelled else { return .cancelled }
        guard let snapshot, snapshot.renderable else { return .failed }
        return .succeeded(identity: snapshot.identity)
    }
}

/// Injectable Settings boundary. Production closures are the only paths from
/// the Usage tab into Rafu's Keychain, browser importer/cache, and one-shot
/// provider test fetch. Tests replace every closure and never touch those
/// external resources.
nonisolated struct UsageProviderInputClient: Sendable {
    typealias CredentialLoader = @Sendable (UsageProviderID) async throws -> String?
    typealias CredentialWriter = @Sendable (String, UsageProviderID) async throws -> Void
    typealias CredentialRemover = @Sendable (UsageProviderID) async throws -> Void
    typealias APIKeyTester =
        @Sendable (UsageProviderID, String, Date) async -> UsageAPIKeyTestResult
    typealias CookiePresence = @Sendable (UsageProviderID) async -> Bool
    typealias CookieImporter =
        @MainActor @Sendable (UsageProviderID, Browser) async -> UsageCookieImportResult
    typealias CookieRemover = @Sendable (UsageProviderID) async throws -> Void

    let loadCredential: CredentialLoader
    let writeCredential: CredentialWriter
    let removeCredential: CredentialRemover
    let testAPIKey: APIKeyTester
    let hasImportedCookie: CookiePresence
    let importCookies: CookieImporter
    let removeCookies: CookieRemover

    static let production = UsageProviderInputClient(
        loadCredential: { id in
            try await UsageCredentialStore.shared.credential(for: id)
        },
        writeCredential: { value, id in
            try await UsageCredentialStore.shared.setCredential(value, for: id)
        },
        removeCredential: { id in
            try await UsageCredentialStore.shared.removeCredential(for: id)
        },
        testAPIKey: { id, credential, now in
            await UsageAPIKeyTestService().test(id, credential: credential, now: now)
        },
        hasImportedCookie: { id in
            await UsageProviderInputOperations.hasImportedCookie(for: id)
        },
        importCookies: { id, browser in
            await UsageProviderInputOperations.importCookies(for: id, from: browser)
        },
        removeCookies: { id in
            try await CookieHeaderCache.shared.remove(for: id)
        })
}

private nonisolated enum UsageProviderInputOperations {
    @concurrent
    static func hasImportedCookie(for id: UsageProviderID) async -> Bool {
        CookieHeaderCache.shared.header(for: id) != nil
    }

    /// Constructing a fresh importer per explicit click is intentional: W1's
    /// importer is one-shot so a retry always represents fresh user intent.
    @MainActor
    static func importCookies(
        for id: UsageProviderID, from browser: Browser
    ) async -> UsageCookieImportResult {
        guard let request = UsageCookieImportCatalog.request(for: id) else {
            return .invalidRequest
        }
        let importer = BrowserCookieImporter.userInitiated()
        let outcome = await importer.importCookieHeaderOutcome(
            domains: request.domains,
            names: request.names,
            browsers: [browser])

        switch outcome {
        case .imported(let header):
            do {
                try await CookieHeaderCache.shared.store(header.rawValue, for: id)
                return .imported(browser: header.browser)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .storageFailed
            }
        case .needsFullDiskAccess:
            return .needsFullDiskAccess
        case .unavailable:
            return .browserUnavailable
        case .noMatchingCookies:
            return .noMatchingCookies
        case .authorizationRequired, .invalidRequest:
            return .invalidRequest
        case .cancelled:
            return .cancelled
        }
    }
}
