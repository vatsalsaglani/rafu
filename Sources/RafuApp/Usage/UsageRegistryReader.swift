import Foundation

/// The `NotchCompanionModel`-facing seam: resolves a `[UsageSnapshot]`
/// across every ENABLED provider in a registry, in registry order, hiding
/// disabled providers, providers with no strategies (stubs), and providers
/// whose pipeline produced nothing renderable. Injectable (mirrors
/// `AgentUsageReader`'s pre-W0 shape) so a headless test can supply fixture
/// descriptors and never touch `~`, the network, or Keychain.
///
/// NOT explicitly named in usage-providers/W0-shim.md's "Created" file
/// list, but required by its exact-signature block — lives in `Usage/` as
/// a W0-owned file alongside the rest of the shared shim; see the W0
/// handoff for this (documented, non-behavioral) addition.
nonisolated struct UsageRegistryReader: Sendable {
    let descriptors: [UsageProviderDescriptor]
    let makeContext: @Sendable (Date) -> UsageFetchContext
    let isEnabled: @Sendable (UsageProviderID) -> Bool

    init(
        descriptors: [UsageProviderDescriptor] = UsageProviderRegistry.all,
        makeContext: @escaping @Sendable (Date) -> UsageFetchContext = UsageRegistryReader
            .productionContext,
        isEnabled: @escaping @Sendable (UsageProviderID) -> Bool = UsageRegistryReader
            .productionIsEnabled
    ) {
        self.descriptors = descriptors
        self.makeContext = makeContext
        self.isEnabled = isEnabled
    }

    /// Resolves every enabled, strategy-bearing descriptor through
    /// `resolveUsageSnapshot(strategies:context:)`, in registry order,
    /// keeping only snapshots that are `renderable`. A single shared
    /// `UsageFetchContext` (built once from `now`) serves every provider —
    /// providers read whichever slice of it they need (`credential`/
    /// `cookieHeader` are keyed by `UsageProviderID`).
    func snapshots(now: Date) async -> [UsageSnapshot] {
        let context = makeContext(now)
        var results: [UsageSnapshot] = []
        for descriptor in descriptors {
            guard isEnabled(descriptor.id) else { continue }
            let strategies = descriptor.makeStrategies(context)
            guard !strategies.isEmpty else { continue }
            guard
                let snapshot = await resolveUsageSnapshot(
                    strategies: strategies, context: context),
                snapshot.renderable
            else { continue }
            results.append(snapshot)
        }
        return results
    }

    // MARK: - Production defaults

    /// Reads a single file at `path` UNDER the user's home directory —
    /// bounded to exactly the contract's single-file shape (see
    /// `UsageFetchContext.readFile`'s doc comment). No W0 strategy calls
    /// this; it exists for a future single-file consumer (e.g. an
    /// `auth.json`/token-file read).
    static func productionContext(_ now: Date) -> UsageFetchContext {
        UsageFetchContext(
            now: now,
            readFile: { path in
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(path)
                return try? String(contentsOf: url, encoding: .utf8)
            },
            http: UsageHTTPClient(),
            // No W0 strategy reads a credential — bridging
            // `UsageCredentialStore`'s actor-isolated reads into this
            // SYNCHRONOUS closure is left to whichever phase adds the
            // first credentialed strategy; see the W0 handoff.
            credential: { _ in nil },
            // Cookie import lands in W1 — until then, no provider has one.
            cookieHeader: { _ in nil }
        )
    }

    static func productionIsEnabled(_ id: UsageProviderID) -> Bool {
        guard let descriptor = UsageProviderRegistry.descriptor(for: id) else { return false }
        return UsageEnableStore().isEnabled(id, default: descriptor.defaultEnabled)
    }
}
