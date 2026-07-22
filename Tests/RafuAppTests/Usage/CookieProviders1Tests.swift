import Foundation
import SQLite3
import Testing

@testable import RafuApp

private func cookieProvidersContext(
    now: Date = Date(timeIntervalSince1970: 2_000_000_000),
    readFile: @escaping @Sendable (String) -> String? = { _ in nil },
    http: UsageHTTPClient = .noop,
    credentials: [UsageProviderID: String] = [:],
    cookies: [UsageProviderID: String] = [:]
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: readFile,
        http: http,
        credential: { credentials[$0] },
        cookieHeader: { cookies[$0] })
}

private func cookieProviderResponse(
    for request: URLRequest,
    status: Int = 200,
    headers: [String: String] = [:],
    data: Data,
    finalURL: URL? = nil
) throws -> (Data, HTTPURLResponse) {
    let url = try #require(finalURL ?? request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers))
    return (data, response)
}

private actor CookieProviderRequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func snapshot() -> [URLRequest] { requests }
}

private struct CookieProviderSecretError: Error, Sendable, CustomStringConvertible {
    let secret: String
    var description: String { "transport included \(secret)" }
}

private enum AntigravityFixtureError: Error { case open, exec, prepare, step }

/// Writes a temporary `state.vscdb` holding Antigravity's OAuth token under
/// its real `ItemTable` key, mirroring how the Cursor tests build a fixture
/// database. A `nil` token creates the table but stores no row (signed-out).
private func makeAntigravityDatabase(token: String?) throws -> (root: URL, database: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AntigravityProviderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("state.vscdb")

    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK else {
        throw AntigravityFixtureError.open
    }
    defer { sqlite3_close(db) }
    guard
        sqlite3_exec(
            db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil)
            == SQLITE_OK
    else {
        throw AntigravityFixtureError.exec
    }

    if let token {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &statement, nil)
                == SQLITE_OK
        else {
            throw AntigravityFixtureError.prepare
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "antigravityUnifiedStateSync.oauthToken", -1, transient)
        sqlite3_bind_text(statement, 2, token, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AntigravityFixtureError.step }
    }
    return (root, database)
}

private func grokAuth(
    now: Date,
    token: String = "grok-secret",
    email: String = "grok@example.com"
) -> String {
    """
    {"https://auth.x.ai::fixture":{"key":"\(token)","email":"\(email)","expires_at":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)))"}}
    """
}

private func grpcWebFrame(flags: UInt8 = 0, payload: Data) -> Data {
    let count = UInt32(payload.count)
    var result = Data([
        flags,
        UInt8((count >> 24) & 0xFF),
        UInt8((count >> 16) & 0xFF),
        UInt8((count >> 8) & 0xFF),
        UInt8(count & 0xFF),
    ])
    result.append(payload)
    return result
}

private func protobufVarint(_ value: UInt64) -> Data {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return Data(bytes)
}

private func protobufVarintField(_ field: UInt64, value: UInt64) -> Data {
    var data = protobufVarint(field << 3)
    data.append(protobufVarint(value))
    return data
}

private func protobufFixed32Field(_ field: UInt64, value: Float) -> Data {
    var data = protobufVarint((field << 3) | 5)
    let bits = value.bitPattern
    data.append(contentsOf: [
        UInt8(bits & 0xFF),
        UInt8((bits >> 8) & 0xFF),
        UInt8((bits >> 16) & 0xFF),
        UInt8((bits >> 24) & 0xFF),
    ])
    return data
}

private func protobufMessageField(_ field: UInt64, payload: Data) -> Data {
    var data = protobufVarint((field << 3) | 2)
    data.append(protobufVarint(UInt64(payload.count)))
    data.append(payload)
    return data
}

private func grokBillingFixture(percent: Float, reset: Date) -> Data {
    let resetMessage = protobufVarintField(1, value: UInt64(reset.timeIntervalSince1970))
    var billing = protobufFixed32Field(1, value: percent)
    billing.append(protobufMessageField(5, payload: resetMessage))
    return grpcWebFrame(payload: protobufMessageField(1, payload: billing))
}

private let kiloFixture = Data(
    #"""
    [
      {"result":{"data":{"json":{"creditBlocks":[
        {"amount_mUsd":10000000,"balance_mUsd":4000000},
        {"amount_mUsd":"5000000","balance_mUsd":"1000000"}
      ]}}}},
      {"result":{"data":{"json":{"subscription":{
        "currentPeriodUsageUsd":12.5,
        "currentPeriodBaseCreditsUsd":20,
        "currentPeriodBonusCreditsUsd":5,
        "nextRenewalAt":"2033-05-25T03:33:20Z",
        "tier":"tier_49"
      }}}}},
      {"error":{"json":{"message":"FORBIDDEN"}}}
    ]
    """#.utf8)

@Suite("CookieProviders1")
struct CookieProviders1Tests {
    @Test("W6 descriptors have fixed strategy order, auth patterns, and disclosures")
    func descriptorContracts() {
        let empty = cookieProvidersContext()
        let populated = cookieProvidersContext(
            readFile: { _ in "fixture" },
            credentials: [.kiloCode: "key"],
            cookies: [.grokBuild: "sso=cached"])

        if case .piggybackNetwork = AntigravityProvider.descriptor.authPattern {
        } else {
            Issue.record("Antigravity must use piggyback-network auth")
        }
        if case .cookieImport = GrokBuildProvider.descriptor.authPattern {
        } else {
            Issue.record("Grok Build must use cookie-import auth")
        }
        if case .apiKey = KiloCodeProvider.descriptor.authPattern {
        } else {
            Issue.record("Kilo Code must use API-key auth")
        }
        #expect(!AntigravityProvider.descriptor.defaultEnabled)
        #expect(!GrokBuildProvider.descriptor.defaultEnabled)
        #expect(!KiloCodeProvider.descriptor.defaultEnabled)

        #expect(
            AntigravityProvider.descriptor.makeStrategies(empty).map(\.id) == [
                "antigravity.local-oauth"
            ])
        #expect(AntigravityProvider.descriptor.makeStrategies(populated).count == 1)
        #expect(
            GrokBuildProvider.descriptor.makeStrategies(empty).map(\.id) == [
                "grok-build.local-bearer", "grok-build.cached-cookie",
            ])
        #expect(GrokBuildProvider.descriptor.makeStrategies(populated).count == 2)
        #expect(
            KiloCodeProvider.descriptor.makeStrategies(empty).map(\.id) == [
                "kilo-code.cli-token", "kilo-code.api-key",
            ])
        #expect(KiloCodeProvider.descriptor.makeStrategies(populated).count == 2)

        #expect(AntigravityProvider.descriptor.disclosure.contains("state.vscdb"))
        #expect(AntigravityProvider.descriptor.disclosure.contains("retrieveUserQuota"))
        #expect(
            !AntigravityProvider.descriptor.disclosure.lowercased().contains("codexbar"))
        #expect(GrokBuildProvider.descriptor.disclosure.contains("sso and sso-rw"))
        #expect(GrokBuildProvider.descriptor.disclosure.contains("GetGrokCreditsConfig"))
        #expect(KiloCodeProvider.descriptor.disclosure.contains("~/.local/share/kilo/auth.json"))
        #expect(KiloCodeProvider.descriptor.disclosure.contains("KILO_API_KEY"))
    }

    @Test("Absent W6 credentials resolve nil without transport or browser import")
    func absentCredentialsDoNotCallTransport() async {
        let recorder = CookieProviderRequestRecorder()
        let client = UsageHTTPClient(transport: { request in
            await recorder.record(request)
            return try cookieProviderResponse(for: request, data: Data())
        })
        let context = cookieProvidersContext(http: client)
        let descriptors = [
            GrokBuildProvider.descriptor,
            KiloCodeProvider.descriptor,
        ]

        for descriptor in descriptors {
            #expect(
                await resolveUsageSnapshot(
                    strategies: descriptor.makeStrategies(context), context: context) == nil)
        }
        // Antigravity reads a real on-disk state.vscdb path, so pin it to a
        // nonexistent database rather than the machine default, which may
        // exist when Antigravity is installed on the test host.
        let missingDatabase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityAbsent-\(UUID().uuidString)/state.vscdb").path
        #expect(
            await resolveUsageSnapshot(
                strategies: [AntigravityLocalOAuthStrategy(databasePath: missingDatabase)],
                context: context) == nil)
        #expect(await recorder.snapshot().isEmpty)
    }

    @Test("Antigravity is unavailable without a readable state.vscdb token")
    func antigravityWithoutTokenIsUnavailable() async throws {
        let context = cookieProvidersContext()

        // Missing database file.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityMissing-\(UUID().uuidString)/state.vscdb").path
        #expect(
            await !AntigravityLocalOAuthStrategy(databasePath: missing).isAvailable(context))

        // Present database, but signed out (no token row).
        let signedOut = try makeAntigravityDatabase(token: nil)
        #expect(
            await !AntigravityLocalOAuthStrategy(databasePath: signedOut.database.path)
                .isAvailable(context))

        // Present database with a blank token is not a usable credential.
        let blank = try makeAntigravityDatabase(token: "   ")
        #expect(
            await !AntigravityLocalOAuthStrategy(databasePath: blank.database.path)
                .isAvailable(context))
    }

    @Test("Antigravity fixture maps most-consumed model groups and exact request chain")
    func antigravityFixtureAndRequests() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let geminiReset = "2033-05-18T04:00:00Z"
        let sharedReset = "2033-05-18T05:00:00.000Z"
        let recorder = CookieProviderRequestRecorder()
        let client = UsageHTTPClient(transport: { request in
            await recorder.record(request)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ag-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "antigravity")
            #expect(request.timeoutInterval == 15)
            switch request.url?.path {
            case "/v1internal:loadCodeAssist":
                let requestBody = try #require(request.httpBody)
                let body = try #require(
                    JSONSerialization.jsonObject(with: requestBody)
                        as? [String: [String: String]])
                #expect(body["metadata"]?["ideType"] == "ANTIGRAVITY")
                #expect(body["metadata"]?["platform"] == "PLATFORM_UNSPECIFIED")
                #expect(body["metadata"]?["pluginType"] == "GEMINI")
                return try cookieProviderResponse(
                    for: request,
                    data: Data(#"{"cloudaicompanionProject":{"id":"project-123"}}"#.utf8))
            case "/v1internal:fetchAvailableModels":
                let requestBody = try #require(request.httpBody)
                let body = try #require(
                    JSONSerialization.jsonObject(with: requestBody)
                        as? [String: String])
                #expect(body == ["project": "project-123"])
                return try cookieProviderResponse(
                    for: request,
                    data: Data(
                        #"""
                        {"models":{
                          "gemini-3-pro":{"quotaInfo":{"remainingFraction":0.75,"resetTime":"2033-05-18T03:00:00Z"}},
                          "gemini-3-flash":{"quotaInfo":{"remainingFraction":0.40,"resetTime":"\#(geminiReset)"}},
                          "gemini-3-flash-lite":{"quotaInfo":{"remainingFraction":0.10}},
                          "claude-sonnet":{"quotaInfo":{"remainingFraction":0.80,"resetTime":"2033-05-18T03:00:00Z"}},
                          "gpt-5":{"quotaInfo":{"remainingFraction":0.30,"resetTime":"\#(sharedReset)"}},
                          "gpt-image":{"quotaInfo":{"remainingFraction":0.05}}
                        }}
                        """#.utf8))
            default:
                return try cookieProviderResponse(for: request, status: 404, data: Data())
            }
        })
        let fixture = try makeAntigravityDatabase(token: "ag-token")
        let context = cookieProvidersContext(now: now, http: client)

        let snapshot = try await AntigravityLocalOAuthStrategy(
            databasePath: fixture.database.path
        ).fetch(context)

        #expect(snapshot.providerID == .antigravity)
        #expect(snapshot.windows.map(\.label) == ["Gemini Models", "Claude and GPT"])
        #expect(snapshot.windows.map(\.percent) == [60, 70])
        #expect(
            snapshot.windows.map(\.resetsAt) == [
                UsageDateParsing.parseISO8601Fractional(geminiReset),
                UsageDateParsing.parseISO8601Fractional(sharedReset),
            ])
        // The opaque state.vscdb token carries no email; identity is unset.
        #expect(snapshot.identity == nil)
        #expect(snapshot.costLine == nil)
        #expect(await recorder.snapshot().count == 2)
    }

    @Test("Antigravity verifies suspicious all-full model quotas")
    func antigravityFullQuotaVerification() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recorder = CookieProviderRequestRecorder()
        let client = UsageHTTPClient(transport: { request in
            await recorder.record(request)
            switch request.url?.path {
            case "/v1internal:loadCodeAssist":
                return try cookieProviderResponse(
                    for: request, data: Data(#"{"cloudaicompanionProject":"project"}"#.utf8))
            case "/v1internal:fetchAvailableModels":
                return try cookieProviderResponse(
                    for: request,
                    data: Data(
                        #"{"models":{"gemini-3-pro":{"quotaInfo":{"remainingFraction":1}}}}"#.utf8))
            case "/v1internal:retrieveUserQuota":
                let requestBody = try #require(request.httpBody)
                let body = try #require(
                    JSONSerialization.jsonObject(with: requestBody)
                        as? [String: String])
                #expect(body == ["project": "project"])
                return try cookieProviderResponse(
                    for: request,
                    data: Data(
                        #"{"buckets":[{"modelId":"gemini-3-pro","remainingFraction":0.25}]}"#.utf8))
            default:
                return try cookieProviderResponse(for: request, status: 404, data: Data())
            }
        })
        let fixture = try makeAntigravityDatabase(token: "antigravity-secret")
        let context = cookieProvidersContext(now: now, http: client)

        let snapshot = try await AntigravityLocalOAuthStrategy(
            databasePath: fixture.database.path
        ).fetch(context)
        #expect(snapshot.windows.map(\.percent) == [75])
        #expect(
            await recorder.snapshot().map { $0.url?.path } == [
                "/v1internal:loadCodeAssist",
                "/v1internal:fetchAvailableModels",
                "/v1internal:retrieveUserQuota",
            ])
    }

    @Test("Antigravity 401 is typed invalid credentials and hides the tile")
    func antigravityUnauthorizedIsTyped() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secret = "antigravity-secret-that-must-not-escape"
        let client = UsageHTTPClient(transport: { request in
            try cookieProviderResponse(for: request, status: 401, data: Data())
        })
        let fixture = try makeAntigravityDatabase(token: secret)
        let context = cookieProvidersContext(now: now, http: client)
        let strategy = AntigravityLocalOAuthStrategy(databasePath: fixture.database.path)

        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected invalid credentials")
        } catch let error as AntigravityUsageError {
            #expect(error == .invalidCredentials)
            #expect(!String(describing: error).contains(secret))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    }

    @Test("Grok local bearer fixture maps protobuf percent and exact grpc-web request")
    func grokLocalBearerFixtureAndRequest() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(7 * 24 * 60 * 60)
        let fixture = grokBillingFixture(percent: 37.5, reset: reset)
        let client = UsageHTTPClient(transport: { request in
            #expect(
                request.url?.absoluteString
                    == "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == Data([0, 0, 0, 0, 0]))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer grok-token")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://grok.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://grok.com/?_s=usage")
            #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
            #expect(
                request.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
            #expect(request.value(forHTTPHeaderField: "x-grpc-web") == "1")
            #expect(request.value(forHTTPHeaderField: "x-user-agent") == "connect-es/2.1.1")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Rafu")
            #expect(request.timeoutInterval == 15)
            return try cookieProviderResponse(
                for: request,
                headers: ["Content-Type": "application/grpc-web+proto", "grpc-status": "0"],
                data: fixture)
        })
        let context = cookieProvidersContext(
            now: now,
            readFile: { path in
                path == ".grok/auth.json"
                    ? grokAuth(now: now, token: "grok-token", email: "person@x.ai")
                    : nil
            },
            http: client)

        let snapshot = try await GrokBuildLocalBearerStrategy().fetch(context)
        #expect(snapshot.providerID == .grokBuild)
        #expect(
            snapshot.windows == [
                UsageWindow(label: "weekly", percent: 37.5, tokens: nil, resetsAt: reset)
            ])
        #expect(snapshot.identity == "person@x.ai")
    }

    @Test("Grok falls from rejected local bearer to cached cookie without importing")
    func grokLocalFirstFallbackToCachedCookie() async {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = grokBillingFixture(percent: 15, reset: now.addingTimeInterval(30 * 86_400))
        let recorder = CookieProviderRequestRecorder()
        let client = UsageHTTPClient(transport: { request in
            await recorder.record(request)
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                return try cookieProviderResponse(for: request, status: 401, data: Data())
            }
            #expect(request.value(forHTTPHeaderField: "Cookie") == "sso=cached; sso-rw=cached-rw")
            return try cookieProviderResponse(
                for: request,
                headers: ["Content-Type": "application/grpc-web+proto"],
                data: fixture)
        })
        let context = cookieProvidersContext(
            now: now,
            readFile: { _ in grokAuth(now: now, token: "stale-local") },
            http: client,
            cookies: [.grokBuild: "sso=cached; sso-rw=cached-rw"])

        let snapshot = await resolveUsageSnapshot(
            strategies: GrokBuildProvider.descriptor.makeStrategies(context), context: context)
        #expect(snapshot?.windows.map(\.label) == ["monthly"])
        let requests = await recorder.snapshot()
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer stale-local")
        #expect(requests[1].value(forHTTPHeaderField: "Cookie") == "sso=cached; sso-rw=cached-rw")
    }

    @Test("Grok login redirect and HTML are typed invalid credentials")
    func grokSignedOutHTMLIsTyped() async throws {
        let secret = "sso=secret-cookie"
        let client = UsageHTTPClient(transport: { request in
            try cookieProviderResponse(
                for: request,
                headers: ["Content-Type": "text/html"],
                data: Data("<html>Sign in</html>".utf8),
                finalURL: URL(string: "https://accounts.x.ai/sign-in")!)
        })
        let context = cookieProvidersContext(http: client, cookies: [.grokBuild: secret])

        do {
            _ = try await GrokBuildCachedCookieStrategy().fetch(context)
            Issue.record("Expected invalid credentials")
        } catch let error as GrokBuildUsageError {
            #expect(error == .invalidCredentials)
            #expect(!String(describing: error).contains(secret))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(
        "Grok grpc credential failures are typed",
        arguments: [
            ("16", "Unauthenticated"),
            ("7", "access token expired"),
        ])
    func grokGRPCCredentialsAreTyped(status: String, message: String) async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let client = UsageHTTPClient(transport: { request in
            try cookieProviderResponse(
                for: request,
                headers: ["grpc-status": status, "grpc-message": message],
                data: grokBillingFixture(percent: 1, reset: now.addingTimeInterval(86_400)))
        })
        let context = cookieProvidersContext(
            now: now,
            readFile: { _ in grokAuth(now: now) },
            http: client)

        await #expect(throws: GrokBuildUsageError.invalidCredentials) {
            try await GrokBuildLocalBearerStrategy().fetch(context)
        }
    }

    @Test("Kilo fixture maps mUsd credits and pass usage with exact tRPC batch request")
    func kiloFixtureAndExactRequest() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let client = UsageHTTPClient(transport: { request in
            #expect(request.url?.host == "app.kilo.ai")
            #expect(
                request.url?.path
                    == "/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod"
            )
            let query = Dictionary(
                uniqueKeysWithValues: (URLComponents(
                    url: try #require(request.url), resolvingAgainstBaseURL: false
                )?.queryItems ?? []).map { ($0.name, $0.value) })
            #expect(query["batch"] == "1")
            #expect(
                query["input"]
                    == #"{"0":{"json":null},"1":{"json":null},"2":{"json":null}}"#)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kilo-cli-token")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return try cookieProviderResponse(
                for: request, headers: ["Content-Type": "application/json"], data: kiloFixture)
        })
        let context = cookieProvidersContext(
            now: now,
            readFile: { path in
                path == ".local/share/kilo/auth.json"
                    ? #"{"kilo":{"access":" kilo-cli-token "}}"#
                    : nil
            },
            http: client,
            credentials: [.kiloCode: "explicit-key-must-not-win"])

        let snapshot = try await KiloCodeCLITokenStrategy().fetch(context)
        #expect(snapshot.providerID == .kiloCode)
        #expect(snapshot.windows.map(\.label) == ["credits", "Kilo Pass"])
        #expect(abs((snapshot.windows[0].percent ?? 0) - 66.666_666_666_7) < 0.000_001)
        #expect(snapshot.windows[1].percent == 50)
        #expect(
            snapshot.windows[1].resetsAt
                == UsageDateParsing.parseISO8601Fractional("2033-05-25T03:33:20Z"))
        #expect(snapshot.costLine == "$10.00 used · $5.00 remaining")
        #expect(snapshot.identity == nil)
    }

    @Test("Kilo falls from rejected CLI token to explicit API key")
    func kiloLocalFirstFallback() async {
        let recorder = CookieProviderRequestRecorder()
        let client = UsageHTTPClient(transport: { request in
            await recorder.record(request)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale-cli" {
                return try cookieProviderResponse(for: request, status: 401, data: Data())
            }
            return try cookieProviderResponse(
                for: request, headers: ["Content-Type": "application/json"], data: kiloFixture)
        })
        let context = cookieProvidersContext(
            readFile: { _ in #"{"kilo":{"access":"stale-cli"}}"# },
            http: client,
            credentials: [.kiloCode: "fresh-explicit"])

        let snapshot = await resolveUsageSnapshot(
            strategies: [KiloCodeCLITokenStrategy(), KiloCodeAPIKeyStrategy(environment: [:])],
            context: context)
        #expect(snapshot?.providerID == .kiloCode)
        #expect(
            await recorder.snapshot().compactMap {
                $0.value(forHTTPHeaderField: "Authorization")
            } == ["Bearer stale-cli", "Bearer fresh-explicit"])
    }

    @Test("Kilo explicit strategy falls back to KILO_API_KEY environment")
    func kiloEnvironmentFallback() async {
        let strategy = KiloCodeAPIKeyStrategy(environment: ["KILO_API_KEY": "env-kilo-key"])
        #expect(await strategy.isAvailable(cookieProvidersContext()))
    }

    @Test("Kilo HTTP and tRPC auth failures are typed and redacted", arguments: [true, false])
    func kiloAuthFailuresAreTyped(httpFailure: Bool) async {
        let secret = "kilo-secret-that-must-not-escape"
        let client = UsageHTTPClient(transport: { request in
            if httpFailure {
                return try cookieProviderResponse(for: request, status: 401, data: Data())
            }
            return try cookieProviderResponse(
                for: request,
                headers: ["Content-Type": "application/json"],
                data: Data(
                    #"[{"error":{"json":{"message":"UNAUTHORIZED","data":{"code":"UNAUTHORIZED"}}}}]"#
                        .utf8))
        })
        let context = cookieProvidersContext(
            http: client, credentials: [.kiloCode: secret])
        let strategy = KiloCodeAPIKeyStrategy(environment: [:])

        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected invalid credentials")
        } catch let error as KiloCodeUsageError {
            #expect(error == .invalidCredentials)
            #expect(!String(describing: error).contains(secret))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Injected transport details containing W6 credentials are structurally redacted")
    func transportErrorsAreRedacted() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secret = "w6-secret-that-must-not-escape"
        let client = UsageHTTPClient(transport: { _ in
            throw CookieProviderSecretError(secret: secret)
        })
        let antigravityFixture = try makeAntigravityDatabase(token: secret)
        let attempts: [(any UsageFetchStrategy, UsageFetchContext)] = [
            (
                AntigravityLocalOAuthStrategy(databasePath: antigravityFixture.database.path),
                cookieProvidersContext(now: now, http: client)
            ),
            (
                GrokBuildCachedCookieStrategy(),
                cookieProvidersContext(http: client, cookies: [.grokBuild: "sso=\(secret)"])
            ),
            (
                KiloCodeAPIKeyStrategy(environment: [:]),
                cookieProvidersContext(http: client, credentials: [.kiloCode: secret])
            ),
        ]

        for (strategy, context) in attempts {
            do {
                _ = try await strategy.fetch(context)
                Issue.record("Expected transport failure")
            } catch {
                #expect(error as? UsageHTTPError == .transportFailure)
                #expect(!String(describing: error).contains(secret))
                #expect(!String(describing: error).lowercased().contains("bearer"))
                #expect(!String(describing: error).lowercased().contains("cookie"))
            }
        }
    }
}
