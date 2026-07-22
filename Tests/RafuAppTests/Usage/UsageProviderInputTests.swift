import Foundation
import Testing

@testable import RafuApp

private actor UsageInputFixture {
    private var credentials: [UsageProviderID: String]
    private var importedCookies: Set<UsageProviderID>
    private var nextCookieImportResult: UsageCookieImportResult
    private var nextAPIKeyTestResult: UsageAPIKeyTestResult
    private var testedCredentials: [UsageProviderID: String] = [:]
    private var cookieImportCalls: [(UsageProviderID, Browser)] = []

    init(
        credentials: [UsageProviderID: String] = [:],
        importedCookies: Set<UsageProviderID> = [],
        cookieImportResult: UsageCookieImportResult = .noMatchingCookies,
        apiKeyTestResult: UsageAPIKeyTestResult = .failed
    ) {
        self.credentials = credentials
        self.importedCookies = importedCookies
        nextCookieImportResult = cookieImportResult
        nextAPIKeyTestResult = apiKeyTestResult
    }

    func loadCredential(_ id: UsageProviderID) -> String? {
        credentials[id]
    }

    func writeCredential(_ value: String, for id: UsageProviderID) {
        credentials[id] = value
    }

    func removeCredential(_ id: UsageProviderID) {
        credentials[id] = nil
    }

    func testAPIKey(_ id: UsageProviderID, credential: String) -> UsageAPIKeyTestResult {
        testedCredentials[id] = credential
        return nextAPIKeyTestResult
    }

    func hasImportedCookie(_ id: UsageProviderID) -> Bool {
        importedCookies.contains(id)
    }

    func importCookies(_ id: UsageProviderID, browser: Browser) -> UsageCookieImportResult {
        cookieImportCalls.append((id, browser))
        if case .imported = nextCookieImportResult {
            importedCookies.insert(id)
        }
        return nextCookieImportResult
    }

    func removeCookies(_ id: UsageProviderID) {
        importedCookies.remove(id)
    }

    func setCookieImportResult(_ result: UsageCookieImportResult) {
        nextCookieImportResult = result
    }

    func credential(for id: UsageProviderID) -> String? {
        credentials[id]
    }

    func testedCredential(for id: UsageProviderID) -> String? {
        testedCredentials[id]
    }

    func cookieImportCallCount() -> Int {
        cookieImportCalls.count
    }
}

private actor UsageTestRequestRecorder {
    private var authorizationValues: [String?] = []

    func record(_ request: URLRequest) {
        authorizationValues.append(request.value(forHTTPHeaderField: "Authorization"))
    }

    func values() -> [String?] {
        authorizationValues
    }
}

@MainActor
private func inputClient(_ fixture: UsageInputFixture) -> UsageProviderInputClient {
    UsageProviderInputClient(
        loadCredential: { id in await fixture.loadCredential(id) },
        writeCredential: { value, id in await fixture.writeCredential(value, for: id) },
        removeCredential: { id in await fixture.removeCredential(id) },
        testAPIKey: { id, credential, _ in
            await fixture.testAPIKey(id, credential: credential)
        },
        hasImportedCookie: { id in await fixture.hasImportedCookie(id) },
        importCookies: { id, browser in
            await fixture.importCookies(id, browser: browser)
        },
        removeCookies: { id in await fixture.removeCookies(id) })
}

private func isolatedUsageInputSuite() -> String {
    "UsageProviderInputTests.\(UUID().uuidString)"
}

@MainActor
@Test("Usage Settings exposes secure-key controls for six providers and browser import for three")
func usageSettingsAuthPatternRoster() {
    let suite = isolatedUsageInputSuite()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let model = UsageSettingsModel(
        descriptors: UsageProviderRegistry.all,
        enableStore: UsageEnableStore(suiteName: suite),
        inputClient: inputClient(UsageInputFixture()))

    let apiKeyIDs = model.visibleRows.compactMap { row -> UsageProviderID? in
        guard case .apiKey = row.authPattern else { return nil }
        return row.id
    }
    let cookieImportIDs = model.visibleRows.compactMap { row -> UsageProviderID? in
        guard case .cookieImport = row.authPattern else { return nil }
        return row.id
    }

    #expect(apiKeyIDs == [.cline, .kiloCode, .amp, .openRouter, .warp, .qwen])
    #expect(cookieImportIDs == [.grokBuild, .factoryDroid, .qoder])
}

@Test("Cookie import catalog stays provider-scoped and region-aware")
func cookieImportCatalogIsBounded() throws {
    let grok = try #require(UsageCookieImportCatalog.request(for: .grokBuild))
    #expect(grok.domains == ["grok.com"])
    #expect(grok.names == ["sso", "sso-rw"])

    let factory = try #require(UsageCookieImportCatalog.request(for: .factoryDroid))
    #expect(factory.domains == ["factory.ai", "app.factory.ai", "auth.factory.ai"])
    #expect(factory.names == UsageCookieImportCatalog.factoryDroidCookieNames)

    let qoderInternational = try #require(
        UsageCookieImportCatalog.request(for: .qoder, qoderRegion: .international))
    #expect(qoderInternational.domains == ["qoder.com", "www.qoder.com"])
    #expect(qoderInternational.names == nil)

    let qoderChina = try #require(
        UsageCookieImportCatalog.request(for: .qoder, qoderRegion: .chinaMainland))
    #expect(qoderChina.domains == ["qoder.com.cn", "www.qoder.com.cn"])
    #expect(UsageCookieImportCatalog.request(for: .cline) == nil)
}

@MainActor
@Test("API-key Test stores the trimmed key, runs one injected fetch, and reports success")
func apiKeyTestStoresAndFetches() async {
    let suite = isolatedUsageInputSuite()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let fixture = UsageInputFixture(apiKeyTestResult: .succeeded(identity: nil))
    let model = UsageSettingsModel(
        descriptors: [ClineProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        inputClient: inputClient(fixture))

    await model.loadInputStatuses()
    #expect(model.apiKeyState(for: .cline) == .idle)
    #expect(!model.hasStoredAPIKey(for: .cline))

    await model.testAPIKey("  test-secret  ", for: .cline)

    #expect(await fixture.credential(for: .cline) == "test-secret")
    #expect(await fixture.testedCredential(for: .cline) == "test-secret")
    #expect(model.hasStoredAPIKey(for: .cline))
    #expect(model.apiKeyState(for: .cline) == .succeeded)
    #expect(!model.isEnabled(.cline))

    await model.removeAPIKey(for: .cline)

    #expect(await fixture.credential(for: .cline) == nil)
    #expect(!model.hasStoredAPIKey(for: .cline))
    #expect(model.apiKeyState(for: .cline) == .idle)
}

@Test("Production API-key test service performs one credentialed provider fetch")
func apiKeyTestServicePerformsOneFetch() async throws {
    let recorder = UsageTestRequestRecorder()
    let responseData = Data(
        #"{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":42,"resetsAt":null}]}}"#
            .utf8)
    let http = UsageHTTPClient { request in
        await recorder.record(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
        return (responseData, response)
    }
    let service = UsageAPIKeyTestService(http: http)

    let result = await service.test(
        .cline, credential: "fixture-secret", now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(result == .succeeded(identity: nil))
    #expect(await recorder.values() == ["Bearer fixture-secret"])
}

@MainActor
@Test("API-key Test refuses an empty field when no Rafu Keychain item exists")
func apiKeyTestRequiresCredential() async {
    let suite = isolatedUsageInputSuite()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let fixture = UsageInputFixture(apiKeyTestResult: .succeeded(identity: nil))
    let model = UsageSettingsModel(
        descriptors: [ClineProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        inputClient: inputClient(fixture))

    await model.loadInputStatuses()
    await model.testAPIKey("", for: .cline)

    #expect(model.apiKeyState(for: .cline) == .failed(.keyRequired))
    #expect(await fixture.testedCredential(for: .cline) == nil)
}

@MainActor
@Test("API-key input rejects control characters before Keychain or network use")
func apiKeyInputRejectsControlCharacters() async {
    let suite = isolatedUsageInputSuite()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let fixture = UsageInputFixture(apiKeyTestResult: .succeeded(identity: nil))
    let model = UsageSettingsModel(
        descriptors: [ClineProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        inputClient: inputClient(fixture))

    await model.loadInputStatuses()
    await model.testAPIKey("secret\nInjected: value", for: .cline)

    #expect(model.apiKeyState(for: .cline) == .failed(.invalidKey))
    #expect(await fixture.credential(for: .cline) == nil)
    #expect(await fixture.testedCredential(for: .cline) == nil)
}

@MainActor
@Test("Cookie import preserves Safari Full Disk Access as a typed Settings state")
func cookieImportSurfacesFullDiskAccessGuidance() async {
    let suite = isolatedUsageInputSuite()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let fixture = UsageInputFixture(cookieImportResult: .needsFullDiskAccess)
    let model = UsageSettingsModel(
        descriptors: [GrokBuildProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        inputClient: inputClient(fixture))

    await model.loadInputStatuses()
    await model.importCookies(for: .grokBuild, from: .safari)

    #expect(model.cookieState(for: .grokBuild) == .failed(.needsFullDiskAccess))
    #expect(!model.hasImportedCookie(for: .grokBuild))
    #expect(await fixture.cookieImportCallCount() == 1)
}

@MainActor
@Test("Successful cookie import and explicit removal update only redacted presence state")
func cookieImportAndRemovalRoundTrip() async {
    let suite = isolatedUsageInputSuite()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let fixture = UsageInputFixture(cookieImportResult: .imported(browser: .firefox))
    let model = UsageSettingsModel(
        descriptors: [FactoryDroidProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        inputClient: inputClient(fixture))

    await model.loadInputStatuses()
    await model.importCookies(for: .factoryDroid, from: .firefox)

    #expect(model.hasImportedCookie(for: .factoryDroid))
    #expect(model.cookieState(for: .factoryDroid) == .imported(.firefox))

    await model.removeCookies(for: .factoryDroid)

    #expect(!model.hasImportedCookie(for: .factoryDroid))
    #expect(model.cookieState(for: .factoryDroid) == .idle)
}

@Test("Production context composes the cookie cache seam into provider lookups")
func productionContextUsesCookieHeaderClosure() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let context = UsageRegistryReader.productionContext(
        now,
        cookieHeader: { id in id == .grokBuild ? "sso=fixture" : nil })

    #expect(context.now == now)
    #expect(context.cookieHeader(.grokBuild) == "sso=fixture")
    #expect(context.cookieHeader(.factoryDroid) == nil)
}
