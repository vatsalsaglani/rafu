import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

private func claudeOAuthContext(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    http: UsageHTTPClient = .noop,
    credential: String? = nil,
    reads: ClaudeSynchronousCounter? = nil
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { _ in
            reads?.increment()
            return nil
        },
        http: http,
        credential: { id in id == .claude ? credential : nil },
        cookieHeader: { _ in nil })
}

private func claudeEnvelope(token: String, expiresAt: Date) -> String {
    guard
        let encoded = UsageExternalCredentialEnvelope(
            accessToken: token, accountID: nil, expiresAt: expiresAt
        ).encoded()
    else { fatalError("test envelope must encode") }
    return encoded
}

private func claudeCredentials(token: String, expiresAt: Date) -> String {
    let milliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
    return """
        {
          "claudeAiOauth": {
            "accessToken": "\(token)",
            "refreshToken": "must-not-cross-the-bridge",
            "expiresAt": \(milliseconds),
            "scopes": ["user:profile"]
          }
        }
        """
}

private actor ClaudeRequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

private actor ClaudeAttemptCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private final class ClaudeSynchronousCounter: Sendable {
    private let countStorage = Mutex(0)

    var count: Int { countStorage.withLock { $0 } }

    func increment() {
        countStorage.withLock { $0 += 1 }
    }
}

private struct ClaudeFixtureLocalStrategy: UsageFetchStrategy {
    let id = "claude.fixture-local"
    let attempts: ClaudeAttemptCounter

    func isAvailable(_ context: UsageFetchContext) async -> Bool { true }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        await attempts.increment()
        return UsageSnapshot(
            providerID: .claude,
            windows: [UsageWindow(label: "local", percent: nil, tokens: 123, resetsAt: nil)],
            costLine: nil,
            identity: nil)
    }

    func shouldFallback(on error: Error) -> Bool { false }
}

private struct ClaudeHostileTransportError: Error, CustomStringConvertible, Sendable {
    let description: String
}

enum ClaudeInvalidFile: CaseIterable, Sendable {
    case absent
    case malformed
    case expired

    func contents(now: Date) -> String? {
        switch self {
        case .absent:
            nil
        case .malformed:
            #"{"claudeAiOauth":{"accessToken":42}}"#
        case .expired:
            claudeCredentials(token: "expired-file-token", expiresAt: now.addingTimeInterval(-1))
        }
    }
}

private let claudeUsageFixture = """
    {
      "five_hour": {
        "utilization": 12.5,
        "resets_at": "2026-07-23T12:00:00.000Z"
      },
      "seven_day": {
        "utilization": 30,
        "resets_at": "2026-07-29T00:00:00.000Z"
      },
      "limits": [
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 9,
          "resets_at": "2026-07-29T00:00:00.000Z",
          "scope": { "model": null }
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 5,
          "resets_at": "2026-07-29T00:00:00.000Z",
          "is_active": false,
          "scope": { "model": { "id": "claude-fable", "display_name": "Fable" } }
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 6,
          "resets_at": "2026-07-29T00:00:00.000Z",
          "scope": { "model": { "id": "claude-fable", "display_name": "Fable" } }
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 7,
          "resets_at": "2026-07-29T00:00:00.000Z",
          "scope": { "model": { "id": "claude-other", "display_name": "Other" } }
        }
      ]
    }
    """

@Test("Claude CLI parser copies only the access token and millisecond expiry into an envelope")
func claudeCredentialParserProducesMinimalEnvelope() throws {
    let expiry = Date(timeIntervalSince1970: 1_800_000_123)
    let envelope = try #require(
        UsageExternalCredentialParser.claude(
            contents: claudeCredentials(token: "file-token", expiresAt: expiry)))

    #expect(envelope.accessToken == "file-token")
    #expect(envelope.accountID == nil)
    #expect(envelope.expiresAt == expiry)
    let encoded = try #require(envelope.encoded())
    #expect(!encoded.contains("refresh"))
    #expect(!encoded.contains("scopes"))
}

@Test("Claude Connect accepts a valid CLI file without reading Claude Code Keychain")
func claudeConnectorValidFileNeverReadsKeychain() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = "ClaudeConnectorTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let consent = UsageNetworkConsentStore(suiteName: suite)
    let credentialStore = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let keychainReads = ClaudeSynchronousCounter()
    let connector = UsageOAuthConnector(
        credentialFileReader: { id in
            id == .claude
                ? claudeCredentials(
                    token: "file-token", expiresAt: now.addingTimeInterval(3_600))
                : nil
        },
        claudeKeychainReader: {
            keychainReads.increment()
            return .credential("must-not-be-read")
        },
        credentialStore: credentialStore,
        consentStore: consent)

    #expect(await connector.connect(.claude, now: now) == .connected)
    #expect(keychainReads.count == 0)
    #expect(consent.hasConsent(for: .claude))
    #expect(await credentialStore.transientExternalCredential(for: .claude) == nil)
}

@Test(
    "Claude Connect reads Claude Code Keychain exactly once after an absent, malformed, or expired file",
    arguments: ClaudeInvalidFile.allCases)
func claudeConnectorFallsBackToKeychainExactlyOnce(condition: ClaudeInvalidFile) async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = "ClaudeConnectorTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let consent = UsageNetworkConsentStore(suiteName: suite)
    let credentialStore = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let keychainReads = ClaudeSynchronousCounter()
    let connector = UsageOAuthConnector(
        credentialFileReader: { id in id == .claude ? condition.contents(now: now) : nil },
        claudeKeychainReader: {
            keychainReads.increment()
            return .credential(
                claudeCredentials(
                    token: "keychain-token", expiresAt: now.addingTimeInterval(3_600)))
        },
        credentialStore: credentialStore,
        consentStore: consent)

    #expect(await connector.connect(.claude, now: now) == .connected)
    #expect(keychainReads.count == 1)
    #expect(consent.hasConsent(for: .claude))
    let cached = try #require(
        await credentialStore.transientExternalCredential(for: .claude))
    #expect(UsageExternalCredentialEnvelope.parse(cached)?.accessToken == "keychain-token")
}

@Test("A failed Claude Connect leaves neither network consent nor transient credentials")
func claudeConnectorFailureLeavesNoAuthority() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = "ClaudeConnectorTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let consent = UsageNetworkConsentStore(suiteName: suite)
    let credentialStore = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let preexisting = claudeEnvelope(
        token: "old-token", expiresAt: now.addingTimeInterval(3_600))
    _ = await credentialStore.setTransientExternalCredential(preexisting, for: .claude)
    consent.setConsent(true, for: .claude)
    let connector = UsageOAuthConnector(
        credentialFileReader: { _ in nil },
        claudeKeychainReader: { .unavailable },
        credentialStore: credentialStore,
        consentStore: consent)

    #expect(
        await connector.connect(.claude, now: now) == .failed(.credentialsUnavailable))
    #expect(!consent.hasConsent(for: .claude))
    #expect(await credentialStore.transientExternalCredential(for: .claude) == nil)
}

@Test("Claude Connect reports Keychain denial as a fixed redacted issue")
func claudeConnectorRedactsKeychainDenial() async {
    let suite = "ClaudeConnectorTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let consent = UsageNetworkConsentStore(suiteName: suite)
    let connector = UsageOAuthConnector(
        credentialFileReader: { _ in nil },
        claudeKeychainReader: { .accessDenied },
        credentialStore: UsageCredentialStore(
            servicePrefix: "test.claude.\(UUID().uuidString)"),
        consentStore: consent)

    #expect(
        await connector.connect(.claude) == .failed(.credentialAccessDenied))
    #expect(!consent.hasConsent(for: .claude))
}

@Test("Claude Disconnect clears transient authority without disabling local usage")
func claudeDisconnectPreservesEnablement() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = "ClaudeConnectorTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let consent = UsageNetworkConsentStore(suiteName: suite)
    let enable = UsageEnableStore(suiteName: suite)
    let credentialStore = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let connector = UsageOAuthConnector(
        credentialFileReader: { _ in nil },
        claudeKeychainReader: {
            .credential(
                claudeCredentials(
                    token: "keychain-token", expiresAt: now.addingTimeInterval(3_600)))
        },
        credentialStore: credentialStore,
        consentStore: consent)

    #expect(await connector.connect(.claude, now: now) == .connected)
    await connector.disconnect(.claude)

    #expect(!consent.hasConsent(for: .claude))
    #expect(await credentialStore.transientExternalCredential(for: .claude) == nil)
    #expect(enable.isEnabled(.claude, default: true))
}

@Test("Claude OAuth accepts inactive-shaped limits and keeps one unique model-scoped window")
func claudeOAuthMapsUsageFixture() throws {
    let snapshot = try ClaudeOAuthStrategy.parseUsage(Data(claudeUsageFixture.utf8))

    #expect(snapshot.providerID == .claude)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.windows.map(\.label) == ["5h", "7d", "Fable 7d"])
    #expect(snapshot.windows.map(\.percent) == [12.5, 30, 5])
    #expect(snapshot.windows.allSatisfy { $0.tokens == nil })
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_784_808_000))
    #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_785_283_200))
    #expect(snapshot.windows[2].resetsAt == Date(timeIntervalSince1970: 1_785_283_200))
}

@Test("Claude descriptor strategy order and count are context-independent")
func claudeOAuthStrategyOrderIsStable() {
    let empty = claudeOAuthContext()
    let connected = claudeOAuthContext(
        credential: claudeEnvelope(
            token: "token", expiresAt: empty.now.addingTimeInterval(3_600)))

    #expect(
        ClaudeProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "claude.oauth", "claude.local-transcripts",
        ])
    #expect(
        ClaudeProvider.descriptor.makeStrategies(connected).map(\.id) == [
            "claude.oauth", "claude.local-transcripts",
        ])
}

@Test("Claude OAuth strategy never reads files and a missing envelope uses local fallback")
func claudeOAuthMissingEnvelopeFallsBackWithoutFileRead() async {
    let reads = ClaudeSynchronousCounter()
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [ClaudeOAuthStrategy(), ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(reads: reads))

    #expect(result?.windows.first?.tokens == 123)
    #expect(reads.count == 0)
    #expect(await attempts.count == 1)
}

@Test("An expired Claude envelope falls back locally without a network request")
func claudeOAuthExpiredEnvelopeFallsBackWithoutNetwork() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let network = ClaudeSynchronousCounter()
    let http = UsageHTTPClient(transport: { _ in
        network.increment()
        throw ClaudeHostileTransportError(description: "must not run")
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [ClaudeOAuthStrategy(), ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(
            now: now, http: http,
            credential: claudeEnvelope(token: "expired", expiresAt: now.addingTimeInterval(-1))))

    #expect(result?.windows.first?.tokens == 123)
    #expect(network.count == 0)
    #expect(await attempts.count == 1)
}

@Test("Claude OAuth sends its envelope token only to the exact endpoint with bounded headers")
func claudeOAuthRequestUsesEnvelopeAndExactHeaders() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = ClaudeRequestRecorder()
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(claudeUsageFixture.utf8), response)
    })

    let snapshot = try await ClaudeOAuthStrategy().fetch(
        claudeOAuthContext(
            now: now, http: http,
            credential: claudeEnvelope(
                token: "envelope-token", expiresAt: now.addingTimeInterval(3_600))))
    let request = try #require(await recorder.request)

    #expect(snapshot.windows.first?.percent == 12.5)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.timeoutInterval == 15)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer envelope-token")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
        request.value(forHTTPHeaderField: "User-Agent") == "Rafu/\(RafuBuildInformation.version)")
}

@Test("Claude OAuth falls back locally only for authentication rejection", arguments: [401, 403])
func claudeOAuthAuthenticationRejectionFallsBack(status: Int) async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [ClaudeOAuthStrategy(), ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(
            now: now, http: http,
            credential: claudeEnvelope(
                token: "token", expiresAt: now.addingTimeInterval(3_600))))

    #expect(result?.windows.first?.tokens == 123)
    #expect(await attempts.count == 1)
}

@Test("Claude malformed usage hides the tile instead of fabricating a local result")
func claudeOAuthMalformedResponseHidesTile() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(#"{"five_hour":{"utilization":"bad"}}"#.utf8), response)
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [ClaudeOAuthStrategy(), ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(
            now: now, http: http,
            credential: claudeEnvelope(
                token: "token", expiresAt: now.addingTimeInterval(3_600))))

    #expect(result == nil)
    #expect(await attempts.count == 0)
}

@Test("Claude hostile transport diagnostics are redacted and never use local fallback")
func claudeOAuthTransportErrorIsRedacted() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let secret = "claude-super-secret"
    let http = UsageHTTPClient(transport: { _ in
        throw ClaudeHostileTransportError(
            description: "Authorization: Bearer \(secret); anthropic-beta: oauth-2025-04-20")
    })
    let strategy = ClaudeOAuthStrategy()
    let credential = claudeEnvelope(
        token: secret, expiresAt: now.addingTimeInterval(3_600))
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [strategy, ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(now: now, http: http, credential: credential))

    #expect(result == nil)
    #expect(await attempts.count == 0)
    do {
        _ = try await strategy.fetch(
            claudeOAuthContext(now: now, http: http, credential: credential))
        Issue.record("expected a redacted transport failure")
    } catch {
        let description = String(describing: error)
        #expect(!description.contains(secret))
        #expect(!description.lowercased().contains("bearer"))
        #expect(error as? UsageHTTPError == .transportFailure)
    }
}

@Test("Claude 429 and server errors hide the tile without local fallback", arguments: [429, 500])
func claudeOAuthNonAuthenticationFailuresHideTile(status: Int) async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [ClaudeOAuthStrategy(), ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(
            now: now, http: http,
            credential: claudeEnvelope(
                token: "token", expiresAt: now.addingTimeInterval(3_600))))

    #expect(result == nil)
    #expect(await attempts.count == 0)
}
