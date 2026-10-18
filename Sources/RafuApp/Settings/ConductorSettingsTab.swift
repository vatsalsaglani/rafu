import AppKit
import SwiftUI

/// Settings > Agents (conductor/C0-shim.md, "Settings surface"):
/// registry-driven rows, one per `ConductorAdapterRegistry` adapter, in one
/// table — enable switch, icon, name, version, sign-in state (glyph + word),
/// and a default-model popup in a single aligned column. Selecting a row
/// shows its details below: abbreviated location with Show in Finder, and
/// one combo field for a custom model ID.
///
/// No credentials are collected anywhere. Rafu never stores, reads, copies,
/// or proxies a provider credential for inference (ADR 0018); the footer says
/// so, and signing in happens in the vendor's own CLI.
struct ConductorSettingsSection: View {
    @State private var model = ConductorSettingsModel()
    @State private var selection: ConductorCLIID?

    var body: some View {
        Group {
            Section {
                if model.rows.isEmpty {
                    Text("No agent CLIs are available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Table(model.rows, selection: $selection) {
                        TableColumn("Enabled") { row in
                            Toggle(isOn: model.binding(for: row.id)) {
                                Text("Enable \(row.displayName)")
                            }
                            .labelsHidden()
                        }
                        .width(52)
                        TableColumn("Agent") { row in
                            Label(row.displayName, systemImage: conductorAgentSymbol(row.id))
                                .lineLimit(1)
                        }
                        .width(min: 100, ideal: 120)
                        TableColumn("Version") { row in
                            Text(ConductorAgentDisplay.versionText(model.probe(for: row.id)))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .width(min: 56, ideal: 70, max: 100)
                        TableColumn("Sign-in") { row in
                            let state = model.signInPresentation(for: row.id)
                            Label(state.word, systemImage: state.systemImage)
                                .lineLimit(1)
                        }
                        .width(min: 110, ideal: 124)
                        TableColumn("Default model") { row in
                            ConductorDefaultModelCell(row: row, model: model)
                        }
                        .width(min: 170, ideal: 210)
                    }
                    .frame(height: 30 + 28 * CGFloat(model.rows.count))
                }
            } header: {
                Text("Agent CLIs")
            } footer: {
                Text(
                    "Rafu runs the agent CLIs you already have installed, under your own subscriptions. It never stores, reads, or forwards a sign-in token — log in inside each CLI. Nothing runs until you start a run. Unknown sign-in does not block runs."
                )
            }

            if let selected = model.rows.first(where: { $0.id == selection }) {
                Section(selected.displayName) {
                    ConductorAgentDetail(row: selected, model: model)
                }
            } else if !model.rows.isEmpty {
                Section {
                    Text("Select an agent to see its location and set a custom model.")
                        .foregroundStyle(.secondary)
                }
            }
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

    /// The last probe result, or `nil` before the explicit refresh finished.
    func probe(for id: ConductorCLIID) -> AdapterProbe? {
        probeByID[id]
    }

    /// Glyph plus word for the Sign-in column.
    func signInPresentation(for id: ConductorCLIID) -> ConductorSignInPresentation {
        ConductorSignInPresentation.make(probe: probeByID[id], auth: authByID[id])
    }

    /// Absolute path of the installed CLI, when the probe found one.
    func executablePath(for id: ConductorCLIID) -> String? {
        guard let probe = probeByID[id], probe.installed else { return nil }
        return probe.executableURL?.path
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

/// Pure presentation rules for the Agents pane: the sign-in glyph and word,
/// the version cell, and the abbreviated executable path.
nonisolated struct ConductorSignInPresentation: Equatable, Sendable {
    let systemImage: String
    let word: String

    /// Glyph plus word, never colour alone. "Unknown" never blocks a run:
    /// the CLI itself is the authority at launch (ADR 0018 delegated auth).
    static func make(probe: AdapterProbe?, auth: AdapterAuthStatus?) -> Self {
        guard let probe else { return Self(systemImage: "ellipsis.circle", word: "Checking…") }
        guard probe.installed else {
            return Self(systemImage: "minus.circle", word: "Not installed")
        }
        switch auth ?? .unknown() {
        case .authenticated:
            return Self(systemImage: "checkmark.circle", word: "Signed in")
        case .notAuthenticated:
            return Self(systemImage: "exclamationmark.triangle", word: "Sign-in needed")
        case .unknown:
            return Self(systemImage: "questionmark.circle", word: "Unknown")
        }
    }
}

nonisolated enum ConductorAgentDisplay {
    /// "/Users/me/.local/bin/claude" becomes "~/.local/bin/claude". Only a
    /// whole leading home-directory component is abbreviated, so
    /// "/Users/mentor/x" is not shortened for home "/Users/me".
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmedHome.isEmpty, trimmedHome != "/" else { return path }
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") {
            return "~" + String(path.dropFirst(trimmedHome.count))
        }
        return path
    }

    static func versionText(_ probe: AdapterProbe?) -> String {
        guard let probe, probe.installed else { return "—" }
        return probe.version ?? "Unknown"
    }
}

/// The glyph beside an agent's name. Neutral SF Symbols; no vendor artwork.
private func conductorAgentSymbol(_ id: ConductorCLIID) -> String {
    switch id {
    case .claudeCode: "asterisk"
    case .codex: "scope"
    case .openCode: "square"
    case .cline: "diamond"
    case .kimi: "k.square"
    case .geminiCLI: "sparkles"
    case .cursor: "cursorarrow"
    }
}

/// The default-model popup for one agent, plus a refresh icon where the CLI
/// can list models. The icon slot is reserved on every row so the popups line
/// up in one column.
private struct ConductorDefaultModelCell: View {
    let row: ConductorSettingsModel.Row
    let model: ConductorSettingsModel

    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
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
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("\(row.displayName) default model")

            if row.supportsModelDiscovery {
                Button {
                    refreshTask?.cancel()
                    refreshTask = Task { await model.refreshModels(for: row.id) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.modelRefreshState(for: row.id) == .refreshing)
                .help("Refresh models")
                .accessibilityLabel("Refresh \(row.displayName) models")
            } else {
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            }
        }
        .onDisappear { refreshTask?.cancel() }
    }
}

/// Details for the selected agent: where the CLI lives, its sign-in note, and
/// one editable combo field for a model ID the list does not offer.
private struct ConductorAgentDetail: View {
    let row: ConductorSettingsModel.Row
    let model: ConductorSettingsModel

    var body: some View {
        if let path = model.executablePath(for: row.id) {
            LabeledContent("Location") {
                HStack(spacing: 8) {
                    Text(ConductorAgentDisplay.abbreviated(path))
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: path)
                        ])
                    }
                    .buttonStyle(.link)
                }
            }
        } else {
            LabeledContent("Location") {
                Text(model.installStatusText(for: row.id))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Install status: \(model.installStatusText(for: row.id))")
            }
        }

        LabeledContent("Sign-in") {
            Text(model.authStatusText(for: row.id))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Sign-in status: \(model.authStatusText(for: row.id))")
        }

        LabeledContent("Custom model") {
            ConductorModelComboField(row: row, model: model)
        }

        if model.modelRefreshState(for: row.id) == .unsupported {
            Text("This CLI has no model-listing command; enter one by hand instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One field that is both a list and free text: type any model ID, or open
/// the menu to pick a listed one. Typing commits on Return or when the field
/// loses focus, so there is no separate "Use" button.
private struct ConductorModelComboField: View {
    let row: ConductorSettingsModel.Row
    let model: ConductorSettingsModel

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("Type a model ID", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .accessibilityLabel("\(row.displayName) custom model identifier")
                .onSubmit { commit(draft) }
            Menu {
                Button(ConductorModelResolution.unsetLabel) { commit("") }
                ForEach(model.availableModels(for: row.id)) { choice in
                    Button(choice.displayName) { commit(choice.id) }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a listed model")
            .accessibilityLabel("Choose \(row.displayName) model from the list")
        }
        .onAppear { draft = model.defaultModel(for: row.id) }
        .onChange(of: row.id) { _, _ in draft = model.defaultModel(for: row.id) }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit(draft) }
        }
    }

    private func commit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setDefaultModel(trimmed, for: row.id)
        draft = trimmed
    }
}
