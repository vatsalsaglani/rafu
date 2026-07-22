import Foundation
import Testing

@testable import RafuApp

private func localTokenContext(
    now: Date = Date(timeIntervalSince1970: 2_000_000_000),
    readFile: @escaping @Sendable (String) -> String? = { _ in nil },
    http: UsageHTTPClient = .noop
) -> UsageFetchContext {
    UsageFetchContext(
        now: now,
        readFile: readFile,
        http: http,
        credential: { _ in nil },
        cookieHeader: { _ in nil })
}

private func successfulResponse(for request: URLRequest, statusCode: Int = 200) throws
    -> HTTPURLResponse
{
    guard let url = request.url,
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
    else {
        throw UsageHTTPError.invalidResponse
    }
    return response
}

private actor LocalTokenRequestRecorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        self.requests.append(request)
    }

    func snapshot() -> [URLRequest] { self.requests }
}

private struct SecretBearingTransportError: Error, CustomStringConvertible {
    let secret: String
    var description: String { "transport failed with \(self.secret)" }
}

private func geminiCredential(
    now: Date, accessToken: String = "gemini-secret", idToken: String? = nil,
    expiresAt: Date? = nil
) -> String {
    var object: [String: Any] = ["access_token": accessToken]
    if let idToken {
        object["id_token"] = idToken
    }
    if let expiresAt {
        object["expiry_date"] = expiresAt.timeIntervalSince1970 * 1_000
    }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func geminiFileReader(
    credentials: String?, settings: String? = nil
) -> @Sendable (String) -> String? {
    { path in
        switch path {
        case ".gemini/oauth_creds.json": credentials
        case ".gemini/settings.json": settings
        default: nil
        }
    }
}

private func jwt(email: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["email": email])
    let payload = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

private func kimiCredential(
    accessToken: String = "kimi-secret", expiresAt: String
) -> String {
    "{\"access_token\":\"\(accessToken)\",\"expires_at\":\"\(expiresAt)\"}"
}

private func kimiFileReader(
    credentials: String?, deviceID: String? = nil
) -> @Sendable (String) -> String? {
    { path in
        switch path {
        case ".kimi-code/credentials/kimi-code.json": credentials
        case ".kimi-code/device_id": deviceID
        default: nil
        }
    }
}

// MARK: - Stable strategy lists and descriptors

@Test("W5 providers return one strategy regardless of context")
func localTokenStrategyCountsAreContextIndependent() {
    let empty = localTokenContext()
    let populated = localTokenContext(
        readFile: { _ in "non-empty" },
        http: UsageHTTPClient(transport: { request in
            (Data(), try successfulResponse(for: request))
        }))

    #expect(GeminiCLIProvider.descriptor.makeStrategies(empty).count == 1)
    #expect(GeminiCLIProvider.descriptor.makeStrategies(populated).count == 1)
    #expect(CopilotProvider.descriptor.makeStrategies(empty).count == 1)
    #expect(CopilotProvider.descriptor.makeStrategies(populated).count == 1)
    #expect(KimiProvider.descriptor.makeStrategies(empty).count == 1)
    #expect(KimiProvider.descriptor.makeStrategies(populated).count == 1)
    #expect(!GeminiCLIProvider.descriptor.defaultEnabled)
    #expect(!CopilotProvider.descriptor.defaultEnabled)
    #expect(!KimiProvider.descriptor.defaultEnabled)
}

@Test("W5 descriptors carry the exact credential and network disclosures")
func localTokenProviderDisclosures() {
    #expect(
        GeminiCLIProvider.descriptor.disclosure
            == "Reads ~/.gemini/oauth_creds.json and ~/.gemini/settings.json; sends only the access token to cloudcode-pa.googleapis.com/v1internal:loadCodeAssist and cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota (and cloudresourcemanager.googleapis.com/v1/projects only when needed) to fetch usage numbers."
    )
    #expect(
        KimiProvider.descriptor.disclosure
            == "Reads ~/.kimi-code/credentials/kimi-code.json and optional ~/.kimi-code/device_id; sends only the access token to api.kimi.com/coding/v1/usages to fetch usage numbers."
    )
    #expect(
        CopilotProvider.descriptor.disclosure
            == "Unavailable: no discoverable local Copilot CLI or gh token is exposed for reading; usage requires a manually or device-flow supplied token."
    )
    // The user-facing disclosure must not name CodexBar (attribution stays
    // in the file-header comment, which is a legal condition of reuse).
    #expect(!CopilotProvider.descriptor.disclosure.lowercased().contains("codexbar"))
}

// MARK: - Gemini CLI

@Test("Gemini CLI fixture maps model minima and sends the exact Cloud Code request chain")
func geminiFixtureMapsToSnapshotAndExactRequests() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let resetPro = "2033-05-18T04:00:00Z"
    let resetFlash = "2033-05-18T05:00:00.000Z"
    let identityToken = jwt(email: "person@example.com")
    let recorder = LocalTokenRequestRecorder()
    let client = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let data: Data
        switch request.url?.absoluteString {
        case "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist":
            data = Data("{}".utf8)
        case "https://cloudresourcemanager.googleapis.com/v1/projects":
            data = Data(
                """
                {"projects":[{"projectId":"ordinary"},{"projectId":"gen-lang-client-123"}]}
                """.utf8)
        case "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota":
            data = Data(
                """
                {"buckets":[
                  {"modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2033-05-18T03:00:00Z"},
                  {"modelId":"gemini-2.5-pro","remainingFraction":0.3,"resetTime":"\(resetPro)"},
                  {"modelId":"gemini-2.5-flash","remainingFraction":0.6,"resetTime":"\(resetFlash)"},
                  {"modelId":"gemini-2.5-flash-lite","remainingFraction":0.9}
                ]}
                """.utf8)
        default:
            throw UsageHTTPError.invalidResponse
        }
        return (data, try successfulResponse(for: request))
    })
    let context = localTokenContext(
        now: now,
        readFile: geminiFileReader(
            credentials: geminiCredential(
                now: now, idToken: identityToken,
                expiresAt: now.addingTimeInterval(3_600)),
            settings: "{\"security\":{\"auth\":{\"selectedType\":\"oauth-personal\"}}}"),
        http: client)

    let snapshot = await resolveUsageSnapshot(
        strategies: GeminiCLIProvider.descriptor.makeStrategies(context), context: context)
    #expect(snapshot?.providerID == .geminiCLI)
    #expect(snapshot?.identity == "person@example.com")
    #expect(snapshot?.costLine == nil)
    #expect(snapshot?.windows.count == 3)
    #expect(
        snapshot?.windows[0]
            == UsageWindow(
                label: "Pro", percent: 70, tokens: nil,
                resetsAt: UsageDateParsing.parseISO8601Fractional(resetPro)))
    #expect(
        snapshot?.windows[1]
            == UsageWindow(
                label: "Flash", percent: 40, tokens: nil,
                resetsAt: UsageDateParsing.parseISO8601Fractional(resetFlash)))
    #expect(
        snapshot?.windows[2]
            == UsageWindow(label: "Flash Lite", percent: 10, tokens: nil, resetsAt: nil))

    let requests = await recorder.snapshot()
    #expect(requests.count == 3)
    let load = try #require(requests.first)
    #expect(
        load.url?.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
    #expect(load.httpMethod == "POST")
    #expect(load.value(forHTTPHeaderField: "Authorization") == "Bearer gemini-secret")
    #expect(load.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
        load.httpBody
            == Data(
                "{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8))

    let projects = requests[1]
    #expect(
        projects.url?.absoluteString == "https://cloudresourcemanager.googleapis.com/v1/projects")
    #expect(projects.httpMethod == "GET")
    #expect(projects.value(forHTTPHeaderField: "Authorization") == "Bearer gemini-secret")
    #expect(projects.httpBody == nil)

    let quota = requests[2]
    #expect(
        quota.url?.absoluteString
            == "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
    #expect(quota.httpMethod == "POST")
    #expect(quota.value(forHTTPHeaderField: "Authorization") == "Bearer gemini-secret")
    #expect(quota.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let quotaBody = try #require(quota.httpBody)
    let quotaObject = try #require(
        JSONSerialization.jsonObject(with: quotaBody) as? [String: String])
    #expect(quotaObject == ["project": "gen-lang-client-123"])
}

@Test("Gemini accepts loadCodeAssist's object project and skips project discovery")
func geminiAcceptsObjectProject() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let recorder = LocalTokenRequestRecorder()
    let client = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let data: Data
        if request.url?.absoluteString.hasSuffix("loadCodeAssist") == true {
            data = Data("{\"cloudaicompanionProject\":{\"projectId\":\"object-project\"}}".utf8)
        } else {
            data = Data(
                "{\"buckets\":[{\"modelId\":\"gemini-pro\",\"remainingFraction\":0.5}]}"
                    .utf8)
        }
        return (data, try successfulResponse(for: request))
    })
    let context = localTokenContext(
        now: now,
        readFile: geminiFileReader(
            credentials: geminiCredential(
                now: now, expiresAt: now.addingTimeInterval(3_600))),
        http: client)

    let snapshot = await resolveUsageSnapshot(
        strategies: GeminiCLIProvider.descriptor.makeStrategies(context), context: context)
    #expect(snapshot?.windows.first?.percent == 50)
    let requests = await recorder.snapshot()
    #expect(requests.count == 2)
    let quotaBody = try #require(requests.last?.httpBody)
    let object = try #require(
        JSONSerialization.jsonObject(with: quotaBody) as? [String: String])
    #expect(object == ["project": "object-project"])
}

@Test("Gemini missing, malformed, or expired credentials are unavailable and resolve nil")
func geminiInvalidCredentialsResolveNil() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let credentialFixtures: [String?] = [
        nil,
        "not json",
        geminiCredential(now: now, expiresAt: now),
    ]
    for credentials in credentialFixtures {
        let context = localTokenContext(
            now: now, readFile: geminiFileReader(credentials: credentials))
        let strategy = GeminiCLILocalTokenStrategy()
        #expect(await !strategy.isAvailable(context))
        #expect(
            await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    }
}

@Test("Gemini rejects API-key and Vertex AI settings without making a request")
func geminiRejectsUnsupportedAuthSettings() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    for selectedType in ["api-key", "gemini-api-key", "vertex-ai"] {
        let context = localTokenContext(
            now: now,
            readFile: geminiFileReader(
                credentials: geminiCredential(
                    now: now, expiresAt: now.addingTimeInterval(3_600)),
                settings:
                    "{\"security\":{\"auth\":{\"selectedType\":\"\(selectedType)\"}}}"))
        let strategy = GeminiCLILocalTokenStrategy()
        #expect(await !strategy.isAvailable(context))
        #expect(await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    }
}

@Test("Gemini malformed quota response resolves nil")
func geminiMalformedResponseResolvesNil() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let client = UsageHTTPClient(transport: { request in
        let data =
            request.url?.absoluteString.hasSuffix("loadCodeAssist") == true
            ? Data("{\"cloudaicompanionProject\":\"project\"}".utf8)
            : Data("malformed".utf8)
        return (data, try successfulResponse(for: request))
    })
    let context = localTokenContext(
        now: now,
        readFile: geminiFileReader(
            credentials: geminiCredential(
                now: now, expiresAt: now.addingTimeInterval(3_600))),
        http: client)
    #expect(
        await resolveUsageSnapshot(
            strategies: GeminiCLIProvider.descriptor.makeStrategies(context), context: context)
            == nil)
}

@Test("Gemini rejects non-finite expiry and out-of-range quota fractions")
func geminiRejectsInvalidNumericValues() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let invalidExpiry = localTokenContext(
        now: now,
        readFile: geminiFileReader(
            credentials: "{\"access_token\":\"secret\",\"expiry_date\":\"nan\"}"))
    #expect(await !GeminiCLILocalTokenStrategy().isAvailable(invalidExpiry))

    let invalidQuota = Data(
        "{\"buckets\":[{\"modelId\":\"gemini-pro\",\"remainingFraction\":1.1}]}".utf8)
    #expect(GeminiCLILocalTokenStrategy.parseQuotaResponse(invalidQuota, identity: nil) == nil)
}

@Test("Gemini transport errors are structurally redacted")
func geminiTransportErrorsAreRedacted() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let secret = "gemini-secret-that-must-not-escape"
    let client = UsageHTTPClient(transport: { _ in
        throw SecretBearingTransportError(secret: secret)
    })
    let context = localTokenContext(
        now: now,
        readFile: geminiFileReader(
            credentials: geminiCredential(
                now: now, accessToken: secret,
                expiresAt: now.addingTimeInterval(3_600))),
        http: client)
    do {
        _ = try await GeminiCLILocalTokenStrategy().fetch(context)
        Issue.record("Expected a transport error")
    } catch {
        #expect(error as? UsageHTTPError == .transportFailure)
        #expect(!String(describing: error).contains(secret))
    }
}

// MARK: - Kimi

@Test("Kimi fixture maps API numerators to percentages and sends the exact request")
func kimiFixtureMapsToSnapshotAndExactRequest() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let weeklyReset = "2033-05-18T04:00:00Z"
    let rateReset = "2033-05-18T05:00:00.000Z"
    let recorder = LocalTokenRequestRecorder()
    let client = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        let data = Data(
            """
            {
              "usage":{"limit":"1000","used":250,"reset_at":"\(weeklyReset)"},
              "limits":[{
                "window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                "detail":{"limit":100,"remaining":"25","resetTime":"\(rateReset)"}
              }]
            }
            """.utf8)
        return (data, try successfulResponse(for: request))
    })
    let context = localTokenContext(
        now: now,
        readFile: kimiFileReader(
            credentials: kimiCredential(
                expiresAt: String(now.addingTimeInterval(3_600).timeIntervalSince1970)),
            deviceID: "  existing-device-id\n"),
        http: client)

    let snapshot = await resolveUsageSnapshot(
        strategies: KimiProvider.descriptor.makeStrategies(context), context: context)
    #expect(snapshot?.providerID == .kimi)
    #expect(snapshot?.costLine == nil)
    #expect(snapshot?.identity == nil)
    #expect(
        snapshot?.windows
            == [
                UsageWindow(
                    label: "Weekly", percent: 25, tokens: nil,
                    resetsAt: UsageDateParsing.parseISO8601Fractional(weeklyReset)),
                UsageWindow(
                    label: "5h", percent: 75, tokens: nil,
                    resetsAt: UsageDateParsing.parseISO8601Fractional(rateReset)),
            ])

    let requests = await recorder.snapshot()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/usages")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-secret")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Rafu")
    #expect(request.value(forHTTPHeaderField: "X-Msh-Platform") == "kimi_code_cli")
    #expect(request.value(forHTTPHeaderField: "X-Msh-Device-Id") == "existing-device-id")
    #expect(request.httpBody == nil)
}

@Test("Kimi clamps source-derived percentages and uses conservative hour/day labels")
func kimiClampsPercentagesAndLabelsWindows() {
    let data = Data(
        """
        {
          "usage":{"limit":100,"used":150},
          "limits":[{
            "window":{"duration":2,"timeUnit":"TIME_UNIT_DAY"},
            "detail":{"limit":"10","remaining":"15"}
          }]
        }
        """.utf8)
    let snapshot = KimiLocalTokenStrategy.parseUsageResponse(data)
    #expect(snapshot?.windows[0].percent == 100)
    #expect(snapshot?.windows[1].label == "2d")
    #expect(snapshot?.windows[1].percent == 0)
    #expect(snapshot?.windows.allSatisfy { $0.tokens == nil } == true)
}

@Test("Kimi missing, malformed, or expired credentials are unavailable and resolve nil")
func kimiInvalidCredentialsResolveNil() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let credentialFixtures: [String?] = [
        nil,
        "not json",
        kimiCredential(expiresAt: String(now.addingTimeInterval(60).timeIntervalSince1970)),
    ]
    for credentials in credentialFixtures {
        let context = localTokenContext(
            now: now, readFile: kimiFileReader(credentials: credentials))
        let strategy = KimiLocalTokenStrategy()
        #expect(await !strategy.isAvailable(context))
        #expect(
            await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    }
}

@Test("Kimi malformed usage response resolves nil")
func kimiMalformedResponseResolvesNil() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let client = UsageHTTPClient(transport: { request in
        (Data("{\"usage\":{\"limit\":0}}".utf8), try successfulResponse(for: request))
    })
    let context = localTokenContext(
        now: now,
        readFile: kimiFileReader(
            credentials: kimiCredential(
                expiresAt: String(now.addingTimeInterval(3_600).timeIntervalSince1970))),
        http: client)
    #expect(
        await resolveUsageSnapshot(
            strategies: KimiProvider.descriptor.makeStrategies(context), context: context) == nil)
}

@Test("Kimi limit without used or remaining is malformed, not fabricated as zero percent")
func kimiMissingNumeratorResolvesNil() {
    let data = Data("{\"usage\":{\"limit\":100}}".utf8)
    #expect(KimiLocalTokenStrategy.parseUsageResponse(data) == nil)
}

@Test("Kimi transport errors are structurally redacted")
func kimiTransportErrorsAreRedacted() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let secret = "kimi-secret-that-must-not-escape"
    let client = UsageHTTPClient(transport: { _ in
        throw SecretBearingTransportError(secret: secret)
    })
    let context = localTokenContext(
        now: now,
        readFile: kimiFileReader(
            credentials: kimiCredential(
                accessToken: secret,
                expiresAt: String(now.addingTimeInterval(3_600).timeIntervalSince1970))),
        http: client)
    do {
        _ = try await KimiLocalTokenStrategy().fetch(context)
        Issue.record("Expected a transport error")
    } catch {
        #expect(error as? UsageHTTPError == .transportFailure)
        #expect(!String(describing: error).contains(secret))
    }
}

// MARK: - Copilot unavailable stub

@Test("Copilot local-token strategy is always unavailable and never calls transport")
func copilotLocalTokenStrategyNeverCallsTransport() async {
    let recorder = LocalTokenRequestRecorder()
    let client = UsageHTTPClient(transport: { request in
        await recorder.record(request)
        return (Data(), try successfulResponse(for: request))
    })
    let context = localTokenContext(
        readFile: { _ in "pretend-local-token" }, http: client)
    let strategy = CopilotUnavailableLocalTokenStrategy()
    #expect(await !strategy.isAvailable(context))
    #expect(await resolveUsageSnapshot(strategies: [strategy], context: context) == nil)
    #expect(await recorder.snapshot().isEmpty)

    do {
        _ = try await strategy.fetch(context)
        Issue.record("Expected noData")
    } catch {
        #expect(error as? UsageLocalDataError == .noData)
    }
    #expect(await recorder.snapshot().isEmpty)
}
