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
    typealias CredentialResolver =
        @Sendable ([UsageProviderID], Date) async -> [UsageProviderID: String]

    let descriptors: [UsageProviderDescriptor]
    let makeContext: @Sendable (Date) async -> UsageFetchContext
    let isEnabled: @Sendable (UsageProviderID) -> Bool
    let resolveCredentials: CredentialResolver

    init(
        descriptors: [UsageProviderDescriptor] = UsageProviderRegistry.all,
        makeContext: @escaping @Sendable (Date) async -> UsageFetchContext = UsageRegistryReader
            .productionContext,
        isEnabled: @escaping @Sendable (UsageProviderID) -> Bool = UsageRegistryReader
            .productionIsEnabled,
        resolveCredentials: @escaping CredentialResolver = UsageRegistryReader
            .productionCredentials
    ) {
        self.descriptors = descriptors
        self.makeContext = makeContext
        self.isEnabled = isEnabled
        self.resolveCredentials = resolveCredentials
    }

    /// Resolves every enabled, strategy-bearing descriptor through
    /// `resolveUsageSnapshot(strategies:context:)`, in registry order,
    /// keeping only snapshots that are `renderable`. A single shared
    /// `UsageFetchContext` (built once from `now`) serves every provider —
    /// providers read whichever slice of it they need (`credential`/
    /// `cookieHeader` are keyed by `UsageProviderID`).
    func snapshots(now: Date) async -> [UsageSnapshot] {
        let enabledDescriptors = descriptors.filter { isEnabled($0.id) }
        let resolvedCredentials = await resolveCredentials(
            enabledDescriptors.map(\.id), now)
        let baseContext = await makeContext(now)
        let context = UsageFetchContext(
            now: baseContext.now,
            readFile: baseContext.readFile,
            http: baseContext.http,
            credential: { id in resolvedCredentials[id] ?? baseContext.credential(id) },
            cookieHeader: baseContext.cookieHeader)

        var results: [UsageSnapshot] = []
        for descriptor in enabledDescriptors {
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
            // `snapshots(now:)` overlays its pre-resolved immutable map on
            // this base closure before any strategy sees the context.
            credential: { _ in nil },
            // Cookie import lands in W1 — until then, no provider has one.
            cookieHeader: { _ in nil }
        )
    }

    static func productionIsEnabled(_ id: UsageProviderID) -> Bool {
        guard let descriptor = UsageProviderRegistry.descriptor(for: id) else { return false }
        return UsageEnableStore().isEnabled(id, default: descriptor.defaultEnabled)
    }

    /// Auth-file and Keychain reads are pre-resolved off the caller's actor,
    /// then captured as immutable strings by the synchronous context closure.
    /// External OAuth credentials require separate network consent and never
    /// use Rafu's persistent Keychain namespace.
    @concurrent
    static func productionCredentials(
        _ ids: [UsageProviderID], now: Date
    ) async -> [UsageProviderID: String] {
        let consentStore = UsageNetworkConsentStore()
        var credentials: [UsageProviderID: String] = [:]

        for id in ids {
            switch id {
            case .claude, .codex:
                guard consentStore.hasConsent(for: id) else { continue }

                if let contents = UsageOAuthConnector.productionCredentialFile(for: id) {
                    let envelope: UsageExternalCredentialEnvelope?
                    switch id {
                    case .claude:
                        envelope = UsageExternalCredentialParser.claude(contents: contents)
                    case .codex:
                        envelope = UsageExternalCredentialParser.codex(contents: contents)
                    default:
                        envelope = nil
                    }
                    if let envelope, envelope.isUsable(for: id, at: now),
                        let encoded = envelope.encoded()
                    {
                        credentials[id] = encoded
                        continue
                    }
                }

                if let transient = await UsageCredentialStore.shared
                    .transientExternalCredential(for: id),
                    let envelope = UsageExternalCredentialEnvelope.parse(transient),
                    envelope.isUsable(for: id, at: now)
                {
                    credentials[id] = transient
                }
            default:
                if let credential = try? await UsageCredentialStore.shared.credential(for: id) {
                    credentials[id] = credential
                }
            }
        }
        return credentials
    }
}
