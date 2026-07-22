import Foundation

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

/// Codex's registry entry. Local, zero-config, on by default — matches the
/// shipped strip's pre-W0 behavior exactly. An OAuth freshness strategy
/// (`~/.codex/auth.json` → `wham/usage`) is deferred to a later phase; W0
/// ships only the local rollout-tail estimate.
nonisolated enum CodexProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .codex,
        displayName: "Codex",
        authPattern: .localZeroConfig,
        disclosure:
            "Reads the newest Codex session rollout under ~/.codex/sessions to report its last-seen 5h/7d rate-limit percentages. Local only — no network, no credentials.",
        defaultEnabled: true,
        makeStrategies: { _ in [CodexLocalRolloutStrategy()] }
    )
}
