import Foundation
import Testing

@testable import RafuApp

/// W8 Alibaba providers. Every request uses an injected transport; these
/// tests never read a browser, the real cookie cache/Keychain, or the network.

private func alibabaContext(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    http: UsageHTTPClient = .noop,
    credentials: [UsageProviderID: String] = [:],
    cookies: [UsageProviderID: String] = [:]
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { _ in nil },
        http: http,
        credential: { credentials[$0] },
        cookieHeader: { cookies[$0] })
}

private func alibabaResponse(
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

private actor AlibabaTransportCounter {
    private(set) var count = 0

    func increment() { count += 1 }
}

private struct AlibabaSecretBearingError: Error, Sendable {
    let secret: String
}

private let qwenCookie =
    "login_aliyunid_ticket=ticket-secret; login_aliyunid_pk=account-secret; "
    + "login_aliyunid_csrf=csrf-secret; sec_token=security-secret"

// MARK: - Descriptor, region, and availability contracts

@Test("Alibaba descriptors stay default-off with context-independent ordered strategies")
func alibabaDescriptorContracts() {
    let empty = alibabaContext()
    let populated = alibabaContext(
        credentials: [.qwen: "qwen-key"],
        cookies: [.qwen: qwenCookie, .qoder: "session=qoder-cookie"])

    #expect(QoderProvider.descriptor.defaultEnabled == false)
    #expect(QoderProvider.descriptor.authPattern == .cookieImport)
    #expect(QoderProvider.descriptor.makeStrategies(empty).map(\.id) == ["qoder.cookie"])
    #expect(QoderProvider.descriptor.makeStrategies(populated).map(\.id) == ["qoder.cookie"])
    #expect(QoderProvider.descriptor.disclosure.contains("qoder.com"))
    #expect(QoderProvider.descriptor.disclosure.contains("qoder.com.cn"))

    #expect(QwenProvider.descriptor.defaultEnabled == false)
    #expect(QwenProvider.descriptor.authPattern == .apiKey)
    #expect(
        QwenProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "qwen.api-key", "qwen.cookie",
        ])
    #expect(
        QwenProvider.descriptor.makeStrategies(populated).map(\.id) == [
            "qwen.api-key", "qwen.cookie",
        ])
    #expect(QwenProvider.descriptor.disclosure.contains("modelstudio.console.alibabacloud.com"))
    #expect(QwenProvider.descriptor.disclosure.contains("bailian.console.aliyun.com"))
}

@Test("Alibaba region preferences and importer facts preserve both source regions")
func alibabaRegionPreferences() throws {
    let qoderSuite = "AlibabaProvidersTests.QoderRegion.\(UUID().uuidString)"
    let qwenSuite = "AlibabaProvidersTests.QwenRegion.\(UUID().uuidString)"
    defer {
        UserDefaults().removePersistentDomain(forName: qoderSuite)
        UserDefaults().removePersistentDomain(forName: qwenSuite)
    }

    #expect(QoderRegionPreference.load(suiteName: qoderSuite) == .international)
    QoderRegionPreference.save(.chinaMainland, suiteName: qoderSuite)
    #expect(QoderRegionPreference.load(suiteName: qoderSuite) == .chinaMainland)
    #expect(
        QoderRegion.international.usageURL.absoluteString
            == "https://qoder.com/api/v2/me/usages/big_model_credits")
    #expect(
        QoderRegion.chinaMainland.usageURL.absoluteString
            == "https://qoder.com.cn/api/v2/me/usages/big_model_credits")
    #expect(QoderRegion.international.cookieImportDomains == ["qoder.com", "www.qoder.com"])
    #expect(
        QoderRegion.chinaMainland.cookieImportDomains == [
            "qoder.com.cn", "www.qoder.com.cn",
        ])

    #expect(QwenRegionPreference.load(suiteName: qwenSuite) == .international)
    QwenRegionPreference.save(.chinaMainland, suiteName: qwenSuite)
    #expect(QwenRegionPreference.load(suiteName: qwenSuite) == .chinaMainland)
    #expect(
        QwenAPIRegion.international.tokenPlanQuotaURL.host == "modelstudio.console.alibabacloud.com"
    )
    #expect(QwenAPIRegion.chinaMainland.tokenPlanQuotaURL.host == "bailian.console.aliyun.com")
    #expect(QwenAPIRegion.international.tokenPlanProductCode == "sfm_tokenplanteams_dp_intl")
    #expect(QwenAPIRegion.chinaMainland.tokenPlanProductCode == "sfm_tokenplanteams_dp_cn")
    #expect(QwenCookieStrategy.cookieImportDomains.count == 13)
    #expect(QwenCookieStrategy.cookieImportDomains.contains("passport.alibabacloud.com"))
    #expect(QwenCookieStrategy.cookieImportDomains.contains("bailian-beijing-cs.aliyuncs.com"))
}

@Test("Missing or structurally incomplete cached cookies are unavailable without transport")
func alibabaCookieAvailabilityIsGated() async {
    let counter = AlibabaTransportCounter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        return try alibabaResponse(request: request, body: "{}")
    })
    let empty = alibabaContext(http: client)
    let incomplete = alibabaContext(
        http: client,
        cookies: [.qwen: "login_aliyunid_ticket=only-ticket"])
    let qoder = QoderCookieStrategy(region: .international)
    let qwen = QwenCookieStrategy(region: .international)

    #expect(await qoder.isAvailable(empty) == false)
    #expect(await qwen.isAvailable(empty) == false)
    #expect(await qwen.isAvailable(incomplete) == false)
    #expect(await resolveUsageSnapshot(strategies: [qoder], context: empty) == nil)
    #expect(await resolveUsageSnapshot(strategies: [qwen], context: incomplete) == nil)
    #expect(await counter.count == 0)
}

// MARK: - Qoder

@Test("Qoder international fixture merges shared credits and maps the browser request")
func qoderInternationalFixture() async throws {
    let fixture = #"""
        {
          "totalQuota": {
            "quotaSummary": {
              "usedValue": 100,
              "limitValue": 1000,
              "remainingValue": 900,
              "usagePercentage": 10,
              "unit": "credits"
            }
          },
          "sharedQuota": {
            "quotaSummary": {
              "usedValue": 50,
              "limitValue": 500,
              "remainingValue": 450,
              "usagePercentage": 10,
              "unit": "credits"
            }
          },
          "nextResetAt": "2026-07-31T00:00:00.000Z"
        }
        """#
    let client = UsageHTTPClient(transport: { request in
        #expect(
            request.url?.absoluteString == "https://qoder.com/api/v2/me/usages/big_model_credits")
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=qoder-secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://qoder.com")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://qoder.com/account/usage")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(request.value(forHTTPHeaderField: "Bx-V") == "2.5.35")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla/5.0") == true)
        #expect(request.timeoutInterval == 15)
        return try alibabaResponse(request: request, body: fixture)
    })
    let context = alibabaContext(
        http: client,
        cookies: [.qoder: "session=qoder-secret"])

    let snapshot = try await QoderCookieStrategy(region: .international).fetch(context)

    #expect(snapshot.providerID == .qoder)
    #expect(
        snapshot.windows == [
            UsageWindow(
                label: "credits",
                percent: 10,
                tokens: nil,
                resetsAt: UsageDateParsing.parseISO8601Fractional(
                    "2026-07-31T00:00:00.000Z"))
        ])
    #expect(snapshot.costLine == "150 / 1,500 credits")
    #expect(snapshot.identity == nil)
}

@Test("Qoder China fixture accepts snake-case fields and derives remaining credits")
func qoderChinaFixture() async throws {
    let fixture = #"""
        {
          "total_quota": {
            "quota_summary": {
              "used_value": 12.5,
              "limit_value": 100,
              "usage_percentage": 12.5
            }
          },
          "next_reset_at": 1701000000000
        }
        """#
    let client = UsageHTTPClient(transport: { request in
        #expect(
            request.url?.absoluteString
                == "https://qoder.com.cn/api/v2/me/usages/big_model_credits")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://qoder.com.cn")
        #expect(
            request.value(forHTTPHeaderField: "Referer") == "https://qoder.com.cn/account/usage")
        return try alibabaResponse(request: request, body: fixture)
    })
    let context = alibabaContext(http: client, cookies: [.qoder: "sid=china-secret"])

    let snapshot = try await QoderCookieStrategy(region: .chinaMainland).fetch(context)

    #expect(snapshot.windows.first?.percent == 12.5)
    #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_701_000_000))
    #expect(snapshot.costLine == "12.5 / 100 credits")
}

// MARK: - Qwen Token Plan cookie path

@Test(
    "Qwen Token Plan fixtures map both regional hosts and request metadata",
    arguments: [QwenAPIRegion.international, .chinaMainland])
func qwenCookieRegionFixtures(region: QwenAPIRegion) async throws {
    let inner =
        #"{"success":true,"data":{"totalCount":1,"totalValue":1000,"totalSurplusValue":875,"nearestExpireDate":1701000000000},"code":"200"}"#
    let fixture: String
    if region == .international {
        fixture = #"""
            {
              "Success": true,
              "Data": {
                "TotalCount": 1,
                "TotalValue": 1000,
                "TotalSurplusValue": 875,
                "NearestExpireDate": 1701000000000
              },
              "Code": "200"
            }
            """#
    } else {
        let encoded = try #require(String(data: JSONEncoder().encode(inner), encoding: .utf8))
        fixture = "{\"successResponse\":{\"body\":\(encoded)}}"
    }
    let client = UsageHTTPClient(transport: { request in
        #expect(request.url?.host == region.gatewayBaseURL.host)
        #expect(request.url?.path == "/data/api.json")
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["action"] == "GetSubscriptionSummary")
        #expect(query["product"] == "BssOpenAPI-V3")
        #expect(query["_tag"] == "")
        #expect(request.httpMethod == "POST")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == qwenCookie)
        #expect(
            request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
        )
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.value(forHTTPHeaderField: "Origin") == region.gatewayBaseURL.absoluteString)
        #expect(
            request.value(forHTTPHeaderField: "Referer")
                == region.tokenPlanDashboardURL.absoluteString)
        #expect(request.value(forHTTPHeaderField: "x-xsrf-token") == "csrf-secret")
        #expect(request.value(forHTTPHeaderField: "x-csrf-token") == "csrf-secret")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla/5.0") == true)
        #expect(request.timeoutInterval == 15)

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        let form = Dictionary(
            uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?\(body)")?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(form["product"] == "BssOpenAPI-V3")
        #expect(form["action"] == "GetSubscriptionSummary")
        #expect(form["region"] == region.currentRegionID)
        #expect(form["sec_token"] == "security-secret")
        let params = try #require(form["params"]?.data(using: .utf8))
        let paramsObject = try #require(
            JSONSerialization.jsonObject(with: params) as? [String: String])
        #expect(paramsObject["ProductCode"] == region.tokenPlanProductCode)
        return try alibabaResponse(request: request, body: fixture)
    })
    let context = alibabaContext(http: client, cookies: [.qwen: qwenCookie])

    let snapshot = try await QwenCookieStrategy(region: region).fetch(context)

    #expect(snapshot.providerID == .qwen)
    #expect(
        snapshot.windows == [
            UsageWindow(
                label: "monthly",
                percent: 12.5,
                tokens: nil,
                resetsAt: Date(timeIntervalSince1970: 1_701_000_000))
        ])
    #expect(snapshot.costLine == "125 / 1,000 credits used")
    #expect(snapshot.identity == "TOKEN PLAN")
}

@Test("Qwen API key wins when both key and cookie are present")
func qwenKeyBeatsCookie() async throws {
    let counter = AlibabaTransportCounter()
    let keyFixture = #"""
        {
          "data": {
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota": 10,
              "per5HourTotalQuota": 100
            }
          },
          "status_code": 0
        }
        """#
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "action" })?.value
        #expect(action?.contains("queryCodingPlanInstanceInfoV2") == true)
        return try alibabaResponse(request: request, body: keyFixture)
    })
    let context = alibabaContext(
        http: client,
        credentials: [.qwen: "qwen-key"],
        cookies: [.qwen: qwenCookie])

    let snapshot = await resolveUsageSnapshot(
        strategies: [
            QwenAPIKeyStrategy(region: .international, environment: [:]),
            QwenCookieStrategy(region: .international),
        ],
        context: context)

    #expect(snapshot?.windows.first?.label == "5h")
    #expect(await counter.count == 1)
}

@Test("Qwen API-key auth rejection stops before an available cookie strategy")
func qwenKeyUnauthorizedStopsCookieFallback() async {
    let counter = AlibabaTransportCounter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        return try alibabaResponse(request: request, status: 401, body: "{}")
    })
    let context = alibabaContext(
        http: client,
        credentials: [.qwen: "rejected-key"],
        cookies: [.qwen: qwenCookie])

    let snapshot = await resolveUsageSnapshot(
        strategies: [
            QwenAPIKeyStrategy(region: .international, environment: [:]),
            QwenCookieStrategy(region: .international),
        ],
        context: context)

    #expect(snapshot == nil)
    #expect(await counter.count == 1)
}

@Test("Qwen's narrow API-key-unavailable error falls through to the cookie strategy")
func qwenKeyUnavailableFallsBackToCookie() async throws {
    let counter = AlibabaTransportCounter()
    let cookieFixture =
        #"{"Success":true,"Data":{"TotalCount":1,"TotalValue":100,"TotalSurplusValue":75},"Code":"200"}"#
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        let action = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "action" })?.value
        if action?.contains("queryCodingPlanInstanceInfoV2") == true {
            return try alibabaResponse(
                request: request,
                body: #"{"code":"ConsoleNeedLogin","message":"Console session required"}"#)
        }
        #expect(action == "GetSubscriptionSummary")
        return try alibabaResponse(request: request, body: cookieFixture)
    })
    let context = alibabaContext(
        http: client,
        credentials: [.qwen: "qwen-key"],
        cookies: [.qwen: qwenCookie])

    let snapshot = await resolveUsageSnapshot(
        strategies: [
            QwenAPIKeyStrategy(region: .international, environment: [:]),
            QwenCookieStrategy(region: .international),
        ],
        context: context)

    #expect(snapshot?.windows.first?.label == "monthly")
    #expect(snapshot?.windows.first?.percent == 25)
    #expect(await counter.count == 2)
}

// MARK: - Typed failures, retry gate, validation, and redaction

@Test(
    "Alibaba cookie strategies map HTTP 401 and 403 to typed credential errors",
    arguments: [401, 403])
func alibabaCookieHTTPAuthErrors(status: Int) async throws {
    let client = UsageHTTPClient(transport: { request in
        try alibabaResponse(request: request, status: status, body: "{}")
    })

    let qoderContext = alibabaContext(http: client, cookies: [.qoder: "session=qoder-secret"])
    let qoder = QoderCookieStrategy(region: .international)
    do {
        _ = try await qoder.fetch(qoderContext)
        Issue.record("Expected QoderUsageError.invalidCredentials")
    } catch let error as QoderUsageError {
        #expect(error == .invalidCredentials)
        #expect(qoder.shouldFallback(on: error) == false)
        #expect(!String(describing: error).contains("qoder-secret"))
    }

    let qwenContext = alibabaContext(http: client, cookies: [.qwen: qwenCookie])
    let qwen = QwenCookieStrategy(region: .international)
    do {
        _ = try await qwen.fetch(qwenContext)
        Issue.record("Expected QwenUsageError.unauthorized")
    } catch let error as QwenUsageError {
        #expect(error == .unauthorized)
        #expect(qwen.shouldFallback(on: error) == false)
        #expect(!String(describing: error).contains("ticket-secret"))
    }
}

@Test("Qwen login payload is typed unauthorized and hides the tile")
func qwenLoginPayloadIsUnauthorized() async {
    let client = UsageHTTPClient(transport: { request in
        try alibabaResponse(
            request: request,
            body: #"{"Success":false,"Code":"ConsoleNeedLogin","Message":"login required"}"#)
    })
    let context = alibabaContext(http: client, cookies: [.qwen: qwenCookie])
    let strategy = QwenCookieStrategy(region: .international)

    do {
        _ = try await strategy.fetch(context)
        Issue.record("Expected QwenUsageError.unauthorized")
    } catch let error as QwenUsageError {
        #expect(error == .unauthorized)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #expect(await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
}

@Test("Alibaba cookie providers honor the shared Retry-After gate")
func alibabaRetryAfterGate() async throws {
    let qoderCounter = AlibabaTransportCounter()
    let qoderClient = UsageHTTPClient(transport: { request in
        await qoderCounter.increment()
        return try alibabaResponse(
            request: request,
            status: 429,
            headers: ["Retry-After": "300"],
            body: "{}")
    })
    let qoderContext = alibabaContext(
        http: qoderClient,
        cookies: [.qoder: "session=qoder-secret"])
    let qoder = QoderCookieStrategy(region: .international)
    for _ in 0..<2 {
        do {
            _ = try await qoder.fetch(qoderContext)
            Issue.record("Expected rate limit")
        } catch UsageHTTPError.rateLimited(let retryAfter) {
            #expect((retryAfter ?? 0) > 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    #expect(await qoderCounter.count == 1)

    let qwenCounter = AlibabaTransportCounter()
    let qwenClient = UsageHTTPClient(transport: { request in
        await qwenCounter.increment()
        return try alibabaResponse(
            request: request,
            status: 429,
            headers: ["Retry-After": "120"],
            body: "{}")
    })
    let qwenContext = alibabaContext(http: qwenClient, cookies: [.qwen: qwenCookie])
    let qwen = QwenCookieStrategy(region: .international)
    for _ in 0..<2 {
        do {
            _ = try await qwen.fetch(qwenContext)
            Issue.record("Expected rate limit")
        } catch UsageHTTPError.rateLimited(let retryAfter) {
            #expect((retryAfter ?? 0) > 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    #expect(await qwenCounter.count == 1)
}

@Test("Alibaba parsers reject negative, incomplete, and non-renderable metrics")
func alibabaInvalidMetrics() {
    #expect(throws: QoderUsageError.invalidResponse) {
        try QoderCookieStrategy.parse(
            Data(
                #"{"totalQuota":{"quotaSummary":{"usedValue":-1,"limitValue":100}}}"#.utf8),
            now: Date())
    }
    #expect(throws: QoderUsageError.invalidResponse) {
        try QoderCookieStrategy.parse(Data(#"{"totalQuota":{}}"#.utf8), now: Date())
    }
    #expect(throws: QwenUsageError.invalidResponse) {
        try QwenCookieStrategy.parse(
            Data(#"{"Success":true,"Data":{"TotalValue":-1,"TotalSurplusValue":0}}"#.utf8),
            now: Date())
    }
    #expect(throws: QwenUsageError.invalidResponse) {
        try QwenCookieStrategy.parse(
            Data(#"{"Success":true,"Data":{"TotalCount":1}}"#.utf8), now: Date())
    }
}

@Test("Cookie and hostile transport secrets are structurally redacted")
func alibabaErrorsAreRedacted() async throws {
    let secret = "alibaba-cookie-secret-sentinel"
    let client = UsageHTTPClient(transport: { _ in
        throw AlibabaSecretBearingError(secret: secret)
    })
    let context = alibabaContext(http: client, cookies: [.qoder: "session=\(secret)"])

    do {
        _ = try await QoderCookieStrategy(region: .international).fetch(context)
        Issue.record("Expected transport failure")
    } catch let error as UsageHTTPError {
        #expect(error == .transportFailure)
        #expect(!String(describing: error).contains(secret))
        #expect(!String(reflecting: error).contains(secret))
    }

    let diagnostics = [
        String(describing: QoderUsageError.invalidCredentials),
        String(reflecting: QoderUsageError.invalidResponse),
        String(describing: QwenUsageError.unauthorized),
        String(reflecting: QwenUsageError.invalidResponse),
    ]
    for diagnostic in diagnostics {
        #expect(!diagnostic.contains(secret))
        #expect(!diagnostic.contains("ticket-secret"))
        #expect(!diagnostic.contains("security-secret"))
    }
}
