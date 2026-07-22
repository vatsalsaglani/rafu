import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

private func codexOAuthContext(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    http: UsageHTTPClient = .noop,
    credential: String? = nil,
    reads: CodexSynchronousCounter? = nil
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { _ in
            reads?.increment()
            return nil
        },
        http: http,
        credential: { id in id == .codex ? credential : nil },
        cookieHeader: { _ in nil })
}

private func codexEnvelope(
    token: String,
    accountID: String? = "account-123",
    expiresAt: Date? = nil
) -> String {
    guard
        let encoded = UsageExternalCredentialEnvelope(
            accessToken: token, accountID: accountID, expiresAt: expiresAt
        ).encoded()
    else { fatalError("test envelope must encode") }
    return encoded
}

private func codexAuth(
    token: String,
    accountID: String = "account-123",
    lastRefresh: Date?,
    camelCase: Bool = false
) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let refreshField =
        lastRefresh.map {
            ",\n  \"\(camelCase ? "lastRefresh" : "last_refresh")\": \"\(formatter.string(from: $0))\""
        } ?? ""
    return """
        {
          "tokens": {
            "\(camelCase ? "accessToken" : "access_token")": "\(token)",
            "\(camelCase ? "refreshToken" : "refresh_token")": "must-not-cross-the-bridge",
            "\(camelCase ? "accountId" : "account_id")": "\(accountID)",
            "id_token": "must-not-cross-the-bridge"
          }\(refreshField)
        }
        """
}

private func codexJWT(expiresAt: Date?) -> String {
    func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let payload = expiresAt.map { #"{"exp":\#($0.timeIntervalSince1970)}"# } ?? #"{"sub":"user"}"#
    return "\(base64URL(#"{"alg":"none"}"#)).\(base64URL(payload)).signature"
}

private actor CodexRequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

private actor CodexAttemptCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private final class CodexSynchronousCounter: Sendable {
    private let countStorage = Mutex(0)

    var count: Int { countStorage.withLock { $0 } }

    func increment() {
        countStorage.withLock { $0 += 1 }
    }
}

private struct CodexFixtureLocalStrategy: UsageFetchStrategy {
    let id = "codex.fixture-local"
    let attempts: CodexAttemptCounter

    func isAvailable(_ context: UsageFetchContext) async -> Bool { true }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        await attempts.increment()
        return UsageSnapshot(
            providerID: .codex,
            windows: [UsageWindow(label: "local", percent: 44, tokens: nil, resetsAt: nil)],
            costLine: nil,
            identity: nil)
    }

    func shouldFallback(on error: Error) -> Bool { false }
}

private struct CodexHostileTransportError: Error, CustomStringConvertible, Sendable {
    let description: String
}

enum CodexFileCondition: CaseIterable, Equatable, Sendable {
    case valid
    case absent

    func contents(now: Date) -> String? {
        switch self {
        case .valid:
            codexAuth(token: "file-token", lastRefresh: now.addingTimeInterval(-60))
        case .absent:
            nil
        }
    }
}

private let codexUsageFixture = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": 22.5,
          "reset_at": 1800001800,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 43,
          "reset_at": 1800604800,
          "limit_window_seconds": 604800
        }
      }
    }
    """

@Test(
    "Codex parser accepts snake/camel auth fields and discards refresh and ID tokens",
    arguments: [false, true])
func codexCredentialParserProducesMinimalEnvelope(camelCase: Bool) throws {
    let envelope = try #require(
        UsageExternalCredentialParser.codex(
            contents: codexAuth(
                token: "access-token", lastRefresh: Date(), camelCase: camelCase)))

    #expect(envelope.accessToken == "access-token")
    #expect(envelope.accountID == "account-123")
    let encoded = try #require(envelope.encoded())
    #expect(!encoded.contains("refresh"))
    #expect(!encoded.contains("id_token"))
}

@Test(
    "Codex parser allows old or missing last_refresh because JWT exp is authoritative",
    arguments: [false, true])
func codexParserIgnoresLastRefresh(missing: Bool) throws {
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let envelope = try #require(
        UsageExternalCredentialParser.codex(
            contents: codexAuth(
                token: "opaque-token", lastRefresh: missing ? nil : old)))

    #expect(envelope.accessToken == "opaque-token")
    #expect(envelope.expiresAt == nil)
    #expect(envelope.isUsable(for: .codex, at: Date(timeIntervalSince1970: 1_800_000_000)))
}

@Test("Codex auth URL honors CODEX_HOME without reading the filesystem")
func codexOAuthResolvesConfiguredHome() {
    let configured = UsageOAuthConnector.codexAuthURL(
        environment: ["CODEX_HOME": "/tmp/rafu-codex-home"])

    #expect(configured?.path == "/tmp/rafu-codex-home/auth.json")
    #expect(UsageOAuthConnector.codexAuthURL(environment: [:]) == nil)
    #expect(UsageOAuthConnector.codexAuthURL(environment: ["CODEX_HOME": "  "]) == nil)
}

@Test("Codex Connect never consults Claude Code Keychain", arguments: CodexFileCondition.allCases)
func codexConnectorNeverReadsClaudeKeychain(condition: CodexFileCondition) async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = "CodexConnectorTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let consent = UsageNetworkConsentStore(suiteName: suite)
    let credentialStore = UsageCredentialStore(servicePrefix: "test.codex.\(UUID().uuidString)")
    let keychainReads = CodexSynchronousCounter()
    let connector = UsageOAuthConnector(
        credentialFileReader: { id in id == .codex ? condition.contents(now: now) : nil },
        claudeKeychainReader: {
            keychainReads.increment()
            return .accessDenied
        },
        credentialStore: credentialStore,
        consentStore: consent)

    let result = await connector.connect(.codex, now: now)

    #expect(keychainReads.count == 0)
    #expect(result == (condition == .valid ? .connected : .failed(.credentialsUnavailable)))
    #expect(consent.hasConsent(for: .codex) == (condition == .valid))
    #expect(await credentialStore.transientExternalCredential(for: .codex) == nil)
}

@Test("Codex OAuth maps primary and secondary wham windows with reset dates")
func codexOAuthMapsUsageFixture() throws {
    let snapshot = try CodexOAuthStrategy.parseUsage(Data(codexUsageFixture.utf8))

    #expect(snapshot.providerID == .codex)
    #expect(snapshot.windows.map(\.label) == ["5h", "7d"])
    #expect(snapshot.windows.map(\.percent) == [22.5, 43])
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_001_800))
    #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_800_604_800))
}

@Test("Codex descriptor strategy order and count are context-independent")
func codexOAuthStrategyOrderIsStable() {
    let empty = codexOAuthContext()
    let connected = codexOAuthContext(credential: codexEnvelope(token: "opaque-token"))

    #expect(
        CodexProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "codex.oauth", "codex.local-rollout",
        ])
    #expect(
        CodexProvider.descriptor.makeStrategies(connected).map(\.id) == [
            "codex.oauth", "codex.local-rollout",
        ])
}

@Test("Codex OAuth strategy never reads files and a missing envelope uses local fallback")
func codexOAuthMissingEnvelopeFallsBackWithoutFileRead() async {
    let reads = CodexSynchronousCounter()
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [CodexOAuthStrategy(), CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(reads: reads))

    #expect(result?.windows.first?.percent == 44)
    #expect(reads.count == 0)
    #expect(await attempts.count == 1)
}

@Test("An expired Codex JWT envelope falls back locally without a network request")
func codexExpiredJWTFallsBackWithoutNetwork() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = codexJWT(expiresAt: now.addingTimeInterval(-1))
    let parsed = try #require(
        UsageExternalCredentialParser.codex(
            contents: codexAuth(token: token, lastRefresh: nil)))
    let encoded = try #require(parsed.encoded())
    let network = CodexSynchronousCounter()
    let http = UsageHTTPClient(transport: { _ in
        network.increment()
        throw CodexHostileTransportError(description: "must not run")
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [CodexOAuthStrategy(), CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(now: now, http: http, credential: encoded))

    #expect(result?.windows.first?.percent == 44)
    #expect(network.count == 0)
    #expect(await attempts.count == 1)
}

@Test("An opaque Codex token without JWT exp may request the exact wham endpoint")
func codexOAuthOpaqueTokenUsesExactHeaders() async throws {
    let recorder = CodexRequestRecorder()
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(codexUsageFixture.utf8), response)
    })

    let snapshot = try await CodexOAuthStrategy().fetch(
        codexOAuthContext(
            http: http,
            credential: codexEnvelope(token: "opaque-token", accountID: "account-123")))
    let request = try #require(await recorder.request)

    #expect(snapshot.windows.first?.percent == 22.5)
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.timeoutInterval == 15)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(
        request.value(forHTTPHeaderField: "User-Agent") == "Rafu/\(RafuBuildInformation.version)")
}

@Test("A Codex envelope without an account id omits the account header")
func codexOAuthOmitsMissingAccountHeader() async throws {
    let recorder = CodexRequestRecorder()
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(codexUsageFixture.utf8), response)
    })

    _ = try await CodexOAuthStrategy().fetch(
        codexOAuthContext(
            http: http,
            credential: codexEnvelope(token: "opaque-token", accountID: nil)))

    #expect(await recorder.request?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

@Test("Codex OAuth falls back locally only for authentication rejection", arguments: [401, 403])
func codexOAuthAuthenticationRejectionFallsBack(status: Int) async throws {
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [CodexOAuthStrategy(), CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(
            http: http, credential: codexEnvelope(token: "opaque-token")))

    #expect(result?.windows.first?.percent == 44)
    #expect(await attempts.count == 1)
}

@Test("Codex malformed wham usage hides the tile instead of fabricating a local result")
func codexOAuthMalformedResponseHidesTile() async throws {
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(#"{"rate_limit":{"primary_window":{"used_percent":"bad"}}}"#.utf8), response)
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [CodexOAuthStrategy(), CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(
            http: http, credential: codexEnvelope(token: "opaque-token")))

    #expect(result == nil)
    #expect(await attempts.count == 0)
}

@Test("Codex hostile transport diagnostics are redacted and never use local fallback")
func codexOAuthTransportErrorIsRedacted() async {
    let secret = "codex-super-secret"
    let http = UsageHTTPClient(transport: { _ in
        throw CodexHostileTransportError(
            description: "Authorization: Bearer \(secret); ChatGPT-Account-Id: account-123")
    })
    let strategy = CodexOAuthStrategy()
    let credential = codexEnvelope(token: secret)
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [strategy, CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(http: http, credential: credential))

    #expect(result == nil)
    #expect(await attempts.count == 0)
    do {
        _ = try await strategy.fetch(
            codexOAuthContext(http: http, credential: credential))
        Issue.record("expected a redacted transport failure")
    } catch {
        let description = String(describing: error)
        #expect(!description.contains(secret))
        #expect(!description.lowercased().contains("bearer"))
        #expect(error as? UsageHTTPError == .transportFailure)
    }
}

@Test("Codex 429 and server errors hide the tile without local fallback", arguments: [429, 500])
func codexOAuthNonAuthenticationFailuresHideTile(status: Int) async throws {
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [CodexOAuthStrategy(), CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(
            http: http, credential: codexEnvelope(token: "opaque-token")))

    #expect(result == nil)
    #expect(await attempts.count == 0)
}
