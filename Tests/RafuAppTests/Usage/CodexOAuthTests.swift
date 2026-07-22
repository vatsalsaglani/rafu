import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

private func codexOAuthContext(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    http: UsageHTTPClient = .noop,
    credential: String? = "connected-token"
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { _ in nil },
        http: http,
        credential: { id in id == .codex ? credential : nil },
        cookieHeader: { _ in nil })
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

private final class CodexReadCounter: Sendable {
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
    let accessKey = camelCase ? "accessToken" : "access_token"
    let refreshKey = camelCase ? "refreshToken" : "refresh_token"
    let accountKey = camelCase ? "accountId" : "account_id"
    return """
        {
          "tokens": {
            "\(accessKey)": "\(token)",
            "\(refreshKey)": "unused-refresh-token",
            "\(accountKey)": "\(accountID)"
          }\(refreshField)
        }
        """
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

@Test("Codex OAuth credentials parse current snake_case auth.json fields")
func codexOAuthCredentialsParseSnakeCase() throws {
    let refresh = Date(timeIntervalSince1970: 1_799_999_000)
    let credentials = try #require(
        CodexOAuthCredentials.parse(
            contents: codexAuth(token: "snake-token", lastRefresh: refresh)))

    #expect(credentials.accessToken == "snake-token")
    #expect(credentials.accountID == "account-123")
    #expect(credentials.lastRefresh == refresh)
}

@Test("Codex OAuth credentials parse legacy camelCase auth.json fields")
func codexOAuthCredentialsParseCamelCase() throws {
    let refresh = Date(timeIntervalSince1970: 1_799_999_000)
    let credentials = try #require(
        CodexOAuthCredentials.parse(
            contents: codexAuth(
                token: "camel-token", lastRefresh: refresh, camelCase: true)))

    #expect(credentials.accessToken == "camel-token")
    #expect(credentials.accountID == "account-123")
    #expect(credentials.lastRefresh == refresh)
}

@Test("Codex OAuth resolves $CODEX_HOME before the default auth path without file I/O")
func codexOAuthResolvesConfiguredHome() {
    let configured = CodexOAuthStrategy.configuredAuthURL(
        environment: ["CODEX_HOME": "/tmp/rafu-codex-home"])

    #expect(configured?.path == "/tmp/rafu-codex-home/auth.json")
    #expect(CodexOAuthStrategy.configuredAuthURL(environment: [:]) == nil)
    #expect(CodexOAuthStrategy.configuredAuthURL(environment: ["CODEX_HOME": "  "]) == nil)
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

@Test("Codex descriptor strategy count and OAuth-first order are independent of context")
func codexOAuthStrategyCountAndOrderAreStable() {
    let empty = codexOAuthContext(credential: nil)
    let connected = codexOAuthContext(credential: "connected-token")

    #expect(
        CodexProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "codex.oauth", "codex.local-rollout",
        ])
    #expect(
        CodexProvider.descriptor.makeStrategies(connected).map(\.id) == [
            "codex.oauth", "codex.local-rollout",
        ])
}

@Test("Codex OAuth requires the connection gate before reading auth.json")
func codexOAuthMissingGateFallsBackWithoutReadingAuth() async {
    let reads = CodexReadCounter()
    let oauth = CodexOAuthStrategy(authContents: { _ in
        reads.increment()
        return "must-not-be-read"
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [oauth, CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(credential: nil))

    #expect(result?.windows.first?.percent == 44)
    #expect(reads.count == 0)
    #expect(await attempts.count == 1)
}

@Test("Codex OAuth stale auth.json uses local fallback without refreshing")
func codexOAuthStaleCredentialsFallBack() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let oauth = CodexOAuthStrategy(authContents: { _ in
        codexAuth(
            token: "stale-token",
            lastRefresh: now.addingTimeInterval(-9 * 24 * 60 * 60))
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [oauth, CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(now: now))

    #expect(result?.windows.first?.percent == 44)
    #expect(await attempts.count == 1)
}

@Test("Codex OAuth auth.json without last_refresh uses local fallback and never refreshes")
func codexOAuthMissingLastRefreshFallsBack() async {
    let oauth = CodexOAuthStrategy(authContents: { _ in
        codexAuth(token: "unrefreshable-token", lastRefresh: nil)
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [oauth, CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext())

    #expect(result?.windows.first?.percent == 44)
    #expect(await attempts.count == 1)
}

@Test("Codex OAuth sends the file token, account id, honest UA, and exact wham headers")
func codexOAuthRequestUsesFileTokenAndExactHeaders() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = CodexRequestRecorder()
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(codexUsageFixture.utf8), response)
    })
    let strategy = CodexOAuthStrategy(authContents: { _ in
        codexAuth(token: "file-token", lastRefresh: now.addingTimeInterval(-60))
    })

    let snapshot = try await strategy.fetch(
        codexOAuthContext(now: now, http: http, credential: "stored-token"))
    let request = try #require(await recorder.request)

    #expect(snapshot.windows.first?.percent == 22.5)
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.timeoutInterval == 15)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer file-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(
        request.value(forHTTPHeaderField: "User-Agent")
            == "Rafu/\(RafuBuildInformation.version)")
}

@Test("Codex OAuth uses the injected credential only when auth.json is absent")
func codexOAuthUsesInjectedCredentialWhenAuthIsAbsent() async throws {
    let recorder = CodexRequestRecorder()
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(codexUsageFixture.utf8), response)
    })
    let strategy = CodexOAuthStrategy(authContents: { _ in nil })

    _ = try await strategy.fetch(codexOAuthContext(http: http, credential: "stored-token"))
    let request = try #require(await recorder.request)

    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stored-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

@Test("Codex OAuth falls back to local usage only for 401 or 403")
func codexOAuthAuthenticationRejectionFallsBack() async throws {
    for status in [401, 403] {
        let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
        let http = UsageHTTPClient(transport: { _ in
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        })
        let attempts = CodexAttemptCounter()
        let result = await resolveUsageSnapshot(
            strategies: [
                CodexOAuthStrategy(authContents: { _ in nil }),
                CodexFixtureLocalStrategy(attempts: attempts),
            ],
            context: codexOAuthContext(http: http))

        #expect(result?.windows.first?.percent == 44)
        #expect(await attempts.count == 1)
    }
}

@Test("Codex OAuth malformed wham response hides the tile without local fallback")
func codexOAuthMalformedResponseDoesNotFallBack() async throws {
    let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(#"{"rate_limit":{"primary_window":{"used_percent":"bad"}}}"#.utf8), response)
    })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [
            CodexOAuthStrategy(authContents: { _ in nil }),
            CodexFixtureLocalStrategy(attempts: attempts),
        ],
        context: codexOAuthContext(http: http))

    #expect(result == nil)
    #expect(await attempts.count == 0)
}

@Test("Codex OAuth hostile transport diagnostics are redacted and do not fall back")
func codexOAuthTransportErrorIsRedacted() async throws {
    let secret = "codex-super-secret"
    let http = UsageHTTPClient(transport: { _ in
        throw CodexHostileTransportError(
            description: "Authorization: Bearer \(secret); ChatGPT-Account-Id: account-123")
    })
    let strategy = CodexOAuthStrategy(authContents: { _ in nil })
    let attempts = CodexAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [strategy, CodexFixtureLocalStrategy(attempts: attempts)],
        context: codexOAuthContext(http: http, credential: secret))

    #expect(result == nil)
    #expect(await attempts.count == 0)
    do {
        _ = try await strategy.fetch(codexOAuthContext(http: http, credential: secret))
        Issue.record("expected a redacted transport failure")
    } catch {
        let description = String(describing: error)
        #expect(!description.contains(secret))
        #expect(!description.lowercased().contains("bearer"))
        #expect(error as? UsageHTTPError == .transportFailure)
    }
}

@Test("Codex OAuth 429 and other server failures hide the tile without local fallback")
func codexOAuthNonAuthenticationHTTPFailuresDoNotFallBack() async throws {
    for status in [429, 500] {
        let url = try #require(URL(string: "https://chatgpt.com/backend-api/wham/usage"))
        let http = UsageHTTPClient(transport: { _ in
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        })
        let attempts = CodexAttemptCounter()
        let result = await resolveUsageSnapshot(
            strategies: [
                CodexOAuthStrategy(authContents: { _ in nil }),
                CodexFixtureLocalStrategy(attempts: attempts),
            ],
            context: codexOAuthContext(http: http))

        #expect(result == nil)
        #expect(await attempts.count == 0)
    }
}
