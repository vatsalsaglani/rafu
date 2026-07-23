import Foundation
import Synchronization
import Testing

@testable import RafuApp

/// conductor/C0-shim.md increment 4: the registry-driven Agents settings
/// surface, the `.runs` navigator case, and `WorkspaceSession`'s run seams.
///
/// Every store test injects a UUID-suffixed suite name — never `.standard` —
/// mirroring `UsageStoreTests`'s isolation discipline, and cleans that suite
/// up afterwards so nothing leaks between tests or into the developer's real
/// defaults.

private func isolatedSuiteName() -> String {
    "rafu.tests.\(UUID().uuidString)"
}

private func withIsolatedSuite<T>(_ body: (String) throws -> T) rethrows -> T {
    let name = isolatedSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: name) }
    return try body(name)
}

/// `isolated (any Actor)? = #isolation` keeps the caller's actor (every async
/// user here is `@MainActor`), so the closure is never *sent* across an
/// isolation boundary and Swift 6 strict concurrency stays satisfied without
/// weakening anything.
private func withIsolatedSuiteAsync<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (String) async throws -> T
) async rethrows -> T {
    let name = isolatedSuiteName()
    defer { UserDefaults().removePersistentDomain(forName: name) }
    return try await body(name)
}

/// Counts every call that would touch the machine, so a test can prove that
/// merely CONSTRUCTING the settings model probes nothing.
private final class CountingAdapter: ConductorCLIAdapter, Sendable {
    struct Counts: Equatable {
        var probe = 0
        var authStatus = 0
        var curatedModels = 0
        var discoverModels = 0
    }

    let id: ConductorCLIID
    let defaultEnabled: Bool
    let supportsModelDiscovery: Bool
    private let discovery: [ConductorModelChoice]?
    private let state = Mutex(Counts())

    init(
        id: ConductorCLIID,
        defaultEnabled: Bool = true,
        discovery: [ConductorModelChoice]? = nil
    ) {
        self.id = id
        self.defaultEnabled = defaultEnabled
        self.discovery = discovery
        supportsModelDiscovery = discovery != nil
    }

    var counts: Counts { state.withLock { $0 } }

    func probe() async -> AdapterProbe {
        state.withLock { $0.probe += 1 }
        return AdapterProbe(
            installed: true, executableURL: URL(fileURLWithPath: "/bin/echo"), version: "9.9")
    }

    func authStatus() async -> AdapterAuthStatus {
        state.withLock { $0.authStatus += 1 }
        return .notAuthenticated(hint: "run `codex login` in a terminal")
    }

    func curatedModels() -> [ConductorModelChoice] {
        state.withLock { $0.curatedModels += 1 }
        return [ConductorModelChoice(id: "curated-1", displayName: "Curated 1", source: .curated)]
    }

    func discoverModels() async -> [ConductorModelChoice]? {
        state.withLock { $0.discoverModels += 1 }
        return discovery
    }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        AdapterInvocation(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [prompt],
            environment: RafuConductorEnvironment.childEnvironment(
                runDirectory: runDirectory, handoffDirectory: handoffDirectory))
    }
}

// MARK: - Stores

@Test("ConductorEnableStore: an unset adapter reads back the caller-supplied default")
func enableStoreHonorsTheAdapterDefault() {
    withIsolatedSuite { suite in
        let store = ConductorEnableStore(suiteName: suite)
        #expect(store.isEnabled(.claudeCode, default: true))
        #expect(!store.isEnabled(.cursor, default: false))
        store.setEnabled(false, for: .claudeCode)
        #expect(!store.isEnabled(.claudeCode, default: true))
        #expect(ConductorEnableStore.key(for: .claudeCode) == "conductorAdapterEnabled.claudeCode")
    }
}

@Test("ConductorDefaultModelStore round-trips a model id and clears on empty")
func defaultModelStoreRoundTrips() {
    withIsolatedSuite { suite in
        let store = ConductorDefaultModelStore(suiteName: suite)
        #expect(store.defaultModel(for: .codex).isEmpty)
        store.setDefaultModel("gpt-5", for: .codex)
        #expect(store.defaultModel(for: .codex) == "gpt-5")
        store.setDefaultModel("   ", for: .codex)
        #expect(store.defaultModel(for: .codex).isEmpty)
        #expect(
            ConductorDefaultModelStore.key(for: .codex) == "conductorAdapterDefaultModel.codex")
    }
}

// MARK: - Settings model

@Test("The Agents tab builds one row per registry adapter, in registry order")
@MainActor
func settingsRowsFollowTheRegistry() {
    withIsolatedSuite { suite in
        let model = ConductorSettingsModel(
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))
        #expect(model.rows.map(\.id) == ConductorAdapterRegistry.all.map(\.id))
        #expect(model.rows.map(\.id) == ConductorCLIID.allCases)
        #expect(model.rows.map(\.displayName) == ConductorCLIID.allCases.map(\.displayName))
    }
}

@Test("Constructing the Agents model probes nothing; probes run only on explicit refresh")
@MainActor
func settingsModelDoesNoWorkOnConstruction() async {
    await withIsolatedSuiteAsync { suite in
        let adapter = CountingAdapter(id: .codex)
        let model = ConductorSettingsModel(
            adapters: [adapter],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        // Opening Settings must never probe the user's machine behind their
        // back: no binary discovery, no auth check, no model listing.
        #expect(adapter.counts.probe == 0)
        #expect(adapter.counts.authStatus == 0)
        #expect(adapter.counts.discoverModels == 0)
        // `curatedModels()` is contractually pure, so building rows may call
        // it — exactly once per adapter.
        #expect(adapter.counts.curatedModels == 1)

        await model.refreshStatuses()
        #expect(adapter.counts.probe == 1)
        #expect(adapter.counts.authStatus == 1)
        #expect(adapter.counts.discoverModels == 0)
        // A second refresh is a no-op; the tab's `.task` can fire again.
        await model.refreshStatuses()
        #expect(adapter.counts.probe == 1)
    }
}

@Test("The enable toggle persists under conductorAdapterEnabled.<id> and honors the default")
@MainActor
func settingsEnableTogglePersists() {
    withIsolatedSuite { suite in
        let defaults = UserDefaults(suiteName: suite)
        let model = ConductorSettingsModel(
            adapters: [CountingAdapter(id: .cline, defaultEnabled: false)],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        // Unset key ⇒ the adapter's own default.
        #expect(!model.isEnabled(.cline))
        model.setEnabled(true, for: .cline)
        #expect(model.isEnabled(.cline))
        #expect(defaults?.bool(forKey: "conductorAdapterEnabled.cline") == true)

        // A fresh model over the same suite reads the persisted value.
        let reloaded = ConductorSettingsModel(
            adapters: [CountingAdapter(id: .cline, defaultEnabled: false)],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))
        #expect(reloaded.isEnabled(.cline))
    }
}

@Test("Default-model selection persists, and free-text entry resolves to ModelSource.custom")
@MainActor
func settingsDefaultModelSelection() {
    withIsolatedSuite { suite in
        let defaults = UserDefaults(suiteName: suite)
        let model = ConductorSettingsModel(
            adapters: [CountingAdapter(id: .kimi)],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        #expect(model.resolvedModelChoice(for: .kimi) == nil)

        model.setDefaultModel("curated-1", for: .kimi)
        #expect(model.resolvedModelChoice(for: .kimi)?.source == .curated)
        #expect(defaults?.string(forKey: "conductorAdapterDefaultModel.kimi") == "curated-1")

        // A hand-typed identifier is reported honestly as custom — Rafu
        // makes no claim that it exists.
        model.setDefaultModel("some-unreleased-model", for: .kimi)
        let resolved = model.resolvedModelChoice(for: .kimi)
        #expect(resolved?.source == .custom)
        #expect(resolved?.id == "some-unreleased-model")
        #expect(resolved?.displayName == "some-unreleased-model")
    }
}

@Test("Refresh models appends discovered choices, and reports an unsupported CLI honestly")
@MainActor
func settingsRefreshModels() async {
    await withIsolatedSuiteAsync { suite in
        let discovered = ConductorModelChoice(
            id: "listed-1", displayName: "Listed 1", source: .discovered)
        let listing = CountingAdapter(id: .openCode, discovery: [discovered])
        let noListing = CountingAdapter(id: .cursor, discovery: nil)
        let model = ConductorSettingsModel(
            adapters: [listing, noListing],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        #expect(model.rows.map(\.supportsModelDiscovery) == [true, false])
        #expect(model.availableModels(for: .openCode).map(\.id) == ["curated-1"])

        await model.refreshModels(for: .openCode)
        #expect(model.availableModels(for: .openCode).map(\.id) == ["curated-1", "listed-1"])
        #expect(model.modelRefreshState(for: .openCode) == .idle)

        await model.refreshModels(for: .cursor)
        #expect(model.modelRefreshState(for: .cursor) == .unsupported)
        #expect(model.availableModels(for: .cursor).map(\.id) == ["curated-1"])
    }
}

@Test("A CANCELLED model refresh returns to idle, never claiming the CLI has no listing")
@MainActor
func settingsCancelledRefreshDoesNotClaimUnsupported() async {
    await withIsolatedSuiteAsync { suite in
        // The Settings row cancels its refresh task when it disappears, and
        // an adapter that honors cancellation returns nil. Landing that in
        // `.unsupported` would tell the user "this CLI has no model-listing
        // command" purely because they navigated away.
        let adapter = CountingAdapter(
            id: .openCode,
            discovery: [
                ConductorModelChoice(id: "listed-1", displayName: "Listed 1", source: .discovered)
            ])
        let model = ConductorSettingsModel(
            adapters: [adapter],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        // Cancelling before the child task's first resumption is
        // deterministic: this test is already on the main actor, so the
        // child cannot start until this function suspends at `await`.
        let task = Task { @MainActor in await model.refreshModels(for: .openCode) }
        task.cancel()
        await task.value

        #expect(model.modelRefreshState(for: .openCode) == .idle)
        // And an honest, uncancelled "no listing command" still reports
        // itself.
        let noListing = CountingAdapter(id: .cursor, discovery: nil)
        let second = ConductorSettingsModel(
            adapters: [noListing],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))
        await second.refreshModels(for: .cursor)
        #expect(second.modelRefreshState(for: .cursor) == .unsupported)
    }
}

@Test("The auth line reproduces the adapter's notAuthenticated hint verbatim")
@MainActor
func settingsAuthLineIsVerbatim() async {
    await withIsolatedSuiteAsync { suite in
        let model = ConductorSettingsModel(
            adapters: [CountingAdapter(id: .codex)],
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))

        #expect(model.authStatusText(for: .codex).contains("unknown"))
        await model.refreshStatuses()
        // Verbatim: Rafu never rewrites or supplements the CLI's own
        // instruction, and never collects the credential itself.
        #expect(model.authStatusText(for: .codex) == "run `codex login` in a terminal")
        #expect(model.installStatusText(for: .codex).contains("9.9"))
    }
}

@Test("No Agents row property is credential-shaped")
@MainActor
func settingsRowCarriesNoCredential() {
    withIsolatedSuite { suite in
        let model = ConductorSettingsModel(
            enableStore: ConductorEnableStore(suiteName: suite),
            defaultModelStore: ConductorDefaultModelStore(suiteName: suite))
        let row = model.rows[0]
        let forbidden = ["token", "secret", "key", "password", "cookie", "credential", "auth"]
        for child in Mirror(reflecting: row).children {
            let label = (child.label ?? "").lowercased()
            #expect(!forbidden.contains { label.contains($0) })
        }
        // And the row's values are plain preference data.
        #expect(row.displayName == ConductorCLIID.allCases[0].displayName)
    }
}

// MARK: - Navigator case and session seams

@Test("The .runs navigator mode encodes as \"runs\" and round-trips")
func runsNavigatorModeRoundTrips() throws {
    let encoded = try JSONEncoder().encode(WorkspaceNavigatorMode.runs)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"runs\"")
    #expect(try JSONDecoder().decode(WorkspaceNavigatorMode.self, from: encoded) == .runs)
    #expect(WorkspaceNavigatorMode.runs.title == "Runs")
    #expect(!WorkspaceNavigatorMode.runs.symbolName.isEmpty)
    #expect(WorkspaceNavigatorMode.allCases.count == 5)
}

@Test("An unknown navigator mode still falls back to .files after adding .runs")
func unknownNavigatorModeStillFallsBack() throws {
    let data = Data("\"totally-unknown\"".utf8)
    #expect(try JSONDecoder().decode(WorkspaceNavigatorMode.self, from: data) == .files)
}

@Test("openConductorRun records the selection and reveals the Runs navigator")
@MainActor
func openConductorRunRevealsThePanel() {
    let session = WorkspaceSession()
    #expect(session.conductorRuns.isEmpty)
    #expect(session.selectedConductorRunID == nil)

    session.openConductorRun("20260724-101500")
    #expect(session.selectedConductorRunID == "20260724-101500")
    #expect(session.navigatorMode == .runs)

    // The run controller is pre-landed per window so C1 fills bodies without
    // adding a stored property to this shared file. Constructing a session
    // starts nothing and attaches no store.
    #expect(session.conductorRunController.state == .idle)
    #expect(session.conductorRunController.manifest == nil)
    #expect(session.conductorRunController.store == nil)
    #expect(session.conductorRunController.adapters.map(\.id) == ConductorCLIID.allCases)
    // Two windows never share one run engine.
    #expect(session.conductorRunController !== WorkspaceSession().conductorRunController)

    // The shared rail toggle still works for the new case.
    session.toggleUtilityPane(.runs)
    #expect(session.navigatorMode == .files)
}
