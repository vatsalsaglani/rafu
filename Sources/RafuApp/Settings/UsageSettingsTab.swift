import SwiftUI

/// Settings > Usage (agent-usage-providers.md, "Registration panel"):
/// registry-driven rows, one per provider whose `makeStrategies` resolves to
/// at least one strategy. Authentication-specific controls stay in Settings;
/// periodic notch refreshes consume only previously stored inputs.
struct UsageSettingsSection: View {
    @State private var model = UsageSettingsModel()
    /// The one usage refresh path: Settings shows the same snapshots as the
    /// notch and never starts a second reader.
    private let companion = NotchCompanionModel.shared

    var body: some View {
        Group {
            UsageDisplayModeSection(companion: companion)

            UsageStripOrderSection(model: model)

            Section {
                if model.visibleRows.isEmpty {
                    Text("No usage providers are available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.visibleRows) { row in
                        UsageProviderRow(row: row, model: model, companion: companion)
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text(
                    "Rafu reads only metric fields — percent used, token totals, reset times — never message or prompt content. API keys and imported cookie headers are stored only in Rafu's Keychain. Provider tests and browser imports run only when you explicitly request them."
                )
            }
        }
        .task {
            companion.refreshUsage()
            await model.loadInputStatuses()
        }
    }
}

/// Used or Remaining for every usage ring, in Settings and in the notch.
private struct UsageDisplayModeSection: View {
    let companion: NotchCompanionModel

    var body: some View {
        Section {
            LabeledContent("Rings show") {
                RafuSegmentedPicker(
                    items: UsageDisplayMode.allCases,
                    selection: Binding(
                        get: { companion.usageDisplayMode },
                        set: { companion.setUsageDisplayMode($0) }),
                    title: { $0.title }
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Rings show used or remaining usage")
            }
        } header: {
            Text("Display")
        } footer: {
            Text(
                "Rings show the share of each limit that is used or still remaining. Warnings follow the used share in both modes."
            )
        }
    }
}

/// Pure rules for the Usage pane: strip reordering, the status capsule, and
/// when a provider's privacy explanation stays on screen.
nonisolated enum UsageSettingsPresentation {
    /// Moves `displayed` (a subsequence of `full`) the way `List.onMove`
    /// asks, then puts the result back into the slots `displayed` occupied.
    /// Entries of `full` that are not displayed (disabled providers) keep
    /// their exact positions, so they resume their place when re-enabled.
    static func reordered<ID: Hashable>(
        full: [ID], displayed: [ID], fromOffsets source: IndexSet, toOffset destination: Int
    ) -> [ID] {
        var moved = displayed
        moved.move(fromOffsets: source, toOffset: destination)
        let shown = Set(displayed)
        var iterator = moved.makeIterator()
        return full.map { id in
            shown.contains(id) ? (iterator.next() ?? id) : id
        }
    }

    /// Whether a provider's explanation of what Rafu reads is shown in full.
    /// It stays visible until the user has taken the step that lets Rafu read
    /// that provider (Connect, store a key, import a session, or — for
    /// providers with nothing to connect — turn it on), so consent is
    /// informed. Afterwards it moves behind a "What Rafu reads" disclosure.
    static func showsDisclosureInline(
        authPattern: UsageAuthPattern,
        isEnabled: Bool,
        isConnected: Bool,
        hasStoredKey: Bool,
        hasImportedSession: Bool
    ) -> Bool {
        switch authPattern {
        case .piggybackNetwork, .localSessionPiggyback: !isConnected
        case .apiKey: !hasStoredKey
        case .cookieImport: !hasImportedSession
        case .localZeroConfig: !isEnabled
        case .unavailable: true
        }
    }

    /// The one-word state shown in the row's capsule. Words, never colour.
    @MainActor
    static func statusLabel(
        authPattern: UsageAuthPattern,
        isEnabled: Bool,
        connection: UsageSettingsModel.ConnectionState,
        hasStoredKey: Bool,
        hasImportedSession: Bool
    ) -> String {
        switch authPattern {
        case .unavailable:
            return "Unavailable"
        case .localZeroConfig:
            return isEnabled ? "Local" : "Off"
        case .piggybackNetwork, .localSessionPiggyback:
            switch connection {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .failed: return "Connection failed"
            case .disconnected: return isEnabled ? "Not connected" : "Off"
            }
        case .apiKey:
            return hasStoredKey ? "Key stored" : "No key"
        case .cookieImport:
            return hasImportedSession ? "Session imported" : "No session"
        }
    }
}

/// Lets the user arrange which enabled providers lead the notch front line.
/// The first `stripFrontLineCap` entries with data render on the strip; the
/// rest fall into the expandable overflow grid. Drag a row to reorder it;
/// the context menu and VoiceOver actions offer Move Up and Move Down.
private struct UsageStripOrderSection: View {
    let model: UsageSettingsModel

    var body: some View {
        let rows = model.stripOrderedEnabledRows()
        Section {
            if rows.isEmpty {
                Text("Enable a provider below to arrange the notch strip.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        UsageStripOrderRow(
                            position: index + 1,
                            onStrip: index < model.stripFrontLineCap,
                            displayName: row.displayName,
                            canMoveUp: index > 0,
                            canMoveDown: index < rows.count - 1,
                            moveUp: { model.moveStripProvider(row.id, up: true) },
                            moveDown: { model.moveStripProvider(row.id, up: false) })
                    }
                    .onMove { source, destination in
                        model.moveStripProviders(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.bordered)
                .frame(height: CGFloat(rows.count) * 28 + 8)
                .accessibilityLabel("Notch strip order")
            }
        } header: {
            Text("Notch Strip Order")
        } footer: {
            Text(
                "Drag to reorder. The first \(model.stripFrontLineCap) enabled providers with data appear on the notch front line, in this order. The rest stay under “more providers.”"
            )
        }
    }
}

private struct UsageStripOrderRow: View {
    let position: Int
    let onStrip: Bool
    let displayName: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(onStrip ? "\(position)" : "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(onStrip ? .primary : .secondary)
                .frame(width: 18, alignment: .trailing)
                .accessibilityHidden(true)
            Text(displayName)
            if !onStrip {
                Text("overflow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Move Up", action: moveUp).disabled(!canMoveUp)
            Button("Move Down", action: moveDown).disabled(!canMoveDown)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            onStrip ? "On strip, position \(position)" : "In overflow"
        )
        .accessibilityAction(named: "Move Up") { if canMoveUp { moveUp() } }
        .accessibilityAction(named: "Move Down") { if canMoveDown { moveDown() } }
    }
}

nonisolated enum UsageAPIKeyInputIssue: Equatable, Sendable {
    case keyRequired
    case invalidKey
    case keychainUnavailable
    case testFailed
    case cancelled
}

nonisolated enum UsageAPIKeyOperationState: Equatable, Sendable {
    case loading
    case idle
    case saving
    case saved
    case testing
    case removing
    case succeeded
    case failed(UsageAPIKeyInputIssue)
}

nonisolated enum UsageCookieInputIssue: Equatable, Sendable {
    case needsFullDiskAccess
    case noMatchingCookies
    case browserUnavailable
    case keychainUnavailable
    case invalidRequest
    case cancelled
}

nonisolated enum UsageCookieOperationState: Equatable, Sendable {
    case loading
    case idle
    case importing
    case imported(Browser)
    case removing
    case failed(UsageCookieInputIssue)
}

/// The section's state: registry visibility, enable state, OAuth consent, and
/// redacted credential/cookie operation status. Secret text remains owned by
/// each `SecureField`; this observable model never stores an API key or cookie.
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
    private(set) var apiKeyStateByID: [UsageProviderID: UsageAPIKeyOperationState] = [:]
    private(set) var hasStoredAPIKeyByID: [UsageProviderID: Bool] = [:]
    private(set) var cookieStateByID: [UsageProviderID: UsageCookieOperationState] = [:]
    private(set) var hasImportedCookieByID: [UsageProviderID: Bool] = [:]

    private let enableStore: UsageEnableStore
    private let oauthConnector: UsageOAuthConnector
    private let inputClient: UsageProviderInputClient
    private let stripOrderStore: UsageStripOrderStore
    private let defaultEnabledByID: [UsageProviderID: Bool]
    private let rowsByID: [UsageProviderID: Row]
    private var enabledByID: [UsageProviderID: Bool] = [:]
    private var stripOrderIDs: [UsageProviderID] = []
    private var isLoadingInputStatuses = false
    private var didLoadInputStatuses = false

    /// `probeContext` never performs real I/O. It checks only whether a
    /// descriptor has landed, without risking network, filesystem, or
    /// Keychain access merely because Settings opened.
    init(
        descriptors: [UsageProviderDescriptor] = UsageProviderRegistry.all,
        enableStore: UsageEnableStore = UsageEnableStore(),
        oauthConnector: UsageOAuthConnector = UsageOAuthConnector(),
        inputClient: UsageProviderInputClient = .production,
        stripOrderStore: UsageStripOrderStore = UsageStripOrderStore(),
        probeContext: UsageFetchContext = UsageSettingsModel.probeContext()
    ) {
        self.enableStore = enableStore
        self.oauthConnector = oauthConnector
        self.inputClient = inputClient
        self.stripOrderStore = stripOrderStore
        let rows = descriptors.compactMap { descriptor -> Row? in
            guard !descriptor.makeStrategies(probeContext).isEmpty else { return nil }
            return Row(
                id: descriptor.id,
                displayName: descriptor.displayName,
                disclosure: descriptor.disclosure,
                authPattern: descriptor.authPattern)
        }
        visibleRows = rows
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        stripOrderIDs = Self.effectiveStripOrder(
            stored: stripOrderStore.order(), visibleIDs: rows.map(\.id))
        defaultEnabledByID = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.id, $0.defaultEnabled) })
        for descriptor in descriptors {
            enabledByID[descriptor.id] = enableStore.isEnabled(
                descriptor.id, default: descriptor.defaultEnabled)
            switch descriptor.authPattern {
            case .piggybackNetwork, .localSessionPiggyback:
                connectionStateByID[descriptor.id] =
                    oauthConnector.hasConsent(for: descriptor.id) ? .connected : .disconnected
            case .apiKey:
                apiKeyStateByID[descriptor.id] = .loading
                hasStoredAPIKeyByID[descriptor.id] = false
            case .cookieImport:
                cookieStateByID[descriptor.id] = .loading
                hasImportedCookieByID[descriptor.id] = false
            case .localZeroConfig, .unavailable:
                break
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

    // MARK: Notch strip order

    /// The number of front-line strip slots the order's first entries fill.
    var stripFrontLineCap: Int { UsageDisplayPolicy.frontLineCap }

    /// Enabled providers in their stored strip order — the reorderable
    /// candidates for the notch front line. Disabled providers never produce
    /// a snapshot, so they are excluded from the arrangement entirely.
    func stripOrderedEnabledRows() -> [Row] {
        stripOrderIDs.compactMap { id in
            guard isEnabled(id), let row = rowsByID[id],
                row.authPattern != .unavailable
            else { return nil }
            return row
        }
    }

    /// Moves `id` one position earlier (`up`) or later within the enabled
    /// strip order and persists the full order. Disabled providers keep their
    /// relative order at the tail so they resume their place if re-enabled.
    func moveStripProvider(_ id: UsageProviderID, up: Bool) {
        var enabled = stripOrderIDs.filter { isEnabled($0) }
        guard let index = enabled.firstIndex(of: id) else { return }
        let target = up ? index - 1 : index + 1
        guard enabled.indices.contains(target) else { return }
        enabled.swapAt(index, target)
        let disabled = stripOrderIDs.filter { !isEnabled($0) }
        stripOrderIDs = enabled + disabled
        stripOrderStore.setOrder(stripOrderIDs)
    }

    /// Applies a drag from `List.onMove`. `source` and `destination` index
    /// `stripOrderedEnabledRows()`; disabled providers keep their positions.
    func moveStripProviders(fromOffsets source: IndexSet, toOffset destination: Int) {
        let displayed = stripOrderedEnabledRows().map(\.id)
        let reordered = UsageSettingsPresentation.reordered(
            full: stripOrderIDs, displayed: displayed,
            fromOffsets: source, toOffset: destination)
        guard reordered != stripOrderIDs else { return }
        stripOrderIDs = reordered
        stripOrderStore.setOrder(stripOrderIDs)
    }

    /// Stored order (filtered to still-visible providers) first, then any
    /// visible provider not yet arranged, in registry order — so a newly
    /// shipped provider joins the tail rather than vanishing.
    private static func effectiveStripOrder(
        stored: [UsageProviderID], visibleIDs: [UsageProviderID]
    ) -> [UsageProviderID] {
        let visible = Set(visibleIDs)
        var result = stored.filter { visible.contains($0) }
        let placed = Set(result)
        result.append(contentsOf: visibleIDs.filter { !placed.contains($0) })
        return result
    }

    func connectionState(for id: UsageProviderID) -> ConnectionState {
        connectionStateByID[id] ?? .disconnected
    }

    /// The row's own auth pattern decides what connecting means, so a
    /// provider with no connection path can never be handed to a credential
    /// lookup that has no entry for it.
    func connectAffordance(for id: UsageProviderID) -> UsageConnectAffordance {
        rowsByID[id]?.authPattern.connectAffordance ?? .none
    }

    func connect(_ id: UsageProviderID, now: Date = Date()) async {
        guard connectionState(for: id) != .connecting else { return }
        let affordance = connectAffordance(for: id)
        guard affordance != .none else {
            connectionStateByID[id] = .failed(.unsupportedProvider)
            return
        }
        connectionStateByID[id] = .connecting
        switch await oauthConnector.connect(id, affordance: affordance, now: now) {
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

    func loadInputStatuses() async {
        guard !didLoadInputStatuses, !isLoadingInputStatuses else { return }
        isLoadingInputStatuses = true
        defer { isLoadingInputStatuses = false }

        for row in visibleRows {
            guard !Task.isCancelled else { return }
            switch row.authPattern {
            case .apiKey:
                do {
                    hasStoredAPIKeyByID[row.id] =
                        try await inputClient.loadCredential(row.id) != nil
                    guard !Task.isCancelled else { return }
                    apiKeyStateByID[row.id] = .idle
                } catch is CancellationError {
                    return
                } catch {
                    apiKeyStateByID[row.id] = .failed(.keychainUnavailable)
                }
            case .cookieImport:
                hasImportedCookieByID[row.id] = await inputClient.hasImportedCookie(row.id)
                guard !Task.isCancelled else { return }
                cookieStateByID[row.id] = .idle
            case .localZeroConfig, .piggybackNetwork, .localSessionPiggyback, .unavailable:
                break
            }
        }
        didLoadInputStatuses = true
    }

    func apiKeyState(for id: UsageProviderID) -> UsageAPIKeyOperationState {
        apiKeyStateByID[id] ?? .idle
    }

    func hasStoredAPIKey(for id: UsageProviderID) -> Bool {
        hasStoredAPIKeyByID[id] ?? false
    }

    @discardableResult
    func saveAPIKey(_ draft: String, for id: UsageProviderID) async -> Bool {
        guard !apiKeyOperationIsRunning(for: id) else { return false }
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            apiKeyStateByID[id] = .failed(.keyRequired)
            return false
        }
        guard let credential = UsageCredentialValidation.normalized(candidate) else {
            apiKeyStateByID[id] = .failed(.invalidKey)
            return false
        }

        apiKeyStateByID[id] = .saving
        do {
            try await inputClient.writeCredential(credential, id)
            hasStoredAPIKeyByID[id] = true
            apiKeyStateByID[id] = .saved
            return true
        } catch is CancellationError {
            apiKeyStateByID[id] = .failed(.cancelled)
        } catch {
            apiKeyStateByID[id] = .failed(.keychainUnavailable)
        }
        return false
    }

    func testAPIKey(_ draft: String, for id: UsageProviderID, now: Date = Date()) async {
        guard !apiKeyOperationIsRunning(for: id) else { return }

        let rawCandidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: String
        if rawCandidate.isEmpty {
            do {
                guard let stored = try await inputClient.loadCredential(id) else {
                    apiKeyStateByID[id] = .failed(.keyRequired)
                    return
                }
                credential = stored
                hasStoredAPIKeyByID[id] = true
            } catch is CancellationError {
                apiKeyStateByID[id] = .failed(.cancelled)
                return
            } catch {
                apiKeyStateByID[id] = .failed(.keychainUnavailable)
                return
            }
        } else {
            guard let candidate = UsageCredentialValidation.normalized(rawCandidate) else {
                apiKeyStateByID[id] = .failed(.invalidKey)
                return
            }
            guard await saveAPIKey(candidate, for: id) else { return }
            credential = candidate
        }

        guard !Task.isCancelled else {
            apiKeyStateByID[id] = .failed(.cancelled)
            return
        }
        apiKeyStateByID[id] = .testing
        switch await inputClient.testAPIKey(id, credential, now) {
        case .succeeded:
            apiKeyStateByID[id] = .succeeded
        case .failed:
            apiKeyStateByID[id] = .failed(.testFailed)
        case .cancelled:
            apiKeyStateByID[id] = .failed(.cancelled)
        }
    }

    func removeAPIKey(for id: UsageProviderID) async {
        guard !apiKeyOperationIsRunning(for: id) else { return }
        apiKeyStateByID[id] = .removing
        do {
            try await inputClient.removeCredential(id)
            hasStoredAPIKeyByID[id] = false
            apiKeyStateByID[id] = .idle
        } catch is CancellationError {
            apiKeyStateByID[id] = .failed(.cancelled)
        } catch {
            apiKeyStateByID[id] = .failed(.keychainUnavailable)
        }
    }

    func clearAPIKeyFeedback(for id: UsageProviderID) {
        switch apiKeyState(for: id) {
        case .saved, .succeeded, .failed:
            apiKeyStateByID[id] = .idle
        case .loading, .idle, .saving, .testing, .removing:
            break
        }
    }

    func cookieState(for id: UsageProviderID) -> UsageCookieOperationState {
        cookieStateByID[id] ?? .idle
    }

    func hasImportedCookie(for id: UsageProviderID) -> Bool {
        hasImportedCookieByID[id] ?? false
    }

    func importCookies(for id: UsageProviderID, from browser: Browser) async {
        guard !cookieOperationIsRunning(for: id) else { return }
        cookieStateByID[id] = .importing
        switch await inputClient.importCookies(id, browser) {
        case .imported(let importedBrowser):
            hasImportedCookieByID[id] = true
            cookieStateByID[id] = .imported(importedBrowser)
        case .needsFullDiskAccess:
            cookieStateByID[id] = .failed(.needsFullDiskAccess)
        case .noMatchingCookies:
            cookieStateByID[id] = .failed(.noMatchingCookies)
        case .browserUnavailable:
            cookieStateByID[id] = .failed(.browserUnavailable)
        case .storageFailed:
            cookieStateByID[id] = .failed(.keychainUnavailable)
        case .invalidRequest:
            cookieStateByID[id] = .failed(.invalidRequest)
        case .cancelled:
            cookieStateByID[id] = .failed(.cancelled)
        }
    }

    func removeCookies(for id: UsageProviderID) async {
        guard !cookieOperationIsRunning(for: id) else { return }
        cookieStateByID[id] = .removing
        do {
            try await inputClient.removeCookies(id)
            hasImportedCookieByID[id] = false
            cookieStateByID[id] = .idle
        } catch is CancellationError {
            cookieStateByID[id] = .failed(.cancelled)
        } catch {
            cookieStateByID[id] = .failed(.keychainUnavailable)
        }
    }

    func clearCookieFeedback(for id: UsageProviderID) {
        switch cookieState(for: id) {
        case .imported, .failed:
            cookieStateByID[id] = .idle
        case .loading, .idle, .importing, .removing:
            break
        }
    }

    static func probeContext() -> UsageFetchContext {
        UsageFetchContext(
            now: Date(),
            readFile: { _ in nil },
            http: .noop,
            credential: { _ in nil },
            cookieHeader: { _ in nil })
    }

    private func apiKeyOperationIsRunning(for id: UsageProviderID) -> Bool {
        switch apiKeyState(for: id) {
        case .saving, .testing, .removing:
            true
        case .loading, .idle, .saved, .succeeded, .failed:
            false
        }
    }

    private func cookieOperationIsRunning(for id: UsageProviderID) -> Bool {
        switch cookieState(for: id) {
        case .importing, .removing:
            true
        case .loading, .idle, .imported, .failed:
            false
        }
    }
}

private struct UsageProviderRow: View {
    let row: UsageSettingsModel.Row
    let model: UsageSettingsModel
    let companion: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: model.binding(for: row.id)) {
                    Text(row.displayName).font(.body.weight(.medium))
                }
                .disabled(row.authPattern == .unavailable)
                Spacer(minLength: 8)
                UsageStatusCapsule(text: statusLabel)
                if isOAuthPattern {
                    UsageOAuthConnectButton(
                        providerName: row.displayName,
                        state: model.connectionState(for: row.id),
                        connect: {
                            await model.connect(row.id)
                            companion.refreshUsage(force: true)
                        },
                        disconnect: {
                            await model.disconnect(row.id)
                            companion.refreshUsage(force: true)
                        })
                }
            }

            if model.isEnabled(row.id), let card = companion.usageCard(for: row.id) {
                UsageProviderCardView(
                    card: card, providerID: row.id, displayName: row.displayName,
                    authPattern: row.authPattern, mode: companion.usageDisplayMode,
                    isRefreshing: companion.isUsageRefreshing, compact: false,
                    ink: .settings(theme: theme), connect: cardConnectAction)
            }

            if showsDisclosureInline {
                Text(row.disclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DisclosureGroup("What Rafu reads") {
                    Text(row.disclosure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }

            switch row.authPattern {
            case .localZeroConfig:
                EmptyView()
            case .piggybackNetwork, .localSessionPiggyback:
                UsageOAuthConnectionStatus(
                    providerName: row.displayName,
                    affordance: row.authPattern.connectAffordance,
                    state: model.connectionState(for: row.id))
            case .apiKey:
                UsageAPIKeyControls(row: row, model: model)
            case .cookieImport:
                UsageCookieImportControls(row: row, model: model)
            case .unavailable:
                UsageUnavailableProviderNote(providerName: row.displayName)
            }
        }
        .padding(.vertical, 3)
    }

    /// The card's "Connect for exact usage…" runs the same Connect flow as
    /// the row's Connect button. `nil` while a Connect is already running.
    private var cardConnectAction: (@MainActor () -> Void)? {
        guard model.connectionState(for: row.id) != .connecting else { return nil }
        let model = model
        let companion = companion
        let id = row.id
        return {
            Task {
                await model.connect(id)
                companion.refreshUsage(force: true)
            }
        }
    }

    private var isOAuthPattern: Bool {
        switch row.authPattern {
        case .piggybackNetwork, .localSessionPiggyback: true
        case .localZeroConfig, .apiKey, .cookieImport, .unavailable: false
        }
    }

    private var statusLabel: String {
        UsageSettingsPresentation.statusLabel(
            authPattern: row.authPattern,
            isEnabled: model.isEnabled(row.id),
            connection: model.connectionState(for: row.id),
            hasStoredKey: model.hasStoredAPIKey(for: row.id),
            hasImportedSession: model.hasImportedCookie(for: row.id))
    }

    private var showsDisclosureInline: Bool {
        UsageSettingsPresentation.showsDisclosureInline(
            authPattern: row.authPattern,
            isEnabled: model.isEnabled(row.id),
            isConnected: model.connectionState(for: row.id) == .connected,
            hasStoredKey: model.hasStoredAPIKey(for: row.id),
            hasImportedSession: model.hasImportedCookie(for: row.id))
    }
}

/// A one-word state in a capsule. The word carries the meaning; the capsule
/// is only a quiet container.
private struct UsageStatusCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .accessibilityLabel("Status: \(text)")
    }
}

/// A rostered provider with no obtainable usage signal. There is deliberately
/// no button here: an error the user cannot act on is worse than a stated
/// limitation, so the reason is plain text next to the disabled toggle
/// (never colour or a tooltip alone).
private struct UsageUnavailableProviderNote: View {
    let providerName: String

    var body: some View {
        Label(
            "Rafu can't show \(providerName) usage: it exposes no local session or CLI credential Rafu is able to read, so there is nothing to turn on or connect.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct UsageAPIKeyControls: View {
    let row: UsageSettingsModel.Row
    let model: UsageSettingsModel

    @State private var draft = ""
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SecureField(fieldPrompt, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .accessibilityLabel("\(row.displayName) API key")
                    .onSubmit {
                        guard canSave else { return }
                        operationTask?.cancel()
                        operationTask = Task {
                            if await model.saveAPIKey(draft, for: row.id) {
                                draft = ""
                            }
                        }
                    }
                Button("Save") {
                    operationTask?.cancel()
                    operationTask = Task {
                        if await model.saveAPIKey(draft, for: row.id) {
                            draft = ""
                        }
                    }
                }
                .disabled(!canSave)
                .accessibilityLabel("Save \(row.displayName) API key")
                Button("Test") {
                    operationTask?.cancel()
                    operationTask = Task {
                        await model.testAPIKey(draft, for: row.id)
                        if model.hasStoredAPIKey(for: row.id) {
                            draft = ""
                        }
                    }
                }
                .disabled(!canTest)
                .accessibilityLabel("Test \(row.displayName) API key")
                if model.hasStoredAPIKey(for: row.id) {
                    Button("Remove", role: .destructive) {
                        operationTask?.cancel()
                        operationTask = Task { await model.removeAPIKey(for: row.id) }
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("Remove \(row.displayName) API key")
                }
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("API key status: \(statusText)")
        }
        .onChange(of: draft) {
            if !draft.isEmpty {
                model.clearAPIKeyFeedback(for: row.id)
            }
        }
        .onDisappear {
            operationTask?.cancel()
        }
    }

    private var fieldPrompt: String {
        model.hasStoredAPIKey(for: row.id) ? "API key stored in Keychain" : "API key"
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    private var canTest: Bool {
        (canSave || model.hasStoredAPIKey(for: row.id)) && !isBusy
    }

    private var isBusy: Bool {
        switch model.apiKeyState(for: row.id) {
        case .loading, .saving, .testing, .removing:
            true
        case .idle, .saved, .succeeded, .failed:
            false
        }
    }

    private var statusText: String {
        switch model.apiKeyState(for: row.id) {
        case .loading:
            "Checking Rafu's Keychain…"
        case .idle:
            model.hasStoredAPIKey(for: row.id)
                ? "API key stored in Rafu's Keychain."
                : "No API key stored."
        case .saving:
            "Saving to Rafu's Keychain…"
        case .saved:
            "API key saved in Rafu's Keychain."
        case .testing:
            "Testing one usage request…"
        case .removing:
            "Removing API key…"
        case .succeeded:
            "Test succeeded. Usage data is available."
        case .failed(.keyRequired):
            "Enter an API key before testing."
        case .failed(.invalidKey):
            "The API key contains an unsupported control character or is too large."
        case .failed(.keychainUnavailable):
            "Rafu couldn't access its Keychain item."
        case .failed(.testFailed):
            "Test failed. Check the key and provider availability."
        case .failed(.cancelled):
            "Test cancelled."
        }
    }
}

private struct UsageCookieImportControls: View {
    let row: UsageSettingsModel.Row
    let model: UsageSettingsModel

    @State private var selectedBrowser = Browser.chrome
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Picker("Browser", selection: $selectedBrowser) {
                    ForEach(Browser.allCases, id: \.rawValue) { browser in
                        Text(browser.displayName).tag(browser)
                    }
                }
                .frame(width: 170)
                Button("Import from browser") {
                    operationTask?.cancel()
                    operationTask = Task {
                        await model.importCookies(for: row.id, from: selectedBrowser)
                    }
                }
                .disabled(isBusy)
                .accessibilityLabel("Import \(row.displayName) session from browser")
                if model.hasImportedCookie(for: row.id) {
                    Button("Remove", role: .destructive) {
                        operationTask?.cancel()
                        operationTask = Task { await model.removeCookies(for: row.id) }
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("Remove imported \(row.displayName) browser session")
                }
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Browser import status: \(statusText)")
            if model.cookieState(for: row.id) == .failed(.needsFullDiskAccess) {
                Label(
                    "Safari cookie access requires Full Disk Access. In System Settings, open Privacy & Security > Full Disk Access, enable Rafu, then try the import again.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: selectedBrowser) {
            model.clearCookieFeedback(for: row.id)
        }
        .onDisappear {
            operationTask?.cancel()
        }
    }

    private var isBusy: Bool {
        switch model.cookieState(for: row.id) {
        case .loading, .importing, .removing:
            true
        case .idle, .imported, .failed:
            false
        }
    }

    private var statusText: String {
        switch model.cookieState(for: row.id) {
        case .loading:
            "Checking Rafu's Keychain…"
        case .idle:
            model.hasImportedCookie(for: row.id)
                ? "Imported browser session stored in Rafu's Keychain."
                : "No browser session imported."
        case .importing:
            "Importing from \(selectedBrowser.displayName)…"
        case .imported(let browser):
            "Imported from \(browser.displayName) and stored in Rafu's Keychain."
        case .removing:
            "Removing imported browser session…"
        case .failed(.needsFullDiskAccess):
            "Safari access was denied."
        case .failed(.noMatchingCookies):
            "No matching signed-in session was found in this browser."
        case .failed(.browserUnavailable):
            "The browser store couldn't be read. Close the browser if needed, then try again."
        case .failed(.keychainUnavailable):
            "The session was found, but Rafu couldn't store it in Keychain."
        case .failed(.invalidRequest):
            "This provider doesn't have a valid browser-import request."
        case .failed(.cancelled):
            "Browser import cancelled."
        }
    }
}

/// Connect or Disconnect, in the provider row's header.
private struct UsageOAuthConnectButton: View {
    let providerName: String
    let state: UsageSettingsModel.ConnectionState
    let connect: @MainActor () async -> Void
    let disconnect: @MainActor () async -> Void

    var body: some View {
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

    private var actionTitle: String {
        state == .connected ? "Disconnect" : "Connect"
    }
}

/// The explanatory line under a Connect-style provider row.
private struct UsageOAuthConnectionStatus: View {
    let providerName: String
    let affordance: UsageConnectAffordance
    let state: UsageSettingsModel.ConnectionState

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
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Connection status: \(statusText)")
        }
    }

    private var statusText: String {
        switch state {
        case .disconnected:
            switch affordance {
            case .externalCredential, .none:
                "Not connected. Local usage remains enabled."
            case .localSession:
                "Not connected. Rafu sends no \(providerName) usage request until you connect."
            }
        case .connecting:
            switch affordance {
            case .externalCredential, .none:
                "Connecting…"
            case .localSession:
                "Checking for a signed-in \(providerName) session on this Mac…"
            }
        case .connected:
            switch affordance {
            case .externalCredential, .none:
                "Connected for exact usage requests."
            case .localSession:
                "Connected. Rafu uses \(providerName)'s own signed-in session on this Mac."
            }
        case .failed(.credentialsUnavailable):
            switch affordance {
            case .externalCredential, .none:
                "Connection failed: credentials were not found."
            case .localSession:
                "Connection failed: no signed-in \(providerName) session was found on this Mac. Sign in to \(providerName), then connect again."
            }
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
