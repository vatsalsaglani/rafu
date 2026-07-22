import Foundation
import Testing

@testable import RafuApp

/// usage-providers/W0-shim.md `UsageStores`: `UsageEnableStore`'s
/// per-provider default-from-descriptor behavior, `UsageStripOrderStore`'s
/// default/round-trip, and (added once `NotchCompanionModel`/
/// `NotchCompanionView` migrate in the companion stage) `UsageDisplayPolicy`
/// 's pure derivations. Every store test injects its own UUID-suffixed
/// suite name — never `.standard` — mirroring
/// `NotchCompanionPreferenceStoreTests`'s isolation discipline, and cleans
/// that suite up afterward so no state leaks between tests.

private func isolatedSuiteName() -> String {
    "UsageStoreTests.\(UUID().uuidString)"
}

private func withIsolatedSuite<T>(_ body: (String) -> T) -> T {
    let name = isolatedSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: name) }
    return body(name)
}

// MARK: - UsageEnableStore

@Test("UsageEnableStore: an unset provider reads back the caller-supplied default")
func enableStoreDefaultsFromCaller() {
    withIsolatedSuite { suite in
        let store = UsageEnableStore(suiteName: suite)
        #expect(store.isEnabled(.claude, default: true) == true)
        #expect(store.isEnabled(.cline, default: false) == false)
    }
}

@Test("UsageEnableStore: setEnabled overrides the default and round-trips")
func enableStoreSetAndReadBack() {
    withIsolatedSuite { suite in
        let store = UsageEnableStore(suiteName: suite)
        store.setEnabled(true, for: .cline)
        #expect(store.isEnabled(.cline, default: false) == true)
        store.setEnabled(false, for: .claude)
        #expect(store.isEnabled(.claude, default: true) == false)
    }
}

@Test("UsageEnableStore: every registry descriptor's default is honored when unset")
func enableStoreHonorsEveryDescriptorDefault() {
    withIsolatedSuite { suite in
        let store = UsageEnableStore(suiteName: suite)
        for descriptor in UsageProviderRegistry.all {
            #expect(
                store.isEnabled(descriptor.id, default: descriptor.defaultEnabled)
                    == descriptor.defaultEnabled)
        }
    }
}

// MARK: - Network consent and external credential envelope

@Test("UsageNetworkConsentStore defaults false independently from local enablement")
func networkConsentDefaultsFalseAndIsIndependent() {
    withIsolatedSuite { suite in
        let consent = UsageNetworkConsentStore(suiteName: suite)
        let enable = UsageEnableStore(suiteName: suite)

        #expect(enable.isEnabled(.claude, default: true))
        #expect(!consent.hasConsent(for: .claude))

        consent.setConsent(true, for: .claude)
        #expect(consent.hasConsent(for: .claude))
        #expect(enable.isEnabled(.claude, default: true))

        enable.setEnabled(false, for: .claude)
        #expect(!enable.isEnabled(.claude, default: true))
        #expect(consent.hasConsent(for: .claude))
    }
}

@Test("External credential envelope encodes only the three allowed fields")
func externalCredentialEnvelopeOmitsForbiddenMaterial() throws {
    let envelope = UsageExternalCredentialEnvelope(
        accessToken: "access-token",
        accountID: "account-123",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
    let encoded = try #require(envelope.encoded())
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])

    #expect(Set(object.keys) == ["accessToken", "accountID", "expiresAt"])
    #expect(!encoded.contains("refresh"))
    #expect(!encoded.contains("idToken"))
    #expect(!encoded.contains("scopes"))
    #expect(!encoded.contains("metadata"))
}

@Test("External credential envelope rejects malformed, unknown-key, and oversized values")
func externalCredentialEnvelopeRejectsInvalidValues() {
    #expect(UsageExternalCredentialEnvelope.parse("not-json") == nil)
    #expect(
        UsageExternalCredentialEnvelope.parse(
            #"{"accessToken":"token","refreshToken":"forbidden"}"#) == nil)
    #expect(
        UsageExternalCredentialEnvelope(
            accessToken: String(
                repeating: "x", count: UsageExternalCredentialEnvelope.maximumEncodedBytes),
            accountID: nil,
            expiresAt: nil
        ).encoded() == nil)
    #expect(
        UsageExternalCredentialParser.codex(
            contents: String(
                repeating: "x", count: UsageExternalCredentialParser.maximumSourceBytes + 1))
            == nil)
}

@Test("Transient external cache rejects malformed and oversized envelope strings")
func transientExternalCacheIsBounded() async {
    let store = UsageCredentialStore(servicePrefix: "test.transient.\(UUID().uuidString)")
    #expect(await store.setTransientExternalCredential("not-json", for: .claude) == false)
    #expect(
        await store.setTransientExternalCredential(
            String(
                repeating: "x", count: UsageExternalCredentialEnvelope.maximumEncodedBytes + 1),
            for: .claude) == false)
    #expect(await store.transientExternalCredential(for: .claude) == nil)
}

// MARK: - UsageStripOrderStore

@Test("UsageStripOrderStore: an unset order defaults to [claude, codex]")
func stripOrderStoreDefault() {
    withIsolatedSuite { suite in
        let store = UsageStripOrderStore(suiteName: suite)
        #expect(store.order() == [.claude, .codex])
    }
}

@Test("UsageStripOrderStore: setOrder round-trips the exact order, including reordering")
func stripOrderStoreRoundTrips() {
    withIsolatedSuite { suite in
        let store = UsageStripOrderStore(suiteName: suite)
        store.setOrder([.codex, .cursor, .claude])
        #expect(store.order() == [.codex, .cursor, .claude])
    }
}

@Test(
    "UsageStripOrderStore: a stored value with no recognizable provider IDs falls back to the default"
)
func stripOrderStoreFallsBackOnUnrecognizedIDs() {
    withIsolatedSuite { suite in
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(["not-a-real-provider"], forKey: UsageStripOrderStore.defaultsKey)
        let store = UsageStripOrderStore(suiteName: suite)
        #expect(store.order() == UsageStripOrderStore.defaultOrder)
    }
}

// MARK: - UsageSettingsModel (Settings "Usage" tab)

@MainActor
@Test(
    "UsageSettingsModel: only descriptors with at least one strategy against the probe are visible")
func settingsModelHidesStubProviders() {
    withIsolatedSuite { suite in
        let model = UsageSettingsModel(
            descriptors: UsageProviderRegistry.all, enableStore: UsageEnableStore(suiteName: suite))
        #expect(model.visibleRows.map(\.id) == [.claude, .codex])
    }
}

@MainActor
@Test("UsageSettingsModel: isEnabled reads the descriptor default until explicitly changed")
func settingsModelDefaultsFromDescriptor() {
    withIsolatedSuite { suite in
        let model = UsageSettingsModel(
            descriptors: [ClaudeProvider.descriptor],
            enableStore: UsageEnableStore(suiteName: suite))
        #expect(model.isEnabled(.claude) == true)
    }
}

@MainActor
@Test("UsageSettingsModel: setEnabled updates both in-memory state and the persisted store")
func settingsModelSetEnabledPersists() {
    withIsolatedSuite { suite in
        let store = UsageEnableStore(suiteName: suite)
        let model = UsageSettingsModel(descriptors: [ClaudeProvider.descriptor], enableStore: store)
        model.setEnabled(false, for: .claude)
        #expect(model.isEnabled(.claude) == false)
        #expect(store.isEnabled(.claude, default: true) == false)
    }
}

private actor SettingsConnectionGate {
    private var resultContinuation: CheckedContinuation<UsageOAuthCredentialLoadResult, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var callCount = 0

    func load() async -> UsageOAuthCredentialLoadResult {
        callCount += 1
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finish(_ result: UsageOAuthCredentialLoadResult) {
        guard let resultContinuation else {
            Issue.record("connection loader was not waiting")
            return
        }
        self.resultContinuation = nil
        resultContinuation.resume(returning: result)
    }
}

@MainActor
@Test("UsageSettingsModel exposes connecting before await and rejects duplicate Connect actions")
func settingsModelConnectStateAndDuplicateGuard() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let suite = isolatedSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let gate = SettingsConnectionGate()
    let credentialStore = UsageCredentialStore(servicePrefix: "test.settings.\(UUID().uuidString)")
    let connector = UsageOAuthConnector(
        credentialLoader: { _, _ in await gate.load() },
        credentialStore: credentialStore,
        consentStore: UsageNetworkConsentStore(suiteName: suite))
    let model = UsageSettingsModel(
        descriptors: [ClaudeProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        oauthConnector: connector)
    let envelope = UsageExternalCredentialEnvelope(
        accessToken: "token", accountID: nil,
        expiresAt: now.addingTimeInterval(3_600))

    let firstConnect = Task { await model.connect(.claude, now: now) }
    await gate.waitUntilStarted()
    #expect(model.connectionState(for: .claude) == .connecting)

    await model.connect(.claude, now: now)
    #expect(await gate.callCount == 1)

    await gate.finish(.credential(envelope, cacheTransiently: false))
    await firstConnect.value
    #expect(model.connectionState(for: .claude) == .connected)
    #expect(model.isEnabled(.claude))

    await model.disconnect(.claude)
    #expect(model.connectionState(for: .claude) == .disconnected)
    #expect(model.isEnabled(.claude))
}

@MainActor
@Test("UsageSettingsModel maps a fixed connector failure into failed state")
func settingsModelFailedTransition() async {
    let suite = isolatedSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let connector = UsageOAuthConnector(
        credentialLoader: { _, _ in .failed(.credentialAccessDenied) },
        credentialStore: UsageCredentialStore(
            servicePrefix: "test.settings.\(UUID().uuidString)"),
        consentStore: UsageNetworkConsentStore(suiteName: suite))
    let model = UsageSettingsModel(
        descriptors: [ClaudeProvider.descriptor],
        enableStore: UsageEnableStore(suiteName: suite),
        oauthConnector: connector)

    await model.connect(.claude)

    #expect(model.connectionState(for: .claude) == .failed(.credentialAccessDenied))
    #expect(model.isEnabled(.claude))
}
