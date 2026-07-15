import Foundation

/// A named bundle of catalog server ids that share one managed runtime,
/// installed together as a single user action from the Settings "Packs"
/// disclosure rather than one server at a time. Every `serverIDs` entry
/// must name an id present in `CuratedCatalog.servers` — `ServerPackTests`
/// enforces this so a pack can never reference a removed or renamed
/// catalog entry.
nonisolated struct ServerPack: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let serverIDs: [String]

    /// Whether every member shares one `NodeRuntimeManager`-managed Node
    /// runtime, so installing the pack only needs to
    /// `ensureInstalled(consentToQuarantineRemoval:)` once rather than once
    /// per member.
    let sharedRuntime: Bool
}

extension ServerPack {
    /// The single batching example this increment ships: Pyright and
    /// typescript-language-server both run under the one pinned Node
    /// runtime `NodeRuntimeManager` installs. (Installing
    /// typescript-language-server this way still only unpacks its release
    /// tarball — see `CuratedCatalog`'s note on why that alone isn't yet a
    /// runnable server.)
    static let all: [ServerPack] = [
        ServerPack(
            id: "node-web-tools",
            displayName: "Web & Python (Node-hosted)",
            serverIDs: ["pyright", "typescript-language-server"],
            sharedRuntime: true
        )
    ]
}
