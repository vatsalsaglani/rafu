import Foundation
import Observation

/// A weak, URI-keyed reference to one open `EditorDocument`, paired with
/// the LSP languageID it was opened under — enough for
/// `OpenDocumentIndex.snapshots(languageID:)` to rebuild a `didOpen` replay
/// list without ever storing document text itself; the text is read fresh
/// from `textSnapshotProvider()` at replay time, and only for documents
/// that are still mounted.
@MainActor
private final class WeakDocumentBox {
    weak var document: EditorDocument?
    let languageID: String

    init(document: EditorDocument, languageID: String) {
        self.document = document
        self.languageID = languageID
    }
}

/// The seam `LanguageServerManager`'s `snapshotProvider` reads through to
/// replay `didOpen` for every already-open document of a lazily-started
/// server's languageID, on the main actor, without the manager (a bare
/// `actor`) reaching into `EditorDocument` directly.
///
/// A plain reference type — not a stored dictionary directly on
/// `LanguageIntelligenceCoordinator` — because Swift forbids capturing
/// `self` in a closure formed during `init()` before every stored property,
/// including `manager` itself, is definitely assigned. Building this index
/// first, as a local, and handing the *index* (never `self`) to
/// `LanguageServerManager`'s `snapshotProvider` closure sidesteps that
/// restriction entirely.
@MainActor
private final class OpenDocumentIndex {
    private var boxes: [String: WeakDocumentBox] = [:]

    func register(uri: String, document: EditorDocument, languageID: String) {
        boxes[uri] = WeakDocumentBox(document: document, languageID: languageID)
    }

    func remove(uri: String) {
        boxes.removeValue(forKey: uri)
    }

    func removeAll() {
        boxes.removeAll()
    }

    /// Every open document for `languageID` with live text available right
    /// now. A document whose `textSnapshotProvider` is `nil` (unmounted) is
    /// silently skipped — its replay is simply missed, the accepted
    /// increment C2 contract.
    func snapshots(languageID: String) -> [LanguageServerManager.DocumentSnapshot] {
        boxes.values.compactMap { box in
            guard box.languageID == languageID, let document = box.document,
                let text = document.textSnapshotProvider?()
            else { return nil }
            return LanguageServerManager.DocumentSnapshot(
                uri: fileURI(forPath: document.url.path), languageID: languageID, text: text)
        }
    }
}

/// Observable per-languageID server status, exposed for a future status/
/// settings UI (increment C4). Never holds document text or request/
/// response payloads — see `LanguageServerStatus`.
@Observable
@MainActor
final class LanguageServerStatusStore {
    private(set) var statuses: [String: LanguageServerStatus] = [:]

    func update(_ status: LanguageServerStatus) {
        statuses[status.languageID] = status
    }

    func clear() {
        statuses.removeAll()
    }
}

/// The only seam lane 2 (LSP / language intelligence) needs into
/// `WorkspaceSession` and `EditorDocument`. `WorkspaceSession` owns exactly
/// one instance and calls these lifecycle hooks around workspace
/// open/close/replace and document open/close; lane 2 never edits
/// `WorkspaceSession.swift` or the `Navigation/` types directly, only this
/// file (and the rest of `Sources/RafuApp/LanguageIntelligence/`).
///
/// Every hook is synchronous — `WorkspaceSession` calls them inline from
/// its own `@MainActor`-isolated code — so each one that needs to reach the
/// bare-`actor` `LanguageServerManager` wraps that work in an independent
/// `Task`. Because these `Task`s are independent, nothing guarantees
/// `documentDidOpen`/`documentDidClose` calls arrive in any particular
/// order relative to `workspaceDidOpen`; `LanguageServerManager` is built
/// to tolerate that (documents may be recorded before a root is active).
@Observable
@MainActor
final class LanguageIntelligenceCoordinator {
    @ObservationIgnored
    private let manager: LanguageServerManager

    /// Per-languageID server status, observable for a future status UI.
    let servers: LanguageServerStatusStore

    /// One subscription task per currently open document, forwarding its
    /// `editDeltas()` stream to `manager.documentChanged`. Cancelled and
    /// removed in `documentDidClose(_:)`; all cancelled in
    /// `workspaceDidClose()`.
    @ObservationIgnored
    private var editSubscriptions: [EditorDocument.ID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private let openDocuments = OpenDocumentIndex()

    /// The box `manager`'s `DynamicLanguageServerResolver` reads through.
    /// `workspaceDidOpen(root:)` rebuilds a fresh `InstalledServerResolver`
    /// into this box on every workspace switch; `workspaceDidClose()`
    /// clears it back to `nil` (decline everything). Swapping this box's
    /// contents never rebuilds `manager` itself, so its live servers/crash
    /// state survive a workspace switch untouched — see
    /// `LanguageServerResolverBox`'s doc comment.
    @ObservationIgnored
    private let resolverBox: LanguageServerResolverBox

    /// A pending "run this untrusted-but-installed server?" request, raised
    /// by `session(forLanguageID:)` when the manager declines a languageID
    /// that resolves to an installed/discoverable server this workspace
    /// simply hasn't approved yet. Built for the C4 trust flow; mounting a
    /// prompt UI keyed off this property is deferred to a
    /// `Views/`-owned integration edit (outside lane 2's C4 paths) — see
    /// `LanguageServerTrustPromptView`'s doc comment.
    private(set) var pendingTrustRequest: TrustRequest?

    /// A stable, opaque identifier for the currently open workspace root,
    /// used as `WorkspaceTrustStore`'s per-workspace key. `nil` when no
    /// workspace is open.
    @ObservationIgnored
    private var workspaceKey: String?

    @ObservationIgnored
    private let trustStore: WorkspaceTrustStore

    @ObservationIgnored
    private let userEntryStore: UserEntryStore

    @ObservationIgnored
    private let layout: InstallLayout

    /// Server ids explicitly declined for the current workspace this
    /// session — never persisted (an explicit decline only lasts until the
    /// user changes it in Settings or reopens the workspace); cleared on
    /// `workspaceDidClose()`.
    @ObservationIgnored
    private var declinedServerIDs: Set<String> = []

    /// Server ids explicitly trusted for the current workspace, merged
    /// from `WorkspaceTrustStore` on every resolver-snapshot rebuild and
    /// updated immediately by `approveTrust(_:)`. Cleared on
    /// `workspaceDidClose()`.
    @ObservationIgnored
    private var trustedServerIDs: Set<String> = []

    /// A cache of the current workspace's user-added descriptors, refreshed
    /// by every `rebuildResolverSnapshot` — lets `session(forLanguageID:)`
    /// find a pending-trust candidate synchronously, without re-reading
    /// `UserEntryStore` on every declined session request.
    @ObservationIgnored
    private var cachedUserEntries: [ServerDescriptor] = []

    @ObservationIgnored
    private var discoveredGoplsURL: URL?

    @ObservationIgnored
    private var discoveredSourceKitLSPURL: URL?

    init() {
        let store = LanguageServerStatusStore()
        let index = openDocuments
        let box = LanguageServerResolverBox()
        resolverBox = box
        servers = store
        trustStore = WorkspaceTrustStore()
        userEntryStore = UserEntryStore()
        layout = InstallLayout()
        manager = LanguageServerManager(
            resolver: DynamicLanguageServerResolver(box: box),
            // Post-merge integration: register language-server pids into the
            // process-wide shared registry so lane 1's Resources surface
            // attributes their memory alongside terminal shells.
            registry: ProcessResourceRegistry.shared,
            statusSink: { status in
                store.update(status)
            },
            snapshotProvider: { languageID in
                await MainActor.run { index.snapshots(languageID: languageID) }
            }
        )
    }

    /// Dependency-injecting initializer for tests. Frozen (C2): the
    /// resolver box, trust store, user-entry store, and install layout all
    /// fall back to their real (unused-by-these-tests) defaults.
    init(manager: LanguageServerManager, servers: LanguageServerStatusStore) {
        self.manager = manager
        self.servers = servers
        self.resolverBox = LanguageServerResolverBox()
        self.trustStore = WorkspaceTrustStore()
        self.userEntryStore = UserEntryStore()
        self.layout = InstallLayout()
    }

    /// Dependency-injecting initializer for the C4 trust-flow tests. The
    /// caller must construct `manager` with
    /// `resolver: DynamicLanguageServerResolver(box: resolverBox)` using
    /// this same `resolverBox` instance, so the coordinator's later
    /// `resolverBox.set(...)` calls actually reach `manager`.
    init(
        manager: LanguageServerManager,
        servers: LanguageServerStatusStore,
        resolverBox: LanguageServerResolverBox,
        trustStore: WorkspaceTrustStore,
        userEntryStore: UserEntryStore,
        layout: InstallLayout
    ) {
        self.manager = manager
        self.servers = servers
        self.resolverBox = resolverBox
        self.trustStore = trustStore
        self.userEntryStore = userEntryStore
        self.layout = layout
    }

    func workspaceDidOpen(root: URL) {
        let uri = fileURI(forPath: root.path)
        let manager = manager
        Task { await manager.activate(rootURI: uri) }

        let workspaceKey = root.standardizedFileURL.path
        self.workspaceKey = workspaceKey
        declinedServerIDs = []
        pendingTrustRequest = nil
        rebuildResolverSnapshot(workspaceKey: workspaceKey)
    }

    func workspaceDidClose() {
        for task in editSubscriptions.values {
            task.cancel()
        }
        editSubscriptions.removeAll()
        openDocuments.removeAll()
        let manager = manager
        Task { await manager.deactivate() }
        servers.clear()

        resolverBox.set(nil)
        pendingTrustRequest = nil
        workspaceKey = nil
        declinedServerIDs.removeAll()
        trustedServerIDs.removeAll()
        cachedUserEntries = []
        discoveredGoplsURL = nil
        discoveredSourceKitLSPURL = nil
    }

    func documentDidOpen(_ document: EditorDocument) {
        guard let languageID = LanguageIdentifier.forURL(document.url) else { return }
        let uri = fileURI(forPath: document.url.path)
        openDocuments.register(uri: uri, document: document, languageID: languageID)

        let manager = manager
        let initialText = document.textSnapshotProvider?() ?? ""
        Task {
            await manager.documentOpened(
                snapshot: LanguageServerManager.DocumentSnapshot(
                    uri: uri, languageID: languageID, text: initialText))
        }

        let task = Task {
            for await delta in document.editDeltas() {
                guard let text = document.textSnapshotProvider?() else { continue }
                await manager.documentChanged(
                    uri: uri, languageID: languageID, delta: delta, newFullText: text)
            }
        }
        editSubscriptions[document.id] = task
    }

    func documentDidClose(_ document: EditorDocument) {
        editSubscriptions.removeValue(forKey: document.id)?.cancel()
        guard let languageID = LanguageIdentifier.forURL(document.url) else { return }
        let uri = fileURI(forPath: document.url.path)
        openDocuments.remove(uri: uri)
        let manager = manager
        Task { await manager.documentClosed(uri: uri, languageID: languageID) }
    }

    /// The only entry point a future navigation provider (increment C5)
    /// needs; never registered with `NavigationLadder` here. When the
    /// manager declines, checks whether `languageID` resolves to an
    /// installed-but-untrusted server and, if so, raises
    /// `pendingTrustRequest` for a future trust-prompt UI to consume.
    func session(forLanguageID languageID: String) async -> LanguageServerSession? {
        if let session = await manager.ensureSession(languageID: languageID) {
            return session
        }
        await computePendingTrustRequest(languageID: languageID)
        return nil
    }

    /// Records the user's explicit approval, persists it for this
    /// workspace, and rebuilds the resolver snapshot so the next
    /// `session(forLanguageID:)` call can resolve immediately.
    func approveTrust(_ request: TrustRequest) {
        guard let workspaceKey else {
            pendingTrustRequest = nil
            return
        }
        trustedServerIDs.insert(request.serverID)
        declinedServerIDs.remove(request.serverID)
        pendingTrustRequest = nil

        let trustStore = trustStore
        Task { [weak self] in
            try? await trustStore.approve(
                serverID: request.serverID, forWorkspaceKey: workspaceKey)
            guard let self, self.workspaceKey == workspaceKey else { return }
            self.rebuildResolverSnapshot(workspaceKey: workspaceKey)
        }
    }

    /// Records the decline for this session only — never persisted —
    /// falling through exactly like an unresolved languageID until the
    /// user changes it in Settings or reopens the workspace.
    func declineTrust(_ request: TrustRequest) {
        declinedServerIDs.insert(request.serverID)
        pendingTrustRequest = nil
    }

    // MARK: - Resolver snapshot

    /// Rebuilds a fresh `InstalledServerResolver` for `workspaceKey` off
    /// the main actor — loading user entries and trust approvals from
    /// disk, and discovering the Node runtime/gopls/SourceKit-LSP toolchain
    /// (the latter two via `Task.detached`, since they may spawn a real
    /// process) — and swaps it into `resolverBox`. If the workspace has
    /// since changed (or closed) by the time this completes, the stale
    /// result is discarded rather than adopted.
    private func rebuildResolverSnapshot(workspaceKey: String) {
        let trustStore = trustStore
        let userEntryStore = userEntryStore
        let layout = layout

        Task { [weak self] in
            guard let self else { return }
            let userEntries = (try? await userEntryStore.load()) ?? []
            let trustFile = try? await trustStore.load()
            let trustedFromDisk = Set(trustFile?.approvals[workspaceKey] ?? [])

            let (nodeExecutableURL, goplsURL, sourceKitURL) = await Task.detached(
                priority: .utility
            ) { () -> (URL?, URL?, URL?) in
                (
                    NodeRuntimeLocator.installedExecutableURL(layout: layout),
                    InstalledServerResolver.discoverGopls(),
                    InstalledServerResolver.discoverSourceKitLSP()
                )
            }.value

            guard self.workspaceKey == workspaceKey else { return }
            self.trustedServerIDs.formUnion(trustedFromDisk)
            self.cachedUserEntries = userEntries
            self.discoveredGoplsURL = goplsURL
            self.discoveredSourceKitLSPURL = sourceKitURL

            // An immutable snapshot, not a live reference back into
            // `self` — `isTrusted` must never need to hop back to the
            // main actor from inside `InstalledServerResolver.resolve`,
            // which `LanguageServerManager` calls from its own actor.
            let trusted = self.trustedServerIDs
            let resolver = InstalledServerResolver(
                userEntries: userEntries,
                layout: layout,
                nodeExecutableURL: nodeExecutableURL,
                goplsExecutableURL: goplsURL,
                sourceKitLSPExecutableURL: sourceKitURL,
                isTrusted: { serverID in trusted.contains(serverID) }
            )
            self.resolverBox.set(resolver)
        }
    }

    // MARK: - Trust prompt candidate

    private func computePendingTrustRequest(languageID: String) async {
        guard pendingTrustRequest == nil else { return }
        guard let descriptor = candidateDescriptor(languageID: languageID) else { return }
        guard !trustedServerIDs.contains(descriptor.id), !declinedServerIDs.contains(descriptor.id)
        else { return }

        let layout = layout
        let goplsURL = discoveredGoplsURL
        let sourceKitURL = discoveredSourceKitLSPURL
        let installed = await Task.detached(priority: .utility) {
            Self.isInstalledOrDiscoverable(
                descriptor, layout: layout, goplsURL: goplsURL, sourceKitURL: sourceKitURL)
        }.value
        guard installed else { return }

        pendingTrustRequest = TrustRequest(
            serverID: descriptor.id, displayName: descriptor.displayName, languageID: languageID)
    }

    /// Searches user entries before the curated catalog, exactly matching
    /// `InstalledServerResolver.resolve(languageID:)`'s own search order.
    private func candidateDescriptor(languageID: String) -> ServerDescriptor? {
        (cachedUserEntries + CuratedCatalog.servers).first {
            $0.languageIDs.contains(languageID)
        }
    }

    private nonisolated static func isInstalledOrDiscoverable(
        _ descriptor: ServerDescriptor, layout: InstallLayout, goplsURL: URL?, sourceKitURL: URL?
    ) -> Bool {
        switch descriptor.kind {
        case .localDiscovery:
            switch descriptor.id {
            case "gopls": return goplsURL != nil
            case "sourcekit-lsp": return sourceKitURL != nil
            default: return false
            }
        case .singleBinary, .nodeHosted:
            if let source = descriptor.source, source.url.isFileURL {
                return FileManager.default.isExecutableFile(atPath: source.url.path)
            }
            guard let binaryURL = layout.installedBinaryURL(descriptor: descriptor) else {
                return false
            }
            return FileManager.default.isExecutableFile(atPath: binaryURL.path)
        }
    }
}
