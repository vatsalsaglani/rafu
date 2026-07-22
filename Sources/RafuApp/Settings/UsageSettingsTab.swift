import SwiftUI

/// Settings > Usage (agent-usage-providers.md, "Registration panel"):
/// registry-driven rows, one per provider whose `makeStrategies` actually
/// resolves to at least one strategy — a stub provider (empty strategies,
/// per usage-providers/W0-shim.md: "recommend hidden to keep the tab
/// honest") never appears here at all, rather than showing as a dead
/// "Not yet supported" row. In W0 that means only Claude and Codex are
/// visible. Their local fallbacks remain independently toggleable, while
/// their `piggybackNetwork` rows expose explicit Connect/Disconnect controls;
/// later phases add rows as their providers' strategies stop returning `[]`.
struct UsageSettingsSection: View {
    @State private var model = UsageSettingsModel()

    var body: some View {
        Section {
            if model.visibleRows.isEmpty {
                Text("No usage providers are available yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.visibleRows) { row in
                    UsageProviderRow(row: row, model: model)
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text(
                "Rafu reads only metric fields — percent used, token totals, reset times — never message or prompt content. Local usage stays enabled independently; Connect separately allows read-only exact usage requests for one provider."
            )
        }
    }
}

/// The section's state: which registry descriptors are currently visible
/// (`makeStrategies` non-empty against a network/credential-free probe
/// context) and each visible provider's enable state, backed by
/// `UsageEnableStore`.
@MainActor
@Observable
final class UsageSettingsModel {
    struct Row: Identifiable {
        let id: UsageProviderID
        let displayName: String
        let disclosure: String
        let authPattern: UsageAuthPattern
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(UsageOAuthConnectionIssue)
    }

    private(set) var visibleRows: [Row] = []
    private(set) var connectionStateByID: [UsageProviderID: ConnectionState] = [:]

    private let enableStore: UsageEnableStore
    private let oauthConnector: UsageOAuthConnector
    private let defaultEnabledByID: [UsageProviderID: Bool]
    private var enabledByID: [UsageProviderID: Bool] = [:]

    /// `probeContext` never performs real I/O — `UsageHTTPClient.noop`
    /// always fails, `readFile`/`credential`/`cookieHeader` always return
    /// `nil` — it exists purely so `descriptor.makeStrategies(_:)` can be
    /// called to check whether a provider has landed yet, without risking
    /// a network call or Keychain read from Settings simply opening.
    init(
        descriptors: [UsageProviderDescriptor] = UsageProviderRegistry.all,
        enableStore: UsageEnableStore = UsageEnableStore(),
        oauthConnector: UsageOAuthConnector = UsageOAuthConnector(),
        probeContext: UsageFetchContext = UsageSettingsModel.probeContext()
    ) {
        self.enableStore = enableStore
        self.oauthConnector = oauthConnector
        visibleRows = descriptors.compactMap { descriptor in
            guard !descriptor.makeStrategies(probeContext).isEmpty else { return nil }
            return Row(
                id: descriptor.id, displayName: descriptor.displayName,
                disclosure: descriptor.disclosure, authPattern: descriptor.authPattern)
        }
        defaultEnabledByID = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.id, $0.defaultEnabled) })
        for descriptor in descriptors {
            enabledByID[descriptor.id] = enableStore.isEnabled(
                descriptor.id, default: descriptor.defaultEnabled)
            if case .piggybackNetwork = descriptor.authPattern {
                connectionStateByID[descriptor.id] =
                    oauthConnector.hasConsent(for: descriptor.id) ? .connected : .disconnected
            }
        }
    }

    func isEnabled(_ id: UsageProviderID) -> Bool {
        enabledByID[id] ?? defaultEnabledByID[id] ?? false
    }

    func setEnabled(_ value: Bool, for id: UsageProviderID) {
        enabledByID[id] = value
        enableStore.setEnabled(value, for: id)
    }

    func binding(for id: UsageProviderID) -> Binding<Bool> {
        Binding(get: { self.isEnabled(id) }, set: { self.setEnabled($0, for: id) })
    }

    func connectionState(for id: UsageProviderID) -> ConnectionState {
        connectionStateByID[id] ?? .disconnected
    }

    func connect(_ id: UsageProviderID, now: Date = Date()) async {
        guard connectionState(for: id) != .connecting else { return }
        connectionStateByID[id] = .connecting
        switch await oauthConnector.connect(id, now: now) {
        case .connected:
            connectionStateByID[id] = .connected
        case .failed(let issue):
            connectionStateByID[id] = .failed(issue)
        }
    }

    func disconnect(_ id: UsageProviderID) async {
        await oauthConnector.disconnect(id)
        connectionStateByID[id] = .disconnected
    }

    static func probeContext() -> UsageFetchContext {
        UsageFetchContext(
            now: Date(), readFile: { _ in nil }, http: .noop, credential: { _ in nil },
            cookieHeader: { _ in nil })
    }
}

/// One provider's Settings row: display name + enable toggle on the header
/// line, the disclosure line beneath it. `authPattern`-specific
/// Connect/key-field/cookie-import affordances arrive with the phase that
/// makes that pattern real (agent-usage-providers.md, "Registration
/// panel") — W0 ships only `localZeroConfig` rows, which need nothing
/// beyond the toggle.
private struct UsageProviderRow: View {
    let row: UsageSettingsModel.Row
    let model: UsageSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: model.binding(for: row.id)) {
                Text(row.displayName).font(.body.weight(.medium))
            }
            Text(row.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .piggybackNetwork = row.authPattern {
                UsageOAuthConnectionControls(
                    providerName: row.displayName,
                    state: model.connectionState(for: row.id),
                    connect: { await model.connect(row.id) },
                    disconnect: { await model.disconnect(row.id) })
            }
        }
        .padding(.vertical, 2)
    }
}

private struct UsageOAuthConnectionControls: View {
    let providerName: String
    let state: UsageSettingsModel.ConnectionState
    let connect: @MainActor () async -> Void
    let disconnect: @MainActor () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            if state == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting \(providerName)")
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Connection status: \(statusText)")
            Spacer()
            Button(actionTitle) {
                Task {
                    if state == .connected {
                        await disconnect()
                    } else {
                        await connect()
                    }
                }
            }
            .disabled(state == .connecting)
            .accessibilityLabel("\(actionTitle) \(providerName) usage")
        }
    }

    private var actionTitle: String {
        state == .connected ? "Disconnect" : "Connect"
    }

    private var statusText: String {
        switch state {
        case .disconnected:
            "Not connected. Local usage remains enabled."
        case .connecting:
            "Connecting…"
        case .connected:
            "Connected for exact usage requests."
        case .failed(.credentialsUnavailable):
            "Connection failed: credentials were not found."
        case .failed(.credentialsInvalid):
            "Connection failed: credentials could not be validated."
        case .failed(.credentialsExpired):
            "Connection failed: credentials are expired."
        case .failed(.credentialAccessDenied):
            "Connection failed: credential access was denied."
        case .failed(.unsupportedProvider):
            "Connection failed: this provider is not supported."
        case .failed(.cancelled):
            "Connection cancelled."
        }
    }
}
