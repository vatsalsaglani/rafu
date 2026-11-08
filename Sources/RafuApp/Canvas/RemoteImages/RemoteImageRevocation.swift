import Foundation

/// Reaches every open Ensemble's image provider, so removing a grant drops the
/// images it allowed at once, in every window. Providers register themselves
/// and are held weakly: a closed Ensemble needs no cleanup here.
@MainActor
final class RemoteImageRevocation {
    static let shared = RemoteImageRevocation()

    private struct Weak {
        weak var provider: RemoteImageProvider?
    }

    private var providers: [Weak] = []

    init() {}

    func register(_ provider: RemoteImageProvider) {
        providers.removeAll { $0.provider == nil }
        guard !providers.contains(where: { $0.provider === provider }) else { return }
        providers.append(Weak(provider: provider))
    }

    /// The live providers, for tests.
    var liveProviders: [RemoteImageProvider] { providers.compactMap(\.provider) }

    func provider(for board: CanvasID) -> RemoteImageProvider? {
        providers.compactMap(\.provider).first { $0.boardID == board }
    }

    /// A trust-list pattern was removed.
    func dropPattern(_ pattern: String) {
        drop { $0 == .pattern(pattern) }
    }

    /// The user revoked consent for one Ensemble.
    func dropEnsemble(_ id: CanvasID) {
        drop { $0 == .ensemble(id) }
    }

    /// The global setting left Always allow.
    func dropGlobal() {
        drop { $0 == .global }
    }

    /// The global setting is Off, or the trust list was cleared: nothing stays.
    func dropAll() {
        drop { _ in true }
    }

    private func drop(where matches: (RemoteImageGrant) -> Bool) {
        providers.removeAll { $0.provider == nil }
        for entry in providers { entry.provider?.dropCached(where: matches) }
    }
}

/// Writes and removes one Ensemble's consent. Both go through `edit`, so each
/// is one undo step. Only the consent card and the Agent control panel call
/// these; no agent tool does.
@MainActor
enum RemoteImageConsentWriter {
    static func grant(on board: CanvasBoardState, now: Date = Date()) throws {
        try board.edit { document in
            var permissions = document.permissions ?? CanvasPermissions()
            permissions.remoteImages = CanvasRemoteImageConsent(
                allowed: true, grantedAt: now, grantedBy: "user")
            document.permissions = permissions
        }
    }

    static func revoke(on board: CanvasBoardState) throws {
        try board.edit { document in
            document.permissions?.remoteImages = nil
            if document.permissions?.remoteImages == nil { document.permissions = nil }
        }
    }
}
