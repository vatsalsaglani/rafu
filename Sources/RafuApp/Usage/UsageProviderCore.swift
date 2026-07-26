import Foundation

/// The agent-usage provider contract (usage-providers/W0-shim.md): every
/// later phase (W1–W8) compiles against the names in this file verbatim —
/// treat them as a binding, additive-only surface. `UsageProviderRegistry`
/// lists the 19 roster descriptors; `UsageProviderDescriptor.makeStrategies`
/// resolves an ordered list of `UsageFetchStrategy`s that
/// `resolveUsageSnapshot(strategies:context:)` tries in order.
///
/// Every type here is pure/value-typed and declared `nonisolated` directly
/// in its PRIMARY declaration (never a bare `extension`) — `RafuApp`'s
/// `.defaultIsolation(MainActor.self)` does not propagate `nonisolated`
/// into a later `extension` block, which would otherwise silently become
/// `@MainActor` and trap (`SIGTRAP`) the first time it runs off-main (see
/// `docs/references/nonisolated-extension-isolation-trap.md`, and
/// `NotchCompanionPolicy.swift`'s `CompanionEditorRow` for the established
/// pattern this file follows).

/// The 19-provider roster (agent-usage-providers.md, "Provider roster").
/// `.claude`/`.codex` list first for detection-order parity with the
/// shipped companion strip (terminal-notch-hud.md NC-D).
nonisolated enum UsageProviderID: String, CaseIterable, Codable, Sendable {
    case claude, codex, cline, openCode, openCodeGo, cursor, antigravity,
        grokBuild, geminiCLI, kiloCode, copilot, windsurf, amp,
        factoryDroid, openRouter, kimi, warp, qwen, qoder
}

/// One rate-limit window inside a `UsageSnapshot` — a real percentage OR a
/// token total, never both fabricated to fill the missing field (mirrors
/// the shipped `AgentUsageWindow`'s discipline).
nonisolated struct UsageWindow: Equatable, Sendable {
    /// "5h" / "7d" / "monthly" — a human label, not a raw window size.
    let label: String
    let percent: Double?
    let tokens: Int?
    let resetsAt: Date?
}

/// One provider's usage, as a fetch strategy resolves it. `renderable`
/// (usage-providers/W0-shim.md: "empty ⇒ tile hidden") is the ONE place
/// that decides visibility — no windows AND no cost line means nothing to
/// show, so `UsageRegistryReader`/`UsageDisplayPolicy` treat it as absent.
nonisolated struct UsageSnapshot: Equatable, Sendable {
    let providerID: UsageProviderID
    /// Empty when the provider has nothing to show for any window this
    /// refresh — see `renderable`.
    let windows: [UsageWindow]
    /// e.g. `"$3.20 of $12"` — optional, for cost-metered providers.
    let costLine: String?
    /// Account email/handle — Settings-only, NEVER rendered in the notch
    /// (agent-usage-providers.md, "Registration panel").
    let identity: String?

    /// `false` means this snapshot carries nothing worth showing — no
    /// window data and no cost line. Both `UsageRegistryReader.snapshots`
    /// and `UsageDisplayPolicy` treat a non-renderable snapshot as if the
    /// provider produced nothing at all.
    var renderable: Bool { !windows.isEmpty || costLine != nil }
}

/// How a provider authenticates (agent-usage-providers.md, "Registration
/// panel" + the roster's cookie-import addendum). Purely descriptive — the
/// Settings tab uses it to choose which (possibly disabled-placeholder)
/// affordance to render.
///
/// `piggybackNetwork` and `localSessionPiggyback` are BOTH "Rafu sends a
/// credential-bearing usage request on your behalf", but they differ in
/// where that credential lives, and therefore in what Connect can do:
///
/// - `piggybackNetwork` (Claude, Codex): Rafu loads the CLI's own OAuth
///   credential file (or, for Claude only, Claude Code's Keychain item) and
///   passes it through `UsageFetchContext.credential`. Connect succeeds only
///   if that documented credential source parses and is unexpired.
/// - `localSessionPiggyback` (Cursor, Antigravity, Gemini CLI, Kimi): the
///   credential never crosses into Rafu's own storage at all — the strategy
///   reads the vendor app's local session itself, at fetch time. There is no
///   credential for Rafu to "load", so Connect verifies (locally, with no
///   network) that a signed-in session exists and records network consent.
///
/// `unavailable` is the honest state for a rostered provider with no
/// obtainable signal: no Connect action exists, so Settings must not render
/// one. See `connectAffordance`.
nonisolated enum UsageAuthPattern: Sendable {
    case localZeroConfig, piggybackNetwork, localSessionPiggyback, apiKey, cookieImport,
        unavailable

    /// What a Connect button would actually do for this pattern — `.none`
    /// means Settings must NOT offer one. A Connect affordance that can only
    /// ever fail is worse than a stated limitation.
    var connectAffordance: UsageConnectAffordance {
        switch self {
        case .piggybackNetwork: .externalCredential
        case .localSessionPiggyback: .localSession
        case .localZeroConfig, .apiKey, .cookieImport, .unavailable: .none
        }
    }
}

/// The three honest outcomes of "can the user connect this provider?".
/// `UsageOAuthConnector.connect(_:affordance:now:)` switches on this rather
/// than on a hardcoded provider list, so a provider added without a
/// connection path reports `.unsupportedProvider` by construction instead of
/// silently reaching a `default: return nil` credential lookup.
nonisolated enum UsageConnectAffordance: Equatable, Sendable {
    /// Rafu loads the CLI's documented credential file/Keychain item.
    case externalCredential
    /// Rafu verifies the vendor app's local signed-in session, no network,
    /// and never copies the credential into its own storage.
    case localSession
    /// Nothing to connect. Settings renders a stated reason, not a button.
    case none
}

/// Everything a `UsageFetchStrategy` needs, injected so every strategy is
/// headless-testable without touching the real filesystem/network/Keychain.
///
/// `readFile` is a SINGLE-file reader (`path` under `~`) — it cannot
/// express the bounded multi-file directory scans the shipped Claude/Codex
/// local strategies need (newest-N-files-under-a-directory, tail-N-bytes).
/// W0 resolved this by having those two strategies depend on
/// `LocalUsageFiles`'s injectable closures directly instead of routing
/// through `readFile`; `readFile` stays in the contract unmodified for a
/// future single-file consumer (e.g. W3/W5's `auth.json`/token-file reads)
/// — see the W0 handoff for the full note.
nonisolated struct UsageFetchContext: Sendable {
    let now: Date
    let readFile: @Sendable (String) -> String?
    let http: UsageHTTPClient
    /// Rafu's OWN Keychain credential for this provider (never another
    /// app's token) — `nil` until the provider has one stored.
    let credential: @Sendable (UsageProviderID) -> String?
    /// An imported browser cookie header for this provider — `nil` until
    /// W1's cookie infrastructure lands.
    let cookieHeader: @Sendable (UsageProviderID) -> String?
}

/// One ordered step in a provider's fetch pipeline
/// (`resolveUsageSnapshot(strategies:context:)` tries these in order).
/// Explicitly `nonisolated` on the protocol itself (mirrors the shipped
/// `AISecretStoring`) — without it, `RafuApp`'s default `MainActor`
/// isolation would infer every requirement as `@MainActor`, making
/// conforming types unusable from the off-main refresh pipeline.
nonisolated protocol UsageFetchStrategy: Sendable {
    var id: String { get }
    func isAvailable(_ context: UsageFetchContext) async -> Bool
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot
    func shouldFallback(on error: Error) -> Bool
}

/// One provider's registry entry: identity, auth story, a plain-language
/// disclosure line, its default enablement, and the strategies it resolves
/// to for a given context. `defaultEnabled` is `true` ONLY for local
/// zero-config providers (agent-usage-providers.md, "The trust
/// transition").
nonisolated struct UsageProviderDescriptor: Sendable {
    let id: UsageProviderID
    let displayName: String
    let authPattern: UsageAuthPattern
    let disclosure: String
    let defaultEnabled: Bool
    let makeStrategies: @Sendable (UsageFetchContext) -> [any UsageFetchStrategy]
}

/// The fetch pipeline (usage-providers/W0-shim.md, "Pipeline"): try
/// strategies in order, skip one that reports itself unavailable, and on a
/// thrown error continue to the next strategy ONLY if it says so via
/// `shouldFallback(on:)` — an error that does not want a fallback stops the
/// whole pipeline immediately (never silently tries a later, possibly
/// less-trustworthy strategy behind its back). First success wins; running
/// out of strategies (or stopping early) yields `nil`, which every caller
/// treats as "hide this provider's tile", never a fabricated number.
nonisolated func resolveUsageSnapshot(
    strategies: [any UsageFetchStrategy], context: UsageFetchContext
) async -> UsageSnapshot? {
    for strategy in strategies {
        guard await strategy.isAvailable(context) else { continue }
        do {
            return try await strategy.fetch(context)
        } catch {
            if strategy.shouldFallback(on: error) {
                continue
            }
            return nil
        }
    }
    return nil
}
