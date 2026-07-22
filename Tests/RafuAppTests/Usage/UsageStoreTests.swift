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
        // Test the visibility MECHANISM with a controlled pair — a real
        // descriptor (non-empty strategies) shows, a synthetic stub (empty
        // strategies) hides — NOT a frozen provider list. The exact visible
        // set grows as each Wn phase makes its providers' `makeStrategies`
        // non-empty, so asserting it against the full registry would break
        // on every phase merge (it was the sole cross-phase blocker for
        // W3/W4/W5).
        let stub = UsageProviderDescriptor(
            id: .warp, displayName: "Stub", authPattern: .cookieImport,
            disclosure: "", defaultEnabled: false, makeStrategies: { _ in [] })
        let model = UsageSettingsModel(
            descriptors: [ClaudeProvider.descriptor, stub],
            enableStore: UsageEnableStore(suiteName: suite))
        #expect(model.visibleRows.map(\.id) == [.claude])

        // The always-real local providers stay visible against the full
        // registry no matter which phases have landed.
        let full = UsageSettingsModel(
            descriptors: UsageProviderRegistry.all,
            enableStore: UsageEnableStore(suiteName: suite))
        #expect(full.visibleRows.map(\.id).contains(.claude))
        #expect(full.visibleRows.map(\.id).contains(.codex))
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
