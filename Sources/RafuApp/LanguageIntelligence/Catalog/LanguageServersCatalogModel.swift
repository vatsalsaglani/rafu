import Foundation
import Observation

/// Drives Settings > Language Servers: the curated catalog, the batching
/// packs, and a user's own custom entries. Mirrors
/// `AIProviderSettingsModel`'s shape — an `@Observable @MainActor` model
/// with `@ObservationIgnored` dependencies, `.task { await model.load() }`
/// guarded by `hasLoaded`, and `beginX()` methods that launch independent,
/// cancellable `Task`s rather than blocking a view action.
///
/// Never holds document text; every observable property here is small
/// install/consent/error metadata, safe to read from a view body.
@Observable
@MainActor
final class LanguageServersCatalogModel {

    // MARK: - Row/state types

    /// Whether one descriptor is ready to run. `.prerequisiteMissing` is
    /// distinct from `.unavailableToolchain`: the latter means a *known*
    /// discovery mechanism (gopls, SourceKit-LSP) ran and found nothing;
    /// the former means this descriptor's `.localDiscovery` id has no
    /// discovery mechanism implemented at all (never true for anything in
    /// `CuratedCatalog` today, but a well-defined answer for a future
    /// local-discovery user entry).
    nonisolated enum InstallState: Sendable, Equatable {
        case notInstalled
        case installed(version: String)
        case availableViaToolchain
        case unavailableToolchain
        case prerequisiteMissing
    }

    nonisolated struct CatalogRowState: Sendable, Identifiable, Equatable {
        let id: String
        let descriptor: ServerDescriptor
        var installState: InstallState
        var progressActive: Bool
    }

    nonisolated struct PackRowState: Sendable, Identifiable, Equatable {
        let pack: ServerPack
        var memberStates: [String: InstallState]
        var progressActive: Bool
        var id: String { pack.id }
    }

    /// One pending "approve this download" sheet, for either a single
    /// server or a whole pack.
    nonisolated struct ConsentRequest: Identifiable, Sendable {
        nonisolated enum Subject: Sendable {
            case server(ServerDescriptor)
            case pack(displayName: String, descriptors: [ServerDescriptor])
        }
        let id: String
        let subject: Subject
    }

    /// The editable fields backing `UserServerEntryForm`, independent of
    /// the `ServerDescriptor` it eventually builds — free-text/comma/
    /// space-separated input needs its own draft shape before validation.
    nonisolated struct UserEntryDraft: Sendable, Equatable {
        nonisolated enum SourceKind: String, Sendable, CaseIterable {
            case httpsReleaseAsset
            case localBinary
        }

        var id = ""
        var displayName = ""
        var languageIDsText = ""
        var sourceKind = SourceKind.httpsReleaseAsset
        var assetURLText = ""
        var version = ""
        var license = ""
        var archiveFormat = ArchiveFormat.tarGzip
        var binaryRelativePath = ""
        var localBinaryPathText = ""
        var launchArgumentsText = ""
    }

    nonisolated enum CatalogModelError: Error, Equatable {
        case emptyID
        case duplicateID
        case emptyLanguageIDs
        case invalidHTTPSURL
        case emptyBinaryRelativePath
        case invalidLocalPath
    }

    // MARK: - Observable state

    private(set) var rows: [CatalogRowState] = []
    private(set) var packs: [PackRowState] = []
    private(set) var userRows: [CatalogRowState] = []
    var presentedConsent: ConsentRequest?
    var presentedError: String?
    var isPresentingEntryForm = false
    var entryDraft = UserEntryDraft()

    // MARK: - Dependencies

    @ObservationIgnored private let userEntryStore: UserEntryStore
    @ObservationIgnored private let layout: InstallLayout
    @ObservationIgnored private let installer: ServerInstaller
    @ObservationIgnored private let nodeRuntime: NodeRuntimeManager
    @ObservationIgnored private var operationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var hasLoaded = false

    init(
        userEntryStore: UserEntryStore = UserEntryStore(),
        layout: InstallLayout = InstallLayout()
    ) {
        self.userEntryStore = userEntryStore
        self.layout = layout
        self.installer = ServerInstaller(layout: layout)
        self.nodeRuntime = NodeRuntimeManager(layout: layout)
    }

    /// Test-only dependency injection: a temp-dir `layout`/`userEntryStore`
    /// and a fixture `downloader`, so install/uninstall/update/pack flows
    /// never touch the real network or `~/Library/Application Support`.
    /// `nodeRuntimeChecksum` defaults to `nil` (verification disabled) so a
    /// fixture Node tarball never has to match the real pinned checksum.
    init(
        userEntryStore: UserEntryStore,
        layout: InstallLayout,
        downloader: any AssetDownloading,
        nodeRuntimeChecksum: String? = nil
    ) {
        self.userEntryStore = userEntryStore
        self.layout = layout
        self.installer = ServerInstaller(downloader: downloader, layout: layout)
        self.nodeRuntime = NodeRuntimeManager(
            downloader: downloader, layout: layout, expectedChecksum: nodeRuntimeChecksum)
    }

    isolated deinit {
        for task in operationTasks.values {
            task.cancel()
        }
    }

    // MARK: - Loading

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        rows = CuratedCatalog.servers.map {
            CatalogRowState(
                id: $0.id, descriptor: $0, installState: .notInstalled, progressActive: false)
        }
        packs = ServerPack.all.map {
            PackRowState(pack: $0, memberStates: [:], progressActive: false)
        }
        await reloadUserEntries()
        await refreshInstallState()
    }

    func beginRefresh() {
        operationTasks["refresh"]?.cancel()
        operationTasks["refresh"] = Task { [weak self] in
            guard let self else { return }
            await self.reloadUserEntries()
            await self.refreshInstallState()
            self.operationTasks["refresh"] = nil
        }
    }

    private func reloadUserEntries() async {
        do {
            let entries = try await userEntryStore.load()
            userRows = entries.map {
                CatalogRowState(
                    id: $0.id, descriptor: $0, installState: .notInstalled, progressActive: false)
            }
        } catch {
            presentedError = Self.message(for: error)
            userRows = []
        }
    }

    /// Recomputes every row/pack's `InstallState` off the main actor: a
    /// disk check for `.singleBinary`/`.nodeHosted` descriptors, or a
    /// `Task.detached` toolchain discovery (spawns `xcrun`, walks `PATH`)
    /// for `.localDiscovery` ones — never inline in a view `body`.
    func refreshInstallState() async {
        let catalogDescriptors = rows.map(\.descriptor)
        let userDescriptors = userRows.map(\.descriptor)
        let layout = layout

        let states = await Task.detached(priority: .utility) { () -> [String: InstallState] in
            var states: [String: InstallState] = [:]
            for descriptor in catalogDescriptors + userDescriptors {
                states[descriptor.id] = Self.installState(for: descriptor, layout: layout)
            }
            return states
        }.value

        rows = rows.map { row in
            var row = row
            if let state = states[row.id] { row.installState = state }
            return row
        }
        userRows = userRows.map { row in
            var row = row
            if let state = states[row.id] { row.installState = state }
            return row
        }
        packs = packs.map { pack in
            var pack = pack
            for serverID in pack.pack.serverIDs {
                if let state = states[serverID] { pack.memberStates[serverID] = state }
            }
            return pack
        }
    }

    private nonisolated static func installState(
        for descriptor: ServerDescriptor, layout: InstallLayout
    ) -> InstallState {
        switch descriptor.kind {
        case .localDiscovery:
            switch descriptor.id {
            case "gopls":
                return InstalledServerResolver.discoverGopls() != nil
                    ? .availableViaToolchain : .unavailableToolchain
            case "sourcekit-lsp":
                return InstalledServerResolver.discoverSourceKitLSP() != nil
                    ? .availableViaToolchain : .unavailableToolchain
            default:
                return .prerequisiteMissing
            }

        case .singleBinary, .nodeHosted:
            if let source = descriptor.source, source.url.isFileURL {
                return FileManager.default.isExecutableFile(atPath: source.url.path)
                    ? .installed(version: source.version) : .notInstalled
            }
            guard let binaryURL = layout.installedBinaryURL(descriptor: descriptor),
                FileManager.default.isExecutableFile(atPath: binaryURL.path)
            else {
                return .notInstalled
            }
            return .installed(version: descriptor.source?.version ?? "unknown")
        }
    }

    // MARK: - Install / update / uninstall (single server)

    func beginInstall(id: String) {
        guard let descriptor = descriptor(forID: id) else { return }
        presentedConsent = ConsentRequest(id: descriptor.id, subject: .server(descriptor))
    }

    /// "Update" re-runs the exact same consent-gated install flow as
    /// "Install…" — a fresh download deserves the same honest disclosure
    /// even though the server was already trusted once.
    func beginUpdate(id: String) {
        beginInstall(id: id)
    }

    func confirmInstall() {
        guard let consent = presentedConsent, case .server(let descriptor) = consent.subject
        else { return }
        presentedConsent = nil
        beginOperation(id: descriptor.id) { model in
            try await model.performInstall(descriptor: descriptor)
        }
    }

    func beginUninstall(id: String) {
        guard let descriptor = descriptor(forID: id) else { return }
        // A local `file://` entry was never copied under `layout` — Rafu
        // never deletes a user's own external binary. "Remove" (custom
        // entries only) drops the catalog record instead.
        guard descriptor.source?.url.isFileURL != true else { return }
        let directory = layout.serverDirectory(id: descriptor.id)
        beginOperation(id: id) { _ in
            try await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: directory)
            }.value
        }
    }

    func cancelInstall(id: String) {
        operationTasks[id]?.cancel()
        operationTasks[id] = nil
        setProgress(id: id, active: false)
    }

    private func performInstall(descriptor: ServerDescriptor) async throws {
        if descriptor.kind == .nodeHosted {
            _ = try await nodeRuntime.ensureInstalled(consentToQuarantineRemoval: true)
        }
        _ = try await installer.install(descriptor: descriptor, consentToQuarantineRemoval: true)
    }

    // MARK: - Packs

    func beginInstallPack(id: String) {
        guard let pack = packs.first(where: { $0.id == id })?.pack else { return }
        let descriptors = pack.serverIDs.compactMap { serverID in
            CuratedCatalog.servers.first { $0.id == serverID }
        }
        guard !descriptors.isEmpty else { return }
        presentedConsent = ConsentRequest(
            id: pack.id, subject: .pack(displayName: pack.displayName, descriptors: descriptors))
    }

    func confirmInstallPack() {
        guard let consent = presentedConsent, case .pack(_, let descriptors) = consent.subject
        else { return }
        let packID = consent.id
        presentedConsent = nil
        beginOperation(id: packID) { model in
            await model.performInstallPack(descriptors: descriptors)
        }
    }

    /// Installs every pack member, sharing one `ensureInstalled` call for
    /// the Node runtime when any member needs it. A single member's
    /// failure is reported (never thrown out of this method) so the
    /// remaining members still install and stay installed.
    private func performInstallPack(descriptors: [ServerDescriptor]) async {
        if descriptors.contains(where: { $0.kind == .nodeHosted }) {
            do {
                _ = try await nodeRuntime.ensureInstalled(consentToQuarantineRemoval: true)
            } catch {
                presentedError = Self.message(for: error)
                return
            }
        }
        for descriptor in descriptors {
            guard !Task.isCancelled else { return }
            do {
                _ = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: true)
            } catch {
                presentedError = Self.message(for: error)
            }
        }
    }

    // MARK: - Custom (user) entries

    /// Validates `draft`, builds a `ServerDescriptor`, and persists it via
    /// `UserEntryStore.add` (which re-validates the source URL itself).
    /// Throws `CatalogModelError` for in-form validation failures, or
    /// rethrows `UserEntryStoreError` from the store.
    func addUserEntry(_ draft: UserEntryDraft) async throws {
        let descriptor = try Self.makeDescriptor(from: draft)
        guard !CuratedCatalog.servers.contains(where: { $0.id == descriptor.id }) else {
            throw CatalogModelError.duplicateID
        }
        try await userEntryStore.add(descriptor)
        isPresentingEntryForm = false
        entryDraft = UserEntryDraft()
        await reloadUserEntries()
        await refreshInstallState()
    }

    /// Removes a custom entry's on-disk JSON record. Never throws — a
    /// failure is surfaced via `presentedError`, matching every other
    /// disk-touching action in this model.
    func removeUserEntry(id: String) async {
        do {
            try await userEntryStore.remove(id: id)
            await reloadUserEntries()
            await refreshInstallState()
        } catch {
            presentedError = Self.message(for: error)
        }
    }

    func beginRemoveUserEntry(id: String) {
        operationTasks[id]?.cancel()
        operationTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.removeUserEntry(id: id)
            self.operationTasks[id] = nil
        }
    }

    static func makeDescriptor(from draft: UserEntryDraft) throws -> ServerDescriptor {
        let id = draft.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CatalogModelError.emptyID }

        let languageIDs =
            draft.languageIDsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !languageIDs.isEmpty else { throw CatalogModelError.emptyLanguageIDs }

        let trimmedDisplayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedDisplayName.isEmpty ? id : trimmedDisplayName
        let launchArguments =
            draft.launchArgumentsText
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let license = draft.license.trimmingCharacters(in: .whitespacesAndNewlines)

        switch draft.sourceKind {
        case .httpsReleaseAsset:
            let trimmedURL = draft.assetURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedURL), url.scheme == "https" else {
                throw CatalogModelError.invalidHTTPSURL
            }
            let relativePath = draft.binaryRelativePath.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !relativePath.isEmpty else { throw CatalogModelError.emptyBinaryRelativePath }

            return ServerDescriptor(
                id: id,
                languageIDs: languageIDs,
                displayName: displayName,
                kind: .singleBinary,
                source: ServerSource(
                    url: url,
                    version: draft.version.trimmingCharacters(in: .whitespacesAndNewlines),
                    checksum: nil,
                    license: license,
                    estimatedBytes: nil
                ),
                launchArguments: launchArguments,
                archive: ArchiveLayout(
                    format: draft.archiveFormat, binaryRelativePath: relativePath),
                initializationOptions: nil,
                prerequisites: []
            )

        case .localBinary:
            let trimmedPath = draft.localBinaryPathText.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { throw CatalogModelError.invalidLocalPath }

            return ServerDescriptor(
                id: id,
                languageIDs: languageIDs,
                displayName: displayName,
                kind: .singleBinary,
                source: ServerSource(
                    url: URL(fileURLWithPath: trimmedPath),
                    version: "local",
                    checksum: nil,
                    license: license,
                    estimatedBytes: nil
                ),
                launchArguments: launchArguments,
                archive: nil,
                initializationOptions: nil,
                prerequisites: []
            )
        }
    }

    // MARK: - Shared helpers

    private func descriptor(forID id: String) -> ServerDescriptor? {
        rows.first(where: { $0.id == id })?.descriptor
            ?? userRows.first(where: { $0.id == id })?.descriptor
    }

    private func setProgress(id: String, active: Bool) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].progressActive = active
        }
        if let index = userRows.firstIndex(where: { $0.id == id }) {
            userRows[index].progressActive = active
        }
        if let index = packs.firstIndex(where: { $0.id == id }) {
            packs[index].progressActive = active
        }
    }

    /// The single funnel every install/update/uninstall/pack action routes
    /// through: cancels any prior operation for `id`, marks its row as
    /// in-progress, runs `operation` in a structured `Task`, and — win,
    /// lose, or cancelled — always clears progress and refreshes install
    /// state afterward so the row never gets stuck mid-flight.
    private func beginOperation(
        id: String,
        _ operation: @escaping @MainActor (LanguageServersCatalogModel) async throws -> Void
    ) {
        operationTasks[id]?.cancel()
        setProgress(id: id, active: true)
        operationTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(self)
            } catch is CancellationError {
                // A user-initiated cancel; the row simply resets below.
            } catch {
                self.presentedError = Self.message(for: error)
            }
            self.setProgress(id: id, active: false)
            self.operationTasks[id] = nil
            await self.refreshInstallState()
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case CatalogModelError.emptyID:
            return "Enter a server id."
        case CatalogModelError.duplicateID:
            return "A server with this id already exists."
        case CatalogModelError.emptyLanguageIDs:
            return "Enter at least one language id."
        case CatalogModelError.invalidHTTPSURL:
            return "Enter a valid https:// asset URL."
        case CatalogModelError.emptyBinaryRelativePath:
            return "Enter the binary's path inside the downloaded archive."
        case CatalogModelError.invalidLocalPath:
            return "Enter the local binary's path."
        case UserEntryStoreError.insecureSourceURL:
            return "Custom servers may only use an https:// download or a local file path."
        case ServerInstallError.checksumMismatch:
            return "The downloaded file didn't match the expected checksum and was discarded."
        case ServerInstallError.downloadFailed:
            return "The download failed."
        case ServerInstallError.binaryMissing:
            return "The expected binary wasn't found after installing."
        case ServerInstallError.pathTraversal:
            return "The downloaded archive contained an unsafe path and was rejected."
        case ServerInstallError.unsupportedArchive:
            return "The downloaded file wasn't in a supported archive format."
        case ServerInstallError.unpackFailed:
            return "The downloaded archive couldn't be unpacked and was discarded."
        default:
            return "The operation failed."
        }
    }
}
