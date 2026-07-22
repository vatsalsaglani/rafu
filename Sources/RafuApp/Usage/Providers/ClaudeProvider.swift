// Portions of the OAuth request/response shapes are adapted from CodexBar
// (https://github.com/steipete/CodexBar), used under its MIT license.
import Foundation
import RafuCore

/// Payload failures carry no response body or credential material, keeping
/// every surfaced description safe to log.
nonisolated enum ClaudeOAuthStrategyError: Error, Equatable, Sendable {
    case credentialUnavailable
    case invalidResponse
}

/// Exact Claude usage from the CLI's OAuth session. Credential discovery and
/// consent happen before context construction; this strategy parses only the
/// minimal envelope supplied by `UsageRegistryReader` and never touches the
/// filesystem or either application's Keychain.
nonisolated struct ClaudeOAuthStrategy: UsageFetchStrategy {
    let id = "claude.oauth"

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        guard let credential = Self.credential(in: context) else {
            throw ClaudeOAuthStrategyError.credentialUnavailable
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeOAuthStrategyError.invalidResponse
        }

        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            "Rafu/\(RafuBuildInformation.version)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await context.http.send(request, provider: .claude)
            try Task.checkCancellation()
            return try Self.parseUsage(data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Only an authentication rejection may use the local estimate. A
    /// malformed payload, transport failure, 429, or other server response
    /// hides the tile instead of replacing an exact fetch with stale-looking
    /// local data.
    func shouldFallback(on error: Error) -> Bool {
        if error as? ClaudeOAuthStrategyError == .credentialUnavailable { return true }
        guard case UsageHTTPError.httpStatus(let status) = error else { return false }
        return status == 401 || status == 403
    }

    static func parseUsage(_ data: Data) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClaudeOAuthStrategyError.invalidResponse
        }

        var windows: [UsageWindow] = []
        if let window = Self.mapWindow(response.fiveHour, label: "5h") {
            windows.append(window)
        }
        if let window = Self.mapWindow(response.sevenDay, label: "7d") {
            windows.append(window)
        }
        if let window = Self.firstScopedWeeklyWindow(response.limits) {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw ClaudeOAuthStrategyError.invalidResponse }

        return UsageSnapshot(
            providerID: .claude, windows: windows, costLine: nil, identity: nil)
    }

    private static func credential(
        in context: UsageFetchContext
    ) -> UsageExternalCredentialEnvelope? {
        guard let value = context.credential(.claude),
            let envelope = UsageExternalCredentialEnvelope.parse(value),
            envelope.isUsable(for: .claude, at: context.now)
        else { return nil }
        return envelope
    }

    private static func mapWindow(_ source: Response.Window?, label: String) -> UsageWindow? {
        guard let source, let percent = validPercent(source.utilization) else { return nil }
        return UsageWindow(
            label: label, percent: percent, tokens: nil,
            resetsAt: source.resetsAt.flatMap(UsageDateParsing.parseISO8601Fractional))
    }

    /// The shared snapshot surface intentionally carries at most three
    /// windows. Preserve the two account-wide lanes and then add the first
    /// valid model-scoped weekly lane, de-duplicated by model identity.
    private static func firstScopedWeeklyWindow(_ limits: [Response.Limit]?) -> UsageWindow? {
        guard let limits else { return nil }
        var seenModels: Set<String> = []
        for limit in limits {
            guard limit.kind == "weekly_scoped", limit.group == "weekly",
                let percent = validPercent(limit.percent),
                let modelName = nonEmpty(limit.scope?.model?.displayName)
            else { continue }

            let identity = nonEmpty(limit.scope?.model?.id) ?? modelName
            let normalizedIdentity = identity.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard normalizedIdentity != "all models", normalizedIdentity != "all-models",
                seenModels.insert(normalizedIdentity).inserted
            else { continue }

            return UsageWindow(
                label: "\(modelName) 7d", percent: percent, tokens: nil,
                resetsAt: limit.resetsAt.flatMap(UsageDateParsing.parseISO8601Fractional))
        }
        return nil
    }

    private static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return if let trimmed, !trimmed.isEmpty { trimmed } else { nil }
    }

    private struct Response: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct Limit: Decodable {
            let kind: String?
            let group: String?
            let percent: Double?
            let resetsAt: String?
            let scope: Scope?

            enum CodingKeys: String, CodingKey {
                case kind, group, percent, scope
                case resetsAt = "resets_at"
            }
        }

        struct Scope: Decodable {
            let model: Model?
        }

        struct Model: Decodable {
            let id: String?
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
    }
}

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

/// Claude's registry entry keeps the local estimate on by default. Exact
/// OAuth usage is attempted first only after an explicit Rafu connection
/// credential exists; the ordered strategy count never depends on context.
nonisolated enum ClaudeProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .claude,
        displayName: "Claude",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads recent Claude Code transcripts locally for an estimate. Connect authorizes Rafu to read Claude Code credentials and make read-only exact usage requests only to api.anthropic.com; disconnect keeps local estimates enabled.",
        defaultEnabled: true,
        makeStrategies: { _ in [ClaudeOAuthStrategy(), ClaudeLocalTranscriptStrategy()] }
    )
}
