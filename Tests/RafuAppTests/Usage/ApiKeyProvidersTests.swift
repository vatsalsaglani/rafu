import Foundation
import Testing

@testable import RafuApp

/// W4 API-key providers. Every network test injects `UsageHTTPClient.Transport`;
/// no test reads Keychain, the process environment, or the live network.

private func apiKeyContext(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    http: UsageHTTPClient = .noop,
    credentials: [UsageProviderID: String] = [:]
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { _ in nil },
        http: http,
        credential: { credentials[$0] },
        cookieHeader: { _ in nil })
}

private func apiResponse(
    request: URLRequest,
    status: Int = 200,
    headers: [String: String] = [:],
    body: String
) throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers))
    return (Data(body.utf8), response)
}

private actor APITransportCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}

// MARK: - Descriptor and availability contract

@Test("W4 descriptors are API-key, default off, and have context-independent strategy counts")
func apiKeyDescriptorContracts() {
    let empty = apiKeyContext()
    let populated = apiKeyContext(credentials: [
        .cline: "cline-key",
        .openRouter: "openrouter-key",
        .qwen: "qwen-key",
    ])
    let descriptors = [
        ClineProvider.descriptor,
        OpenRouterProvider.descriptor,
        QwenProvider.descriptor,
    ]

    for descriptor in descriptors {
        #expect(descriptor.defaultEnabled == false)
        #expect(descriptor.authPattern == .apiKey)
        // The strategy COUNT must be context-independent (the Settings
        // visibility probe calls makeStrategies with an empty context). The
        // exact number varies per provider and grows as phases add strategies
        // (W8 appends a cookie strategy to Qwen), so assert independence +
        // non-empty rather than a frozen count.
        let emptyCount = descriptor.makeStrategies(empty).count
        #expect(emptyCount > 0)
        #expect(descriptor.makeStrategies(populated).count == emptyCount)
    }
    #expect(OpenRouterProvider.descriptor.disclosure.contains("Roo Code"))
    #expect(OpenRouterProvider.descriptor.disclosure.contains("BYO-key"))
    #expect(QwenProvider.descriptor.disclosure.contains("modelstudio.console.alibabacloud.com"))
    #expect(QwenProvider.descriptor.disclosure.contains("bailian.console.aliyun.com"))
}

@Test("No key makes every W4 strategy unavailable and resolves no snapshot")
func apiKeyStrategiesNeedCredentials() async {
    let strategies: [any UsageFetchStrategy] = [
        ClineAPIKeyStrategy(environment: [:]),
        OpenRouterAPIKeyStrategy(environment: [:]),
        QwenAPIKeyStrategy(region: .international, environment: [:]),
    ]
    let context = apiKeyContext()

    for strategy in strategies {
        #expect(await strategy.isAvailable(context) == false)
        #expect(await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    }
}

@Test("Environment aliases are usable availability and credential sources")
func apiKeyEnvironmentAliases() async {
    let context = apiKeyContext()
    #expect(
        await ClineAPIKeyStrategy(environment: ["CLINEPASS_API_KEY": "cline-env"])
            .isAvailable(context))
    #expect(
        await OpenRouterAPIKeyStrategy(environment: ["OPENROUTER_API_KEY": "router-env"])
            .isAvailable(context))
    #expect(
        await QwenAPIKeyStrategy(
            region: .international,
            environment: ["ALIBABA_QWEN_API_KEY": "qwen-env"]
        ).isAvailable(context))
}

// MARK: - Cline / ClinePass

@Test("Cline fixture maps known limits in fixed order and ignores unknown limit types")
func clineFixtureMapsUsageWindows() async throws {
    let fixture = #"""
        {
          "success": true,
          "data": {
            "limits": [
              {"type":"weekly","percentUsed":25,"resetsAt":"2026-07-20T00:00:00Z"},
              {"type":"experimental_pool","percentUsed":77,"resetsAt":null},
              {"type":"five_hour","percentUsed":12.5,"resetsAt":"2026-07-16T15:00:00.000Z"},
              {"type":"monthly","percentUsed":140,"resetsAt":null}
            ]
          }
        }
        """#
    let client = UsageHTTPClient(transport: { request in
        #expect(
            request.url?.absoluteString == "https://api.cline.bot/api/v1/users/me/plan/usage-limits"
        )
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cline-test-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        return try apiResponse(request: request, body: fixture)
    })
    let context = apiKeyContext(http: client, credentials: [.cline: " cline-test-key "])

    let snapshot = try await ClineAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.providerID == .cline)
    #expect(snapshot.windows.map(\.label) == ["5h", "7d", "monthly"])
    #expect(snapshot.windows.map(\.percent) == [12.5, 25, 100])
    #expect(
        snapshot.windows[0].resetsAt
            == UsageDateParsing.parseISO8601Fractional(
                "2026-07-16T15:00:00.000Z"))
    #expect(
        snapshot.windows[1].resetsAt
            == UsageDateParsing.parseISO8601Fractional(
                "2026-07-20T00:00:00Z"))
    #expect(snapshot.costLine == nil)
}

@Test("Cline 401 and 403 map to typed unauthorized errors", arguments: [401, 403])
func clineUnauthorizedIsTyped(status: Int) async throws {
    let client = UsageHTTPClient(transport: { request in
        try apiResponse(request: request, status: status, body: #"{"error":"rejected"}"#)
    })
    let context = apiKeyContext(http: client, credentials: [.cline: "secret-cline-key"])

    do {
        _ = try await ClineAPIKeyStrategy(environment: [:]).fetch(context)
        Issue.record("Expected ClineUsageError.unauthorized")
    } catch let error as ClineUsageError {
        #expect(error == .unauthorized)
        #expect(!String(describing: error).contains("secret-cline-key"))
        #expect(ClineAPIKeyStrategy(environment: [:]).shouldFallback(on: error) == false)
    }
}

// MARK: - OpenRouter

@Test("OpenRouter credits and key limit map to cost plus percentage")
func openRouterFixtureMapsCreditsAndLimit() async throws {
    let client = UsageHTTPClient(transport: { request in
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer router-test-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Rafu")
        switch request.url?.path {
        case "/api/v1/credits":
            return try apiResponse(
                request: request,
                body: #"{"data":{"total_credits":100,"total_usage":40}}"#)
        case "/api/v1/key":
            return try apiResponse(
                request: request,
                body: #"{"data":{"limit":20,"usage":5,"usage_daily":1.2}}"#)
        default:
            return try apiResponse(request: request, status: 404, body: "{}")
        }
    })
    let context = apiKeyContext(
        http: client,
        credentials: [.openRouter: "router-test-key"])

    let snapshot = try await OpenRouterAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.providerID == .openRouter)
    #expect(snapshot.costLine == "$40.00 used · $60.00 left")
    #expect(
        snapshot.windows == [
            UsageWindow(label: "limit", percent: 25, tokens: nil, resetsAt: nil)
        ])
}

@Test("OpenRouter retains credits when optional key enrichment is unavailable")
func openRouterKeyEnrichmentCanDegrade() async throws {
    let client = UsageHTTPClient(transport: { request in
        if request.url?.path == "/api/v1/credits" {
            return try apiResponse(
                request: request,
                body: #"{"data":{"total_credits":50,"total_usage":12.5}}"#)
        }
        return try apiResponse(request: request, status: 500, body: "{}")
    })
    let context = apiKeyContext(http: client, credentials: [.openRouter: "router-key"])

    let snapshot = try await OpenRouterAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.costLine == "$12.50 used · $37.50 left")
    #expect(snapshot.renderable)
}

@Test("OpenRouter 401 and 403 map to typed unauthorized errors", arguments: [401, 403])
func openRouterUnauthorizedIsTyped(status: Int) async throws {
    let client = UsageHTTPClient(transport: { request in
        try apiResponse(request: request, status: status, body: #"{"error":"rejected"}"#)
    })
    let context = apiKeyContext(
        http: client,
        credentials: [.openRouter: "secret-router-key"])

    do {
        _ = try await OpenRouterAPIKeyStrategy(environment: [:]).fetch(context)
        Issue.record("Expected OpenRouterUsageError.unauthorized")
    } catch let error as OpenRouterUsageError {
        #expect(error == .unauthorized)
        #expect(!String(describing: error).contains("secret-router-key"))
        #expect(OpenRouterAPIKeyStrategy(environment: [:]).shouldFallback(on: error) == false)
    }
}

// MARK: - Qwen / Alibaba Coding Plan key path

@Test("Qwen Coding Plan fixture maps intl request shape and three quota windows")
func qwenFixtureMapsCodingPlanWindows() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fixture = #"""
        {
          "data": {
            "codingPlanInstanceInfos": [
              {
                "planName": "Alibaba Coding Plan Pro",
                "status": "VALID"
              }
            ],
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota": 52,
              "per5HourTotalQuota": 1000,
              "per5HourQuotaNextRefreshTime": 1700000300000,
              "perWeekUsedQuota": 800,
              "perWeekTotalQuota": 5000,
              "perWeekQuotaNextRefreshTime": 1700100000000,
              "perBillMonthUsedQuota": 1200,
              "perBillMonthTotalQuota": 20000,
              "perBillMonthQuotaNextRefreshTime": 1701000000000
            }
          },
          "status_code": 0
        }
        """#
    let client = UsageHTTPClient(transport: { request in
        #expect(request.url?.host == "modelstudio.console.alibabacloud.com")
        #expect(request.url?.path == "/data/api.json")
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? [])
                .map { ($0.name, $0.value) })
        #expect(
            query["action"]
                == "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2")
        #expect(query["product"] == "broadscope-bailian")
        #expect(query["api"] == "queryCodingPlanInstanceInfoV2")
        #expect(query["currentRegionId"] == "ap-southeast-1")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer qwen-test-key")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "qwen-test-key")
        #expect(request.value(forHTTPHeaderField: "X-DashScope-API-Key") == "qwen-test-key")
        #expect(
            request.value(forHTTPHeaderField: "Origin")
                == "https://modelstudio.console.alibabacloud.com")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: [String: String]])
        #expect(
            object["queryCodingPlanInstanceInfoRequest"]?["commodityCode"]
                == "sfm_codingplan_public_intl")
        return try apiResponse(request: request, body: fixture)
    })
    let context = apiKeyContext(
        now: now,
        http: client,
        credentials: [.qwen: "qwen-test-key"])

    let snapshot = try await QwenAPIKeyStrategy(
        region: .international,
        environment: [:]
    ).fetch(context)

    #expect(snapshot.providerID == .qwen)
    #expect(snapshot.windows.map(\.label) == ["5h", "7d", "monthly"])
    #expect(abs((snapshot.windows[0].percent ?? 0) - 5.2) < 0.000_001)
    #expect(snapshot.windows[1].percent == 16)
    #expect(snapshot.windows[2].percent == 6)
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_000_300))
    #expect(snapshot.identity == "Alibaba Coding Plan Pro")
}

@Test("Qwen region helper and preference preserve exact intl and China endpoint metadata")
func qwenRegionPreferenceRoundTrips() throws {
    let suite = "ApiKeyProvidersTests.QwenRegion.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }

    #expect(QwenRegionPreference.load(suiteName: suite) == .international)
    QwenRegionPreference.save(.chinaMainland, suiteName: suite)
    #expect(QwenRegionPreference.load(suiteName: suite) == .chinaMainland)
    #expect(QwenAPIRegion.international.quotaURL.host == "modelstudio.console.alibabacloud.com")
    #expect(QwenAPIRegion.chinaMainland.quotaURL.host == "bailian.console.aliyun.com")
    #expect(QwenAPIRegion.chinaMainland.currentRegionID == "cn-beijing")
    #expect(QwenAPIRegion.chinaMainland.commodityCode == "sfm_codingplan_public_cn")
}

@Test("Qwen 401 and 403 map to typed unauthorized errors", arguments: [401, 403])
func qwenUnauthorizedIsTyped(status: Int) async throws {
    let client = UsageHTTPClient(transport: { request in
        try apiResponse(request: request, status: status, body: #"{"error":"rejected"}"#)
    })
    let context = apiKeyContext(http: client, credentials: [.qwen: "secret-qwen-key"])
    let strategy = QwenAPIKeyStrategy(region: .international, environment: [:])

    do {
        _ = try await strategy.fetch(context)
        Issue.record("Expected QwenUsageError.unauthorized")
    } catch let error as QwenUsageError {
        #expect(error == .unauthorized)
        #expect(!String(describing: error).contains("secret-qwen-key"))
        #expect(strategy.shouldFallback(on: error) == false)
    }
}

@Test("Qwen API-key-unavailable response is the sole W8 cookie-fallback error")
func qwenCookieFallbackIsNarrow() throws {
    let strategy = QwenAPIKeyStrategy(region: .international, environment: [:])
    do {
        _ = try QwenAPIKeyStrategy.parse(
            Data(#"{"code":"ConsoleNeedLogin","message":"Console session required"}"#.utf8),
            now: Date())
        Issue.record("Expected QwenUsageError.apiKeyUnavailableInRegion")
    } catch let error as QwenUsageError {
        #expect(error == .apiKeyUnavailableInRegion)
        #expect(strategy.shouldFallback(on: error))
        #expect(strategy.shouldFallback(on: QwenUsageError.unauthorized) == false)
        #expect(strategy.shouldFallback(on: UsageHTTPError.rateLimited(retryAfter: 60)) == false)
    }
}

// MARK: - Shared gate and redaction integration

@Test("Unauthorized W4 fetches hide the tile and make no fallback request")
func apiKeyUnauthorizedStopsPipeline() async {
    let counter = APITransportCounter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        return try apiResponse(request: request, status: 401, body: "{}")
    })
    let strategies: [(any UsageFetchStrategy, UsageProviderID)] = [
        (ClineAPIKeyStrategy(environment: [:]), .cline),
        (OpenRouterAPIKeyStrategy(environment: [:]), .openRouter),
        (QwenAPIKeyStrategy(region: .international, environment: [:]), .qwen),
    ]

    for (strategy, provider) in strategies {
        let context = apiKeyContext(http: client, credentials: [provider: "fixture-key"])
        #expect(await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    }
    #expect(await counter.count == strategies.count)
}

@Test("W4 strategy consults the shared Retry-After gate before invoking transport again")
func apiKeyProviderHonorsRetryAfterGate() async throws {
    let counter = APITransportCounter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        return try apiResponse(
            request: request,
            status: 429,
            headers: ["Retry-After": "300"],
            body: "{}")
    })
    let context = apiKeyContext(http: client, credentials: [.cline: "cline-key"])
    let strategy = ClineAPIKeyStrategy(environment: [:])

    do {
        _ = try await strategy.fetch(context)
        Issue.record("Expected rate limit")
    } catch UsageHTTPError.rateLimited(let retryAfter) {
        #expect(retryAfter == 300)
    }
    #expect(await counter.count == 1)

    do {
        _ = try await strategy.fetch(context)
        Issue.record("Expected active rate-limit gate")
    } catch UsageHTTPError.rateLimited(let retryAfter) {
        #expect((retryAfter ?? 0) > 0)
    }
    #expect(await counter.count == 1)
}

private struct SecretBearingTransportError: Error, Sendable {
    let secret: String
}

@Test("Injected transport details containing a key are structurally redacted")
func apiKeyTransportErrorsAreRedacted() async throws {
    let secret = "sk-secret-that-must-not-escape"
    let client = UsageHTTPClient(transport: { _ in
        throw SecretBearingTransportError(secret: secret)
    })
    let context = apiKeyContext(http: client, credentials: [.cline: secret])

    do {
        _ = try await ClineAPIKeyStrategy(environment: [:]).fetch(context)
        Issue.record("Expected transport failure")
    } catch {
        #expect(error as? UsageHTTPError == .transportFailure)
        #expect(!String(describing: error).contains(secret))
        #expect(!String(describing: error).lowercased().contains("bearer"))
    }
}
