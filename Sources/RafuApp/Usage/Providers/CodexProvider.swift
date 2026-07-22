// Portions of the OAuth request/response shapes are adapted from CodexBar
// (https://github.com/steipete/CodexBar), used under its MIT license.
import Foundation
import RafuCore

nonisolated enum CodexOAuthStrategyError: Error, Equatable, Sendable {
    case credentialUnavailable
    case invalidResponse
}

/// Exact Codex rate-limit percentages from ChatGPT's wham endpoint. The
/// strategy consumes only the minimal pre-resolved context envelope; auth
/// file discovery and JWT expiry validation stay in the credential bridge.
nonisolated struct CodexOAuthStrategy: UsageFetchStrategy {
    let id = "codex.oauth"

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        guard let credential = Self.credential(in: context) else {
            throw CodexOAuthStrategyError.credentialUnavailable
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexOAuthStrategyError.invalidResponse
        }

        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Rafu/\(RafuBuildInformation.version)", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, _) = try await context.http.send(request, provider: .codex)
            try Task.checkCancellation()
            return try Self.parseUsage(data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func shouldFallback(on error: Error) -> Bool {
        if error as? CodexOAuthStrategyError == .credentialUnavailable { return true }
        guard case UsageHTTPError.httpStatus(let status) = error else { return false }
        return status == 401 || status == 403
    }

    static func parseUsage(_ data: Data) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CodexOAuthStrategyError.invalidResponse
        }
        guard let rateLimit = response.rateLimit else {
            throw CodexOAuthStrategyError.invalidResponse
        }

        let windows = [rateLimit.primaryWindow, rateLimit.secondaryWindow].compactMap(
            Self.mapWindow)
        guard !windows.isEmpty else { throw CodexOAuthStrategyError.invalidResponse }
        return UsageSnapshot(providerID: .codex, windows: windows, costLine: nil, identity: nil)
    }

    private static func credential(
        in context: UsageFetchContext
    ) -> UsageExternalCredentialEnvelope? {
        guard let value = context.credential(.codex),
            let envelope = UsageExternalCredentialEnvelope.parse(value),
            envelope.isUsable(for: .codex, at: context.now)
        else { return nil }
        return envelope
    }

    private static func mapWindow(_ source: Response.Window?) -> UsageWindow? {
        guard let source, source.usedPercent.isFinite,
            (0...100).contains(source.usedPercent), source.limitWindowSeconds > 0
        else { return nil }

        return UsageWindow(
            label: CodexLocalRolloutStrategy.label(
                forWindowMinutes: source.limitWindowSeconds / 60),
            percent: source.usedPercent,
            tokens: nil,
            resetsAt: source.resetAt > 0
                ? Date(timeIntervalSince1970: source.resetAt)
                : nil)
    }

    private struct Response: Decodable {
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct Window: Decodable {
            let usedPercent: Double
            let resetAt: Double
            let limitWindowSeconds: Double

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
        }
    }
}

/// Codex's local, zero-config usage strategy — migrated unchanged from the
/// shipped `CodexUsageParser` (terminal-notch-hud.md NC-D, "Data sources"):
/// parses `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` rollout logs,
/// verified shape 2026-07-22. Each line is `{"timestamp", "type",
/// "payload"}`; `event_msg` lines carry `payload.rate_limits =
/// {"primary": {"used_percent", "window_minutes", "resets_at"},
/// "secondary": ... | null, ...}`. Pure and version-tolerant — every field
/// is optional, an unrecognized/malformed line is skipped (never thrown),
/// and only the LAST line carrying `rate_limits` in the file is used
/// (rollout logs append a fresh snapshot on every turn).
///
/// Depends on `LocalUsageFiles.newestCodexRollout()` directly (injectable
/// for tests) rather than `UsageFetchContext.readFile` — see
/// `UsageFetchContext`'s doc comment.
///
/// `parse`/`label(forWindowMinutes:)` live directly in this type's primary
/// declaration — see `UsageProviderCore.swift`'s doc comment.
nonisolated struct CodexLocalRolloutStrategy: UsageFetchStrategy {
    let id = "codex.local-rollout"

    private let newestRolloutContents: @Sendable () -> String?

    init(
        newestRolloutContents: @escaping @Sendable () -> String? = LocalUsageFiles
            .newestCodexRollout
    ) {
        self.newestRolloutContents = newestRolloutContents
    }

    /// Always available — a missing/empty `~/.codex/sessions` tree simply
    /// yields no rollout contents, which `fetch` turns into a thrown
    /// `UsageLocalDataError.noData`.
    func isAvailable(_ context: UsageFetchContext) async -> Bool { true }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let rolloutContents = newestRolloutContents(),
            let snapshot = Self.parse(rolloutContents: rolloutContents, now: context.now)
        else {
            throw UsageLocalDataError.noData
        }
        return snapshot
    }

    /// The only strategy for this provider in W0 — nothing to fall back to.
    func shouldFallback(on error: Error) -> Bool { false }

    private struct RolloutLine: Decodable {
        let payload: Payload?

        struct Payload: Decodable {
            let rateLimits: RateLimits?
            enum CodingKeys: String, CodingKey {
                case rateLimits = "rate_limits"
            }
        }
    }

    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    private struct Window: Decodable {
        let usedPercent: Double?
        let windowMinutes: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
        }
    }

    /// `nil` when no line in `rolloutContents` carries `payload.rate_limits`
    /// (a rollout with no turns yet, or a shape this parser no longer
    /// recognizes) — never a crash, never a fabricated percentage.
    static func parse(rolloutContents: String, now: Date) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        var lastRateLimits: RateLimits?
        rolloutContents.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                let decoded = try? decoder.decode(RolloutLine.self, from: data),
                let rateLimits = decoded.payload?.rateLimits
            else { return }
            lastRateLimits = rateLimits
        }
        guard let rateLimits = lastRateLimits else { return nil }

        var windows: [UsageWindow] = []
        if let primary = rateLimits.primary, let percent = primary.usedPercent {
            windows.append(
                UsageWindow(
                    label: label(forWindowMinutes: primary.windowMinutes), percent: percent,
                    tokens: nil, resetsAt: nil))
        }
        if let secondary = rateLimits.secondary, let percent = secondary.usedPercent {
            windows.append(
                UsageWindow(
                    label: label(forWindowMinutes: secondary.windowMinutes), percent: percent,
                    tokens: nil, resetsAt: nil))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(providerID: .codex, windows: windows, costLine: nil, identity: nil)
    }

    /// `window_minutes` → a human label, generic rather than hardcoded to
    /// the two values observed on this machine (300/10080): under a day →
    /// rounded hours ("5h"); a day or more → rounded days ("7d"). `nil`/
    /// non-positive → "usage" (never a 0-labeled window).
    static func label(forWindowMinutes minutes: Double?) -> String {
        guard let minutes, minutes > 0 else { return "usage" }
        let hours = minutes / 60
        if hours < 24 {
            return "\(max(1, Int(hours.rounded())))h"
        }
        let days = hours / 24
        return "\(max(1, Int(days.rounded())))d"
    }
}

/// Codex's registry entry keeps its shipped local rollout behavior on by
/// default. Exact OAuth usage is attempted first only after explicit Rafu
/// connection state exists; strategy order/count are context-independent.
nonisolated enum CodexProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .codex,
        displayName: "Codex",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads the newest Codex rollout locally for last-seen usage. Connect authorizes Rafu to read Codex auth.json and make read-only exact usage requests only to chatgpt.com; disconnect keeps local usage enabled.",
        defaultEnabled: true,
        makeStrategies: { _ in [CodexOAuthStrategy(), CodexLocalRolloutStrategy()] }
    )
}
