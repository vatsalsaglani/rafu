import SwiftUI

/// Settings > Agents (conductor/C0-shim.md, "Settings surface"):
/// registry-driven rows, one per `ConductorAdapterRegistry` adapter — install
/// status, version, delegated auth hint, enable toggle, and a default-model
/// picker with free-text override.
///
/// No credentials are collected anywhere. Rafu never stores, reads, copies,
/// or proxies a provider credential for inference (ADR 0018); every row says
/// so, and signing in happens in the vendor's own CLI.
struct ConductorSettingsSection: View {
    @State private var model = ConductorSettingsModel()

    var body: some View {
        RafuSettingsSection {
            Text("Agent CLIs")
        } content: {
            if model.rows.isEmpty {
                RafuSettingsRow {
                    Text("No agent CLIs are available yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                        }
                        RafuSettingsRow {
                            ConductorAdapterRow(row: row, model: model)
                        }
                    }
                }
            }
        } footer: {
            Text(
                "Rafu runs the agent CLIs you already have installed, under your own subscriptions. It never stores, reads, or forwards a sign-in token — log in inside each CLI. Nothing runs until you start a run."
            )
        }
        .task {
            await model.refreshStatuses()
        }
    }
}

/// The Agents tab's state: registry rows plus the results of any explicit
/// refresh. Secret material never appears here because the Conductor holds
/// none — the only per-adapter values are an enable flag and a model id.
@MainActor
@Observable
final class ConductorSettingsModel {
    /// One adapter's row. Deliberately carries NO credential-shaped
    /// property; a test asserts that by name.
    struct Row: Identifiable {
        let id: ConductorCLIID
        let displayName: String
        let curatedModels: [ConductorModelChoice]
        let supportsModelDiscovery: Bool
        let defaultEnabled: Bool
    }

    /// Deliberately has NO `failed` case. `ConductorCLIAdapter
    /// .discoverModels()` returns `[ConductorModelChoice]?`, so it has
    /// exactly two outcomes — a list, or "this CLI has no listing command" —
    /// and no error channel to render. A `failed` case would be unreachable
    /// by construction, and unreachable UI state is how a build starts
    /// claiming things about the user's machine that nothing can produce.
    /// Giving C2–C4 a real probe-failure state is an ADAPTER CONTRACT change
    /// (throwing or `Result`-returning discovery in `ConductorCore.swift`),
    /// not a Settings change, so it belongs in the phase that needs it.
    enum RefreshState: Equatable {
        case idle
        case refreshing
        /// The CLI has no listing command.
        case unsupported
    }

    private(set) var rows: [Row] = []
    private(set) var probeByID: [ConductorCLIID: AdapterProbe] = [:]
    private(set) var authByID: [ConductorCLIID: AdapterAuthStatus] = [:]
    private(set) var modelRefreshStateByID: [ConductorCLIID: RefreshState] = [:]

    /// Discovery results now live in the app-wide cache rather than in this
    /// model, because the New Ensemble canvas needs the same answer and used
    /// to give a different one. This stays a read-through accessor so
    /// existing callers and tests keep working unchanged.
    var discoveredModelsByID: [ConductorCLIID: [ConductorModelChoice]] {
        Dictionary(
            rows.map { ($0.id, discoveredModels.models(for: $0.id)) },
            uniquingKeysWith: { first, _ in first }
        )
        .filter { !$0.value.isEmpty }
    }

    private let adapters: [any ConductorCLIAdapter]
    private let enableStore: ConductorEnableStore
    private let defaultModelStore: ConductorDefaultModelStore
    private let discoveredModels: ConductorDiscoveredModelCache
    private var enabledByID: [ConductorCLIID: Bool] = [:]
    private var defaultModelByID: [ConductorCLIID: String] = [:]
    private var didRefreshStatuses = false
    private var isRefreshingStatuses = false

    /// Construction performs NO filesystem, network, or Keychain access.
    /// `curatedModels()` is contractually pure, and `probe()`/`authStatus()`
    /// run only from `refreshStatuses()` — opening Settings must never probe
    /// the user's machine behind their back.
    init(
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        enableStore: ConductorEnableStore = ConductorEnableStore(),
        defaultModelStore: ConductorDefaultModelStore = ConductorDefaultModelStore(),
        discoveredModels: ConductorDiscoveredModelCache = .shared
    ) {
        self.adapters = adapters
        self.enableStore = enableStore
        self.defaultModelStore = defaultModelStore
        self.discoveredModels = discoveredModels
        rows = adapters.map { adapter in
            Row(
                id: adapter.id,
                displayName: adapter.id.displayName,
                curatedModels: adapter.curatedModels(),
                supportsModelDiscovery: adapter.supportsModelDiscovery,
                defaultEnabled: adapter.defaultEnabled)
        }
        for adapter in adapters {
            enabledByID[adapter.id] = enableStore.isEnabled(
                adapter.id, default: adapter.defaultEnabled)
            defaultModelByID[adapter.id] = defaultModelStore.defaultModel(for: adapter.id)
        }
    }

    // MARK: Enablement

    func isEnabled(_ id: ConductorCLIID) -> Bool {
        enabledByID[id] ?? rows.first { $0.id == id }?.defaultEnabled ?? false
    }

    func setEnabled(_ value: Bool, for id: ConductorCLIID) {
        enabledByID[id] = value
        enableStore.setEnabled(value, for: id)
    }

    func binding(for id: ConductorCLIID) -> Binding<Bool> {
        Binding(get: { self.isEnabled(id) }, set: { self.setEnabled($0, for: id) })
    }

    // MARK: Status

    /// Probes every adapter once, on explicit request (the tab's `.task`).
    func refreshStatuses() async {
        guard !didRefreshStatuses, !isRefreshingStatuses else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }
        for adapter in adapters {
            guard !Task.isCancelled else { return }
            probeByID[adapter.id] = await adapter.probe()
            guard !Task.isCancelled else { return }
            authByID[adapter.id] = await adapter.authStatus()
        }
        didRefreshStatuses = true
    }

    func installStatusText(for id: ConductorCLIID) -> String {
        guard let probe = probeByID[id] else { return "Checking for the CLI…" }
        guard probe.installed else {
            return "Not found on this Mac. Install the CLI to use it in a run."
        }
        let version = probe.version.map { " \($0)" } ?? ""
        return "Installed\(version) at \(probe.executableURL?.path ?? "an unknown path")."
    }

    /// Reproduces the adapter's own `notAuthenticated(hint:)` text VERBATIM —
    /// the hint is the adapter's instruction to the user (e.g. "run `codex
    /// login` in a terminal"), and Rafu never rewrites or supplements it.
    func authStatusText(for id: ConductorCLIID) -> String {
        switch authByID[id] ?? .unknown() {
        case .authenticated:
            "Signed in to this CLI. Rafu holds no token for it."
        case .notAuthenticated(let hint):
            hint
        case .unknown(let reason):
            // A CLI that cannot report sign-in headlessly says so plainly,
            // rather than leaving a bare shrug that reads like a failure.
            // Either way this never blocks a run — the CLI itself is the
            // authority at launch (ADR 0018 delegated auth).
            reason
                ?? "Sign-in status unknown — Rafu could not read it from this CLI. This does not block runs."
        }
    }

    // MARK: Default model

    func defaultModel(for id: ConductorCLIID) -> String {
        defaultModelByID[id] ?? ""
    }

    func setDefaultModel(_ value: String, for id: ConductorCLIID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultModelByID[id] = trimmed
        defaultModelStore.setDefaultModel(trimmed, for: id)
    }

    func defaultModelBinding(for id: ConductorCLIID) -> Binding<String> {
        Binding(get: { self.defaultModel(for: id) }, set: { self.setDefaultModel($0, for: id) })
    }

    /// Every model this adapter can offer right now: curated first, then
    /// anything a refresh discovered, deduplicated by id. The merge rule
    /// itself lives in `ConductorModelCatalog` because the New Ensemble
    /// canvas needs the same list for its own pickers.
    func availableModels(for id: ConductorCLIID) -> [ConductorModelChoice] {
        ConductorModelCatalog.merge(
            curated: rows.first { $0.id == id }?.curatedModels ?? [],
            discovered: discoveredModels.models(for: id))
    }

    /// Resolves the persisted string against what the adapter offers. A
    /// value the adapter never listed is honestly reported as `.custom` —
    /// Rafu makes no claim that a hand-typed model exists.
    func resolvedModelChoice(for id: ConductorCLIID) -> ConductorModelChoice? {
        ConductorModelCatalog.choice(for: defaultModel(for: id), in: availableModels(for: id))
    }

    func modelRefreshState(for id: ConductorCLIID) -> RefreshState {
        modelRefreshStateByID[id] ?? .idle
    }

    /// Explicit user action only — "Refresh models" runs the CLI's own
    /// listing command, which is real work on the user's machine.
    func refreshModels(for id: ConductorCLIID) async {
        guard let adapter = adapters.first(where: { $0.id == id }) else { return }
        guard modelRefreshState(for: id) != .refreshing else { return }
        modelRefreshStateByID[id] = .refreshing
        let discovery = await adapter.discoverModels()
        // The row cancels this task when it disappears, and an adapter that
        // honors cancellation returns `nil`. Reporting that as `.unsupported`
        // would tell the user "this CLI has no model-listing command" purely
        // because they navigated away — a false statement about their
        // machine. A cancelled refresh simply did not happen.
        guard !Task.isCancelled else {
            modelRefreshStateByID[id] = .idle
            return
        }
        guard let discovered = discovery else {
            modelRefreshStateByID[id] = .unsupported
            return
        }
        // Into the app-wide cache, so the New Ensemble canvas shows this same
        // list without ever having to run the CLI itself.
        discoveredModels.setModels(discovered, for: id)
        modelRefreshStateByID[id] = .idle
    }
}

private struct ConductorAdapterRow: View {
    let row: ConductorSettingsModel.Row
    let model: ConductorSettingsModel

    @State private var customModel = ""
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: model.binding(for: row.id)) {
                Text(row.displayName).font(.body.weight(.medium))
            }
            Text(model.installStatusText(for: row.id))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Install status: \(model.installStatusText(for: row.id))")
            Text(model.authStatusText(for: row.id))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sign-in status: \(model.authStatusText(for: row.id))")

            HStack(spacing: 8) {
                Picker("Default model", selection: model.defaultModelBinding(for: row.id)) {
                    Text(ConductorModelResolution.unsetLabel).tag("")
                    ForEach(model.availableModels(for: row.id)) { choice in
                        Text(choice.displayName).tag(choice.id)
                    }
                    if let resolved = model.resolvedModelChoice(for: row.id),
                        resolved.source == .custom
                    {
                        Text("\(resolved.displayName) (custom)").tag(resolved.id)
                    }
                }
                .accessibilityLabel("\(row.displayName) default model")
                if row.supportsModelDiscovery {
                    Button("Refresh models") {
                        refreshTask?.cancel()
                        refreshTask = Task { await model.refreshModels(for: row.id) }
                    }
                    .disabled(model.modelRefreshState(for: row.id) == .refreshing)
                    .accessibilityLabel("Refresh \(row.displayName) models")
                }
            }

            HStack(spacing: 8) {
                TextField("Custom model identifier", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(row.displayName) custom model identifier")
                    .onSubmit { applyCustomModel() }
                Button("Use") { applyCustomModel() }
                    .disabled(
                        customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityLabel("Use custom model for \(row.displayName)")
            }
            if model.modelRefreshState(for: row.id) == .unsupported {
                Text("This CLI has no model-listing command; enter one by hand instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .onDisappear { refreshTask?.cancel() }
    }

    private func applyCustomModel() {
        let trimmed = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.setDefaultModel(trimmed, for: row.id)
        customModel = ""
    }
}
