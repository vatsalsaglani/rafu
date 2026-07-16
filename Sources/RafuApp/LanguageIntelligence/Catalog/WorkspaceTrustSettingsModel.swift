import Foundation
import Observation

/// Drives Settings > Language Servers' "Workspace Trust" section: lists
/// every workspace/server approval `WorkspaceTrustStore` has persisted and
/// lets a user revoke one. Deliberately separate from
/// `LanguageServersCatalogModel` — this is workspace trust (which
/// workspaces may run which server), not install state, and reads a
/// completely different on-disk store.
///
/// Mirrors `LanguageServersCatalogModel`'s shape — an `@Observable
/// @MainActor` model with an `@ObservationIgnored` dependency,
/// `.task { await model.load() }` guarded by `hasLoaded`, and revoke
/// launching an independent, cancellable `Task` rather than blocking a view
/// action. Revoking only edits the trust JSON: it never tears down a
/// currently-running language server for that workspace (see the footer
/// text `LanguageServersSettingsSection` shows beside this list).
@Observable
@MainActor
final class WorkspaceTrustSettingsModel {
    /// One workspace/server approval, flattened for row display.
    /// `workspaceDisplayName` and `workspacePath` are precomputed here so
    /// the view never parses a path in `body`.
    nonisolated struct TrustApprovalRow: Identifiable, Sendable, Equatable {
        var id: String { "\(workspaceKey)#\(serverID)" }
        let workspaceKey: String
        let workspaceDisplayName: String
        let serverID: String
    }

    private(set) var rows: [TrustApprovalRow] = []
    var presentedError: String?

    @ObservationIgnored private let store: WorkspaceTrustStore
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var revokeTasks: [String: Task<Void, Never>] = [:]

    init(store: WorkspaceTrustStore = WorkspaceTrustStore()) {
        self.store = store
    }

    isolated deinit {
        for task in revokeTasks.values {
            task.cancel()
        }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    /// Revokes `row`'s approval, then reloads from disk so the list always
    /// reflects what `WorkspaceTrustStore` actually persisted (rather than
    /// optimistically removing the row and risking drift on failure).
    func revoke(_ row: TrustApprovalRow) {
        revokeTasks[row.id]?.cancel()
        revokeTasks[row.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.revoke(
                    serverID: row.serverID, forWorkspaceKey: row.workspaceKey)
            } catch {
                self.presentedError = "Couldn't revoke this approval. Try again."
            }
            await self.reload()
            self.revokeTasks[row.id] = nil
        }
    }

    private func reload() async {
        do {
            let file = try await store.load()
            rows = Self.rows(from: file).sorted(by: Self.isOrderedBefore)
        } catch {
            presentedError = "Couldn't load workspace trust approvals."
            rows = []
        }
    }

    /// Flattens `TrustFile.approvals` (workspace key → server ids) into one
    /// row per approval. `workspaceKey` is a `standardizedFileURL.path`
    /// (see `LanguageIntelligenceCoordinator`), so its last path component
    /// is a reasonable, stable display name.
    nonisolated static func rows(from file: TrustFile) -> [TrustApprovalRow] {
        file.approvals.flatMap { workspaceKey, serverIDs in
            serverIDs.map { serverID in
                TrustApprovalRow(
                    workspaceKey: workspaceKey,
                    workspaceDisplayName: (workspaceKey as NSString).lastPathComponent,
                    serverID: serverID
                )
            }
        }
    }

    nonisolated static func isOrderedBefore(_ lhs: TrustApprovalRow, _ rhs: TrustApprovalRow)
        -> Bool
    {
        if lhs.workspaceDisplayName != rhs.workspaceDisplayName {
            return lhs.workspaceDisplayName < rhs.workspaceDisplayName
        }
        if lhs.workspaceKey != rhs.workspaceKey { return lhs.workspaceKey < rhs.workspaceKey }
        return lhs.serverID < rhs.serverID
    }
}
