import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

private func claudeOAuthContext(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    http: UsageHTTPClient = .noop,
    credential: String? = "connected-token"
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { _ in nil },
        http: http,
        credential: { id in id == .claude ? credential : nil },
        cookieHeader: { _ in nil })
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

private final class ClaudeReadCounter: Sendable {
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

private func claudeCredentials(token: String, expiresAt: Date) -> String {
    let milliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
    return """
        {
          "claudeAiOauth": {
            "accessToken": "\(token)",
            "refreshToken": "unused-refresh-token",
            "expiresAt": \(milliseconds),
            "scopes": ["user:profile"]
          }
        }
        """
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

@Test("Claude OAuth credentials parse the real claudeAiOauth millisecond expiry shape")
func claudeOAuthCredentialsParseMilliseconds() throws {
    let expiry = Date(timeIntervalSince1970: 1_800_000_123)
    let credentials = try #require(
        ClaudeOAuthCredentials.parse(
            contents: claudeCredentials(token: "file-token", expiresAt: expiry)))

    #expect(credentials.accessToken == "file-token")
    #expect(credentials.expiresAt == expiry)
}

@Test("Claude OAuth maps 5h, 7d, and at most one valid unique model-scoped weekly window")
func claudeOAuthMapsUsageFixture() throws {
    let snapshot = try ClaudeOAuthStrategy.parseUsage(Data(claudeUsageFixture.utf8))

    #expect(snapshot.providerID == .claude)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.windows.map(\.label) == ["5h", "7d", "Fable 7d"])
    #expect(snapshot.windows.map(\.percent) == [12.5, 30, 5])
    #expect(snapshot.windows.allSatisfy { $0.tokens == nil })
    #expect(snapshot.windows.allSatisfy { $0.resetsAt != nil })
}

@Test("Claude descriptor strategy count and OAuth-first order are independent of context")
func claudeOAuthStrategyCountAndOrderAreStable() {
    let empty = claudeOAuthContext(credential: nil)
    let connected = claudeOAuthContext(credential: "connected-token")

    #expect(
        ClaudeProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "claude.oauth", "claude.local-transcripts",
        ])
    #expect(
        ClaudeProvider.descriptor.makeStrategies(connected).map(\.id) == [
            "claude.oauth", "claude.local-transcripts",
        ])
}

@Test("Claude OAuth requires the connection gate before reading the CLI credential file")
func claudeOAuthMissingGateFallsBackWithoutReadingCredentials() async {
    let reads = ClaudeReadCounter()
    let oauth = ClaudeOAuthStrategy(credentialsContents: { _ in
        reads.increment()
        return "must-not-be-read"
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [oauth, ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(credential: nil))

    #expect(result?.windows.first?.tokens == 123)
    #expect(reads.count == 0)
    #expect(await attempts.count == 1)
}

@Test("Claude OAuth expired CLI credentials use the injected local fallback without a request")
func claudeOAuthExpiredCredentialsFallBack() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let oauth = ClaudeOAuthStrategy(credentialsContents: { _ in
        claudeCredentials(token: "expired-token", expiresAt: now.addingTimeInterval(-1))
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [oauth, ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(now: now))

    #expect(result?.windows.first?.tokens == 123)
    #expect(await attempts.count == 1)
}

@Test("Claude OAuth reads the CLI credential first and sends exact endpoint and headers")
func claudeOAuthRequestUsesFileTokenAndExactHeaders() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = ClaudeRequestRecorder()
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(claudeUsageFixture.utf8), response)
    })
    let strategy = ClaudeOAuthStrategy(credentialsContents: { _ in
        claudeCredentials(token: "file-token", expiresAt: now.addingTimeInterval(3_600))
    })

    let snapshot = try await strategy.fetch(
        claudeOAuthContext(now: now, http: http, credential: "stored-token"))
    let request = try #require(await recorder.request)

    #expect(snapshot.windows.first?.percent == 12.5)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.timeoutInterval == 15)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer file-token")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
        request.value(forHTTPHeaderField: "User-Agent")
            == "Rafu/\(RafuBuildInformation.version)")
}

@Test("Claude OAuth uses the injected credential value only when the CLI file is absent")
func claudeOAuthUsesInjectedCredentialWhenFileIsAbsent() async throws {
    let recorder = ClaudeRequestRecorder()
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(claudeUsageFixture.utf8), response)
    })
    let strategy = ClaudeOAuthStrategy(credentialsContents: { _ in nil })

    _ = try await strategy.fetch(claudeOAuthContext(http: http, credential: "stored-token"))

    #expect(
        await recorder.request?.value(forHTTPHeaderField: "Authorization")
            == "Bearer stored-token")
}

@Test("Claude OAuth falls back to local usage only for 401 or 403")
func claudeOAuthAuthenticationRejectionFallsBack() async throws {
    for status in [401, 403] {
        let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let http = UsageHTTPClient(transport: { _ in
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        })
        let attempts = ClaudeAttemptCounter()
        let result = await resolveUsageSnapshot(
            strategies: [
                ClaudeOAuthStrategy(credentialsContents: { _ in nil }),
                ClaudeFixtureLocalStrategy(attempts: attempts),
            ],
            context: claudeOAuthContext(http: http))

        #expect(result?.windows.first?.tokens == 123)
        #expect(await attempts.count == 1)
    }
}

@Test("Claude OAuth malformed response hides the tile and does not use local fallback")
func claudeOAuthMalformedResponseDoesNotFallBack() async throws {
    let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let http = UsageHTTPClient(transport: { _ in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(#"{"five_hour":{"utilization":"not-a-number"}}"#.utf8), response)
    })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [
            ClaudeOAuthStrategy(credentialsContents: { _ in nil }),
            ClaudeFixtureLocalStrategy(attempts: attempts),
        ],
        context: claudeOAuthContext(http: http))

    #expect(result == nil)
    #expect(await attempts.count == 0)
}

@Test("Claude OAuth hostile transport diagnostics are redacted and do not fall back")
func claudeOAuthTransportErrorIsRedacted() async throws {
    let secret = "claude-super-secret"
    let http = UsageHTTPClient(transport: { _ in
        throw ClaudeHostileTransportError(
            description: "Authorization: Bearer \(secret); anthropic-beta: oauth-2025-04-20")
    })
    let strategy = ClaudeOAuthStrategy(credentialsContents: { _ in nil })
    let attempts = ClaudeAttemptCounter()
    let result = await resolveUsageSnapshot(
        strategies: [strategy, ClaudeFixtureLocalStrategy(attempts: attempts)],
        context: claudeOAuthContext(http: http, credential: secret))

    #expect(result == nil)
    #expect(await attempts.count == 0)
    do {
        _ = try await strategy.fetch(claudeOAuthContext(http: http, credential: secret))
        Issue.record("expected a redacted transport failure")
    } catch {
        let description = String(describing: error)
        #expect(!description.contains(secret))
        #expect(!description.lowercased().contains("bearer"))
        #expect(error as? UsageHTTPError == .transportFailure)
    }
}

@Test("Claude OAuth 429 and other server failures hide the tile without local fallback")
func claudeOAuthNonAuthenticationHTTPFailuresDoNotFallBack() async throws {
    for status in [429, 500] {
        let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let http = UsageHTTPClient(transport: { _ in
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        })
        let attempts = ClaudeAttemptCounter()
        let result = await resolveUsageSnapshot(
            strategies: [
                ClaudeOAuthStrategy(credentialsContents: { _ in nil }),
                ClaudeFixtureLocalStrategy(attempts: attempts),
            ],
            context: claudeOAuthContext(http: http))

        #expect(result == nil)
        #expect(await attempts.count == 0)
    }
}
