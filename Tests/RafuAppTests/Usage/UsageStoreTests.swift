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
