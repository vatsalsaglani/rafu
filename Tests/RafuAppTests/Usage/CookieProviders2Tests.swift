import Foundation
import Testing

@testable import RafuApp

private func w7Context(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    readFiles: [String: String] = [:],
    http: UsageHTTPClient = .noop,
    credentials: [UsageProviderID: String] = [:],
    cookies: [UsageProviderID: String] = [:]
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: { readFiles[$0] },
        http: http,
        credential: { credentials[$0] },
        cookieHeader: { cookies[$0] })
}

private func w7Response(
    for request: URLRequest,
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

private actor W7RequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func snapshot() -> [URLRequest] { requests }
}

private actor W7Counter {
    private var value = 0

    func increment() { value += 1 }
    func count() -> Int { value }
}

private struct W7SecretTransportError: Error, Sendable, CustomStringConvertible {
    let secret: String
    var description: String { "transport leaked \(secret)" }
}

// MARK: - Descriptor contracts

@Test("W7 descriptors keep fixed strategy counts and source-backed order")
func w7DescriptorContracts() {
    let empty = w7Context()
    let populated = w7Context(
        readFiles: [".factory/.env": "FACTORY_API_KEY=factory-file"],
        credentials: [.amp: "amp-key", .factoryDroid: "factory-key", .warp: "warp-key"],
        cookies: [.windsurf: "session=w", .amp: "session=a", .factoryDroid: "session=f"])

    let descriptors = [
        WindsurfProvider.descriptor,
        AmpProvider.descriptor,
        FactoryDroidProvider.descriptor,
        WarpProvider.descriptor,
    ]
    for descriptor in descriptors {
        #expect(descriptor.defaultEnabled == false)
        #expect(
            descriptor.makeStrategies(empty).map(\.id)
                == descriptor.makeStrategies(populated).map(\.id))
    }

    #expect(
        WindsurfProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "windsurf.local-cached-plan"
        ])
    #expect(AmpProvider.descriptor.makeStrategies(empty).map(\.id) == ["amp.api-key"])
    #expect(
        FactoryDroidProvider.descriptor.makeStrategies(empty).map(\.id) == [
            "factory-droid.api-key", "factory-droid.cookie",
        ])
    #expect(WarpProvider.descriptor.makeStrategies(empty).map(\.id) == ["warp.api-key"])

    if case .localZeroConfig = WindsurfProvider.descriptor.authPattern {
    } else {
        Issue.record("Windsurf must describe its local cached-plan path")
    }
    if case .apiKey = AmpProvider.descriptor.authPattern {
    } else {
        Issue.record("Amp must describe its supported API-key path")
    }
    if case .cookieImport = FactoryDroidProvider.descriptor.authPattern {
    } else {
        Issue.record("Factory Droid must expose its cookie fallback")
    }
    if case .apiKey = WarpProvider.descriptor.authPattern {
    } else {
        Issue.record("Warp must describe its API-key-only path")
    }

    #expect(WindsurfProvider.descriptor.disclosure.contains("state.vscdb"))
    #expect(WindsurfProvider.descriptor.disclosure.contains("localStorage"))
    #expect(AmpProvider.descriptor.disclosure.contains("dashboard scraping is not used"))
    #expect(FactoryDroidProvider.descriptor.disclosure.contains("~/.factory/.env"))
    #expect(FactoryDroidProvider.descriptor.disclosure.contains("api.factory.ai"))
    #expect(WarpProvider.descriptor.disclosure.contains("WARP_API_KEY/WARP_TOKEN"))
}

// MARK: - Windsurf

@Test("Windsurf cached quota fixture maps exact daily and weekly usage")
func windsurfQuotaFixture() async throws {
    let fixture = #"""
        {
          "planName": "Pro",
          "quotaUsage": {
            "dailyRemainingPercent": 82.5,
            "weeklyRemainingPercent": 40,
            "dailyResetAtUnix": 1800003600,
            "weeklyResetAtUnix": 1800600000
          }
        }
        """#
    let strategy = WindsurfLocalCachedPlanStrategy(
        databasePath: "fixture.vscdb",
        readPlan: { path in path == "fixture.vscdb" ? fixture : nil })

    #expect(await strategy.isAvailable(w7Context()))
    let snapshot = try await strategy.fetch(w7Context())

    #expect(snapshot.providerID == .windsurf)
    #expect(snapshot.windows.map(\.label) == ["daily", "weekly"])
    #expect(snapshot.windows.map(\.percent) == [17.5, 60])
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
    #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_800_600_000))
    #expect(snapshot.identity == "Pro")
    #expect(snapshot.costLine == nil)
}

@Test("Windsurf legacy count fixture maps only real denominators")
func windsurfLegacyFixture() async throws {
    let fixture = #"""
        {
          "usage": {
            "messages": 100,
            "usedMessages": 25,
            "flowActions": 40,
            "remainingFlowActions": 10,
            "flexCredits": 20,
            "usedFlexCredits": 5
          }
        }
        """#
    let strategy = WindsurfLocalCachedPlanStrategy(
        databasePath: "fixture", readPlan: { _ in fixture })
    let snapshot = try await strategy.fetch(w7Context())

    #expect(snapshot.windows.map(\.label) == ["messages", "flow actions", "flex credits"])
    #expect(snapshot.windows.map(\.percent) == [25, 75, 25])
}

@Test("Windsurf accepts UTF-16LE cached JSON and rejects malformed or absent data")
func windsurfEncodingAndAbsence() async throws {
    let json = #"{"quotaUsage":{"dailyRemainingPercent":75}}"#
    let utf16 = try #require(json.data(using: .utf16LittleEndian))
    let decoded = try #require(WindsurfLocalCachedPlanStrategy.decodeSQLiteValue(utf16))
    #expect(try WindsurfLocalCachedPlanStrategy.parseCachedPlan(decoded).windows[0].percent == 25)

    let absent = WindsurfLocalCachedPlanStrategy(
        databasePath: "missing", readPlan: { _ in nil })
    #expect(await absent.isAvailable(w7Context()) == false)
    #expect(await resolveUsageSnapshot(strategies: [absent], context: w7Context()) == nil)

    let secret = "windsurf-local-secret"
    let malformed = WindsurfLocalCachedPlanStrategy(
        databasePath: "bad", readPlan: { _ in "{\"secret\":\"\(secret)\"}" })
    do {
        _ = try await malformed.fetch(w7Context())
        Issue.record("Expected invalid cached-plan data")
    } catch let error as WindsurfUsageError {
        #expect(error == .invalidResponse)
        #expect(!String(describing: error).contains(secret))
    }
    #expect(await resolveUsageSnapshot(strategies: [malformed], context: w7Context()) == nil)
}

// MARK: - Amp

@Test("Amp balance RPC fixture maps exact free usage, balances, identity, and headers")
func ampFixture() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let display = """
        Signed in as dev@example.com (Acme)
        Amp Free: $60 / $100 remaining (replenishes +$10 / hour)
        Individual credits: $12.50 remaining
        Workspace Acme: $7.25 remaining
        Workspace Lab: $2.75 remaining
        """
    let responseObject: [String: Any] = [
        "ok": true,
        "result": ["displayText": display],
    ]
    let responseData = try JSONSerialization.data(withJSONObject: responseObject)
    let client = UsageHTTPClient(transport: { request in
        #expect(
            request.url?.absoluteString
                == "https://ampcode.com/api/internal?userDisplayBalanceInfo")
        #expect(request.httpMethod == "POST")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer amp-secret")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["method"] as? String == "userDisplayBalanceInfo")
        let response = try #require(
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (responseData, response)
    })
    let context = w7Context(
        now: now,
        http: client,
        credentials: [.amp: "amp-secret"],
        cookies: [.amp: "session=must-not-be-sent"])

    let snapshot = try await AmpAPITokenStrategy(environment: [:]).fetch(context)

    #expect(snapshot.providerID == .amp)
    #expect(
        snapshot.windows == [
            UsageWindow(
                label: "Amp Free",
                percent: 40,
                tokens: nil,
                resetsAt: now.addingTimeInterval(4 * 60 * 60))
        ])
    #expect(snapshot.costLine == "Individual $12.50 remaining · Workspaces $10.00 remaining")
    #expect(snapshot.identity == "dev@example.com")
}

@Test("Amp remaining-percent fixture maps without inventing a clock reset")
func ampPercentFixture() throws {
    let snapshot = try AmpAPITokenStrategy.parseDisplayText(
        "Amp Free: 67% remaining today (resets daily)",
        now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(snapshot.windows[0].label == "daily")
    #expect(snapshot.windows[0].percent == 33)
    #expect(snapshot.windows[0].resetsAt == nil)
}

@Test("Amp absent token and invalid credentials hide the tile")
func ampAvailabilityAndUnauthorized() async throws {
    let missing = AmpAPITokenStrategy(environment: [:])
    let missingContext = w7Context(cookies: [.amp: "session=cookie-only"])
    #expect(await missing.isAvailable(missingContext) == false)
    #expect(await resolveUsageSnapshot(strategies: [missing], context: missingContext) == nil)

    let authRequired = #"{"ok":false,"error":{"code":"auth-required"}}"#
    let client = UsageHTTPClient(transport: { request in
        try w7Response(for: request, body: authRequired)
    })
    let context = w7Context(http: client, credentials: [.amp: "bad-amp-key"])
    do {
        _ = try await missing.fetch(context)
        Issue.record("Expected typed Amp unauthorized error")
    } catch let error as AmpUsageError {
        #expect(error == .unauthorized)
        #expect(!String(describing: error).contains("bad-amp-key"))
        #expect(missing.shouldFallback(on: error) == false)
    }
    #expect(await resolveUsageSnapshot(strategies: [missing], context: context) == nil)
}

// MARK: - Factory Droid

@Test("Factory resolves Rafu key, environment, then bounded dotenv before cookies")
func factoryCredentialAvailability() async {
    let stored = FactoryDroidAPIKeyStrategy(environment: ["FACTORY_API_KEY": "env-key"])
    #expect(await stored.isAvailable(w7Context(credentials: [.factoryDroid: "stored-key"])))

    let environment = FactoryDroidAPIKeyStrategy(environment: ["FACTORY_API_KEY": "env-key"])
    #expect(await environment.isAvailable(w7Context()))

    let dotenv = FactoryDroidAPIKeyStrategy(environment: [:])
    #expect(
        await dotenv.isAvailable(
            w7Context(readFiles: [
                ".factory/.env": "# fixture\nexport FACTORY_API_KEY='dotenv-key'\n"
            ])))
    #expect(await dotenv.isAvailable(w7Context()) == false)
}

@Test("Factory billing-limits fixture maps exact windows, resets, balance, and identity")
func factoryBillingFixture() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = W7RequestRecorder()
    let client = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer factory-key")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://app.factory.ai")
        #expect(request.value(forHTTPHeaderField: "x-factory-client") == "web-app")
        switch request.url?.path {
        case "/api/app/auth/me":
            return try w7Response(
                for: request,
                body:
                    #"{"userProfile":{"id":"user-1","email":"droid@example.com"},"organization":{"name":"Acme","subscription":{"factoryTier":"team","orbSubscription":{"plan":{"name":"Team"}}}}}"#
            )
        case "/api/billing/limits":
            return try w7Response(
                for: request,
                body:
                    #"{"usesTokenRateLimitsBilling":true,"limits":{"standard":{"fiveHour":{"usedPercent":12.5,"secondsRemaining":3600},"weekly":{"usedPercent":34,"windowEnd":"2027-01-16T08:00:00Z"},"monthly":{"usedPercent":56}}},"extraUsageBalanceCents":1234}"#
            )
        default:
            return try w7Response(for: request, status: 404, body: "{}")
        }
    })
    let context = w7Context(
        now: now,
        http: client,
        credentials: [.factoryDroid: "factory-key"])

    let snapshot = try await FactoryDroidAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.windows.map(\.label) == ["5h", "7d", "monthly"])
    #expect(snapshot.windows.map(\.percent) == [12.5, 34, 56])
    #expect(snapshot.windows[0].resetsAt == now.addingTimeInterval(3_600))
    #expect(
        snapshot.windows[1].resetsAt
            == UsageDateParsing.parseISO8601Fractional("2027-01-16T08:00:00Z"))
    #expect(snapshot.costLine == "Extra usage balance $12.34")
    #expect(snapshot.identity == "droid@example.com")
    #expect(
        (await recorder.snapshot()).map { $0.url?.path } == [
            "/api/app/auth/me", "/api/billing/limits",
        ])
}

@Test("Factory falls back from unavailable limits endpoint to legacy exact ratios")
func factoryLegacyFixture() async throws {
    let recorder = W7RequestRecorder()
    let client = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        switch request.url?.path {
        case "/api/app/auth/me":
            return try w7Response(
                for: request,
                body: #"{"userProfile":{"id":"legacy-user"},"organization":{"name":"Legacy Org"}}"#)
        case "/api/billing/limits":
            return try w7Response(for: request, status: 404, body: "{}")
        case "/api/organization/subscription/usage":
            let query = try #require(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.contains(URLQueryItem(name: "useCache", value: "true")))
            #expect(query.contains(URLQueryItem(name: "userId", value: "legacy-user")))
            return try w7Response(
                for: request,
                body:
                    #"{"usage":{"endDate":1801000000000,"standard":{"userTokens":100,"totalAllowance":1000,"usedRatio":0.1},"premium":{"userTokens":250,"totalAllowance":1000}}}"#
            )
        default:
            return try w7Response(for: request, status: 404, body: "{}")
        }
    })
    let context = w7Context(http: client, credentials: [.factoryDroid: "factory-key"])

    let snapshot = try await FactoryDroidAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.windows.map(\.label) == ["standard", "premium"])
    #expect(snapshot.windows.map(\.percent) == [10, 25])
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_801_000_000))
    #expect(snapshot.identity == "Legacy Org")
    #expect((await recorder.snapshot()).count == 3)
}

@Test("Factory expired windowEnd clears stale rolling usage")
func factoryExpiredBillingWindow() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let client = UsageHTTPClient(transport: { request in
        switch request.url?.path {
        case "/api/app/auth/me":
            return try w7Response(for: request, body: #"{"organization":{"name":"Acme"}}"#)
        case "/api/billing/limits":
            return try w7Response(
                for: request,
                body:
                    #"{"usesTokenRateLimitsBilling":true,"limits":{"standard":{"fiveHour":{"usedPercent":91,"windowEnd":"2027-01-15T07:59:59Z"},"weekly":{"usedPercent":20},"monthly":{"usedPercent":30}}}}"#
            )
        default:
            return try w7Response(for: request, status: 404, body: "{}")
        }
    })
    let context = w7Context(
        now: now, http: client, credentials: [.factoryDroid: "factory-key"])

    let snapshot = try await FactoryDroidAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.windows[0].percent == 0)
    #expect(snapshot.windows[0].resetsAt == nil)
    #expect(snapshot.windows[1].percent == 20)
}

@Test("Factory cached cookie is filtered, sent only first-party, and may supply bearer")
func factoryCookieFixture() async throws {
    let client = UsageHTTPClient(transport: { request in
        #expect(
            request.value(forHTTPHeaderField: "Cookie")
                == "session=factory-session; access-token=factory-access")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer factory-access")
        switch request.url?.path {
        case "/api/app/auth/me":
            return try w7Response(for: request, body: #"{"organization":{"name":"Cookie Org"}}"#)
        case "/api/billing/limits":
            return try w7Response(
                for: request,
                body:
                    #"{"usesTokenRateLimitsBilling":true,"limits":{"standard":{"fiveHour":{"usedPercent":5},"weekly":{"usedPercent":6},"monthly":{"usedPercent":7}}}}"#
            )
        default:
            return try w7Response(for: request, status: 404, body: "{}")
        }
    })
    let context = w7Context(
        http: client,
        cookies: [
            .factoryDroid:
                "session=factory-session; unrelated=must-not-send; access-token=factory-access"
        ])
    let strategy = FactoryDroidCookieStrategy()

    #expect(await strategy.isAvailable(context))
    let snapshot = try await strategy.fetch(context)
    #expect(snapshot.windows.map(\.percent) == [5, 6, 7])
    #expect(snapshot.identity == "Cookie Org")
}

@Test("Factory API unauthorized stops before an available cookie account")
func factoryUnauthorizedStopsPipeline() async throws {
    let counter = W7Counter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        return try w7Response(for: request, status: 401, body: "{}")
    })
    let context = w7Context(
        http: client,
        credentials: [.factoryDroid: "bad-factory-key"],
        cookies: [.factoryDroid: "session=other-account"])
    let api = FactoryDroidAPIKeyStrategy(environment: [:])
    let cookie = FactoryDroidCookieStrategy()

    do {
        _ = try await api.fetch(context)
        Issue.record("Expected typed Factory unauthorized error")
    } catch let error as FactoryDroidUsageError {
        #expect(error == .unauthorized)
        #expect(api.shouldFallback(on: error) == false)
        #expect(!String(describing: error).contains("bad-factory-key"))
    }
    #expect(
        await resolveUsageSnapshot(strategies: [api, cookie], context: context) == nil)
    #expect(await counter.count() == 2)
}

@Test("Factory absent key and cookie make both strategies unavailable")
func factoryAbsentAuth() async {
    let context = w7Context()
    let strategies: [any UsageFetchStrategy] = [
        FactoryDroidAPIKeyStrategy(environment: [:]), FactoryDroidCookieStrategy(),
    ]
    for strategy in strategies {
        #expect(await strategy.isAvailable(context) == false)
    }
    #expect(await resolveUsageSnapshot(strategies: strategies, context: context) == nil)
}

// MARK: - Warp

@Test("Warp GraphQL fixture maps request quota and aggregate bonus credits")
func warpFixture() async throws {
    let fixture = #"""
        {
          "data": {
            "user": {
              "__typename": "UserOutput",
              "user": {
                "requestLimitInfo": {
                  "isUnlimited": false,
                  "nextRefreshTime": "2027-01-15T08:00:00.000Z",
                  "requestLimit": 1500,
                  "requestsUsedSinceLastRefresh": 75
                },
                "bonusGrants": [
                  {"requestCreditsGranted":20,"requestCreditsRemaining":10}
                ],
                "workspaces": [
                  {"bonusGrantsInfo":{"grants":[
                    {"requestCreditsGranted":"15","requestCreditsRemaining":"5"}
                  ]}}
                ]
              }
            }
          }
        }
        """#
    let client = UsageHTTPClient(transport: { request in
        #expect(
            request.url?.absoluteString
                == "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")
        #expect(request.httpMethod == "POST")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer warp-secret")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Warp/1.0")
        #expect(request.value(forHTTPHeaderField: "x-warp-client-id") == "warp-app")
        #expect(request.value(forHTTPHeaderField: "x-warp-os-category") == "macOS")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["operationName"] as? String == "GetRequestLimitInfo")
        #expect((object["query"] as? String)?.contains("requestLimitInfo") == true)
        return try w7Response(for: request, body: fixture)
    })
    let context = w7Context(
        http: client,
        credentials: [.warp: "warp-secret"],
        cookies: [.warp: "session=must-not-send"])

    let snapshot = try await WarpAPIKeyStrategy(environment: [:]).fetch(context)

    #expect(snapshot.windows.map(\.label) == ["requests", "add-on credits"])
    #expect(snapshot.windows[0].percent == 5)
    #expect(abs((snapshot.windows[1].percent ?? 0) - (20.0 / 35.0 * 100)) < 0.000_001)
    #expect(
        snapshot.windows[0].resetsAt
            == UsageDateParsing.parseISO8601Fractional("2027-01-15T08:00:00.000Z"))
    #expect(snapshot.windows[1].resetsAt == nil)
}

@Test("Warp unlimited fixture is textual and does not invent a percentage")
func warpUnlimitedFixture() throws {
    let fixture =
        #"{"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":{"isUnlimited":true}}}}}"#
    let snapshot = try WarpAPIKeyStrategy.parseResponse(Data(fixture.utf8))
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.costLine == "Unlimited AI requests")
}

@Test("Warp missing and invalid credentials hide the tile")
func warpAvailabilityAndUnauthorized() async throws {
    let missing = WarpAPIKeyStrategy(environment: [:])
    let missingContext = w7Context(cookies: [.warp: "session=cookie-only"])
    #expect(await missing.isAvailable(missingContext) == false)
    #expect(await resolveUsageSnapshot(strategies: [missing], context: missingContext) == nil)

    let graphQLError = #"{"errors":[{"message":"Unauthorized"}]}"#
    do {
        _ = try WarpAPIKeyStrategy.parseResponse(Data(graphQLError.utf8))
        Issue.record("Expected typed Warp unauthorized error")
    } catch let error as WarpUsageError {
        #expect(error == .unauthorized)
        #expect(missing.shouldFallback(on: error) == false)
    }

    let client = UsageHTTPClient(transport: { request in
        try w7Response(for: request, status: 403, body: "{}")
    })
    let context = w7Context(http: client, credentials: [.warp: "bad-warp-key"])
    #expect(await resolveUsageSnapshot(strategies: [missing], context: context) == nil)
}

// MARK: - Redaction

@Test("W7 injected transport failures structurally redact every token and cookie")
func w7TransportRedaction() async throws {
    let cases: [(String, any UsageFetchStrategy, UsageFetchContext)] = [
        (
            "amp-redaction-secret",
            AmpAPITokenStrategy(environment: [:]),
            w7Context(credentials: [.amp: "amp-redaction-secret"])
        ),
        (
            "factory-redaction-secret",
            FactoryDroidAPIKeyStrategy(environment: [:]),
            w7Context(credentials: [.factoryDroid: "factory-redaction-secret"])
        ),
        (
            "warp-redaction-secret",
            WarpAPIKeyStrategy(environment: [:]),
            w7Context(credentials: [.warp: "warp-redaction-secret"])
        ),
        (
            "factory-cookie-redaction-secret",
            FactoryDroidCookieStrategy(),
            w7Context(cookies: [
                .factoryDroid: "session=factory-cookie-redaction-secret"
            ])
        ),
    ]

    for (secret, strategy, baseContext) in cases {
        let client = UsageHTTPClient(transport: { _ in
            throw W7SecretTransportError(secret: secret)
        })
        let context = UsageFetchContext(
            now: baseContext.now,
            readFile: baseContext.readFile,
            http: client,
            credential: baseContext.credential,
            cookieHeader: baseContext.cookieHeader)
        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected redacted transport failure for \(strategy.id)")
        } catch {
            #expect(error as? UsageHTTPError == .transportFailure)
            #expect(!String(describing: error).contains(secret))
            #expect(!String(describing: error).lowercased().contains("bearer"))
            #expect(!String(describing: error).lowercased().contains("cookie"))
        }
    }
}
