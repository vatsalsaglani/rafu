import SwiftUI

/// Settings > Usage (agent-usage-providers.md, "Registration panel"):
/// registry-driven rows, one per provider whose `makeStrategies` actually
/// resolves to at least one strategy — a stub provider (empty strategies,
/// per usage-providers/W0-shim.md: "recommend hidden to keep the tab
/// honest") never appears here at all, rather than showing as a dead
/// "Not yet supported" row. In W0 that means only Claude and Codex are
/// visible, each with just a detection line and an enable toggle (their
/// `localZeroConfig` auth pattern needs no Connect/key/cookie affordance);
/// later phases add rows as their providers' `makeStrategies` stop
/// returning `[]`.
struct UsageSettingsSection: View {
    @State private var model = UsageSettingsModel()

    var body: some View {
        Section {
            if model.visibleRows.isEmpty {
                Text("No usage providers are available yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.visibleRows) { row in
                    UsageProviderRow(row: row, isEnabled: model.binding(for: row.id))
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text(
                "Rafu reads only metric fields — percent used, token totals, reset times — never message or prompt content. Network-backed providers ship off by default; each row states plainly what is read and where a request would go."
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

    private(set) var visibleRows: [Row] = []

    private let enableStore: UsageEnableStore
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
        probeContext: UsageFetchContext = UsageSettingsModel.probeContext()
    ) {
        self.enableStore = enableStore
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
    let isEnabled: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isEnabled) {
                Text(row.displayName).font(.body.weight(.medium))
            }
            Text(row.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
