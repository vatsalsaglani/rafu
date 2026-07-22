import SwiftUI

/// Settings > Usage (agent-usage-providers.md, "Registration panel"):
/// registry-driven rows, one per provider whose `makeStrategies` resolves to
/// at least one strategy. Authentication-specific controls stay in Settings;
/// periodic notch refreshes consume only previously stored inputs.
struct UsageSettingsSection: View {
    @State private var model = UsageSettingsModel()

    var body: some View {
        Group {
            UsageStripOrderSection(model: model)

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
                    "Rafu reads only metric fields — percent used, token totals, reset times — never message or prompt content. API keys and imported cookie headers are stored only in Rafu's Keychain. Provider tests and browser imports run only when you explicitly request them."
                )
            }
        }
        .task {
            await model.loadInputStatuses()
        }
    }
}

/// Lets the user arrange which enabled providers lead the notch front line.
/// The first `stripFrontLineCap` entries with data render on the strip; the
/// rest fall into the expandable overflow grid.
private struct UsageStripOrderSection: View {
    let model: UsageSettingsModel

    var body: some View {
        let rows = model.stripOrderedEnabledRows()
        Section {
            if rows.isEmpty {
                Text("Enable a provider below to arrange the notch strip.")
                    .foregroundStyle(.secondary)
            } else {
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
            }
        } header: {
            Text("Notch strip order")
        } footer: {
            Text(
                "The first \(model.stripFrontLineCap) enabled providers with data appear on the notch front line, in this order. The rest stay under “more providers.”"
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
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            .accessibilityLabel("Move \(displayName) earlier in the strip")
            Button(action: moveDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
            .accessibilityLabel("Move \(displayName) later in the strip")
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            onStrip ? "On strip, position \(position)" : "In overflow")
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
            case .piggybackNetwork:
                connectionStateByID[descriptor.id] =
                    oauthConnector.hasConsent(for: descriptor.id) ? .connected : .disconnected
            case .apiKey:
                apiKeyStateByID[descriptor.id] = .loading
                hasStoredAPIKeyByID[descriptor.id] = false
            case .cookieImport:
                cookieStateByID[descriptor.id] = .loading
                hasImportedCookieByID[descriptor.id] = false
            case .localZeroConfig:
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
            guard isEnabled(id) else { return nil }
            return rowsByID[id]
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
            case .localZeroConfig, .piggybackNetwork:
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: model.binding(for: row.id)) {
                Text(row.displayName).font(.body.weight(.medium))
            }
            Text(row.disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch row.authPattern {
            case .localZeroConfig:
                EmptyView()
            case .piggybackNetwork:
                UsageOAuthConnectionControls(
                    providerName: row.displayName,
                    state: model.connectionState(for: row.id),
                    connect: { await model.connect(row.id) },
                    disconnect: { await model.disconnect(row.id) })
            case .apiKey:
                UsageAPIKeyControls(row: row, model: model)
            case .cookieImport:
                UsageCookieImportControls(row: row, model: model)
            }
        }
        .padding(.vertical, 3)
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
