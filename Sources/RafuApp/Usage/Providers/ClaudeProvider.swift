import Foundation

/// Claude's local, zero-config usage strategy — migrated unchanged from the
/// shipped `ClaudeUsageParser` (terminal-notch-hud.md NC-D, "Data sources"):
/// parses `~/.claude/projects/**/*.jsonl` transcripts, verified shape
/// 2026-07-22. Each assistant-message line carries a top-level `timestamp`
/// (ISO 8601, fractional seconds) and `message.usage = {"input_tokens",
/// "cache_creation_input_tokens", "cache_read_input_tokens",
/// "output_tokens", ...}`. Claude exposes no rate-limit percentage locally,
/// so this sums token counts into trailing 5h/7d buckets instead — every
/// `UsageWindow.percent` here is `nil`, `tokens` is always set.
///
/// Depends on `LocalUsageFiles.recentClaudeTranscriptLines(now:)` directly
/// (injectable for tests) rather than `UsageFetchContext.readFile` — see
/// `UsageFetchContext`'s doc comment for why a single-file reader cannot
/// express this bounded multi-file directory scan.
///
/// `parse`/its helpers live directly in this type's primary declaration,
/// not a later `extension` — see `UsageProviderCore.swift`'s doc comment.
nonisolated struct ClaudeLocalTranscriptStrategy: UsageFetchStrategy {
    let id = "claude.local-transcripts"

    private let recentTranscriptLines: @Sendable (Date) -> [String]

    init(
        recentTranscriptLines: @escaping @Sendable (Date) -> [String] = LocalUsageFiles
            .recentClaudeTranscriptLines
    ) {
        self.recentTranscriptLines = recentTranscriptLines
    }

    /// Always available — a missing/empty `~/.claude/projects` tree simply
    /// yields no transcript lines, which `fetch` turns into a thrown
    /// `UsageLocalDataError.noData` rather than reporting itself
    /// unavailable up front (mirrors the shipped reader's "nil, never a
    /// crash" discipline).
    func isAvailable(_ context: UsageFetchContext) async -> Bool { true }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard
            let snapshot = Self.parse(
                transcriptLines: recentTranscriptLines(context.now), now: context.now)
        else {
            throw UsageLocalDataError.noData
        }
        return snapshot
    }

    /// The only strategy for this provider in W0 — nothing to fall back to.
    func shouldFallback(on error: Error) -> Bool { false }

    private struct TranscriptLine: Decodable {
        let timestamp: String?
        let message: Message?

        struct Message: Decodable {
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    /// `nil` when no line in `transcriptLines` has a parseable
    /// `timestamp`+`message.usage` pair landing within the trailing 7-day
    /// window — never a crash, never a fabricated "0 tok".
    static func parse(transcriptLines: [String], now: Date) -> UsageSnapshot? {
        let decoder = JSONDecoder()
        let fiveHourStart = now.addingTimeInterval(-5 * 60 * 60)
        let sevenDayStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var fiveHourTokens = 0
        var sevenDayTokens = 0
        var sawUsageInWindow = false

        for line in transcriptLines {
            guard let data = line.data(using: .utf8),
                let decoded = try? decoder.decode(TranscriptLine.self, from: data),
                let usage = decoded.message?.usage,
                let timestampString = decoded.timestamp,
                let timestamp = UsageDateParsing.parseISO8601Fractional(timestampString),
                timestamp >= sevenDayStart, timestamp <= now
            else { continue }

            sawUsageInWindow = true
            let tokens =
                (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
                + (usage.cacheReadInputTokens ?? 0) + (usage.outputTokens ?? 0)
            sevenDayTokens += tokens
            if timestamp >= fiveHourStart {
                fiveHourTokens += tokens
            }
        }

        guard sawUsageInWindow else { return nil }
        return UsageSnapshot(
            providerID: .claude,
            windows: [
                UsageWindow(label: "5h", percent: nil, tokens: fiveHourTokens, resetsAt: nil),
                UsageWindow(label: "7d", percent: nil, tokens: sevenDayTokens, resetsAt: nil),
            ],
            costLine: nil, identity: nil
        )
    }
}

/// Claude's registry entry. Local, zero-config, on by default — matches
/// the shipped strip's pre-W0 behavior exactly (agent-usage-providers.md:
/// "the shipped local-only parsers ... stay on by default"). W2 adds an
/// exact-percent OAuth strategy ahead of this one; W0 ships only the local
/// transcript estimate.
nonisolated enum ClaudeProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .claude,
        displayName: "Claude",
        authPattern: .localZeroConfig,
        disclosure:
            "Reads recent Claude Code transcripts under ~/.claude/projects to estimate token usage in the trailing 5h/7d windows. Local only — no network, no credentials.",
        defaultEnabled: true,
        makeStrategies: { _ in [ClaudeLocalTranscriptStrategy()] }
    )
}
