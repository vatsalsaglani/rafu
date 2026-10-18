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
        if let window = Self.mapWindow(
            response.fiveHour, label: "5h", windowMinutes: Self.sessionWindowMinutes)
        {
            windows.append(window)
        }
        if let window = Self.mapWindow(
            response.sevenDay, label: "7d", windowMinutes: Self.weeklyWindowMinutes)
        {
            windows.append(window)
        }
        windows.append(
            contentsOf: Self.modelScopedWeeklyWindows(
                response, cap: Self.maximumWindows - windows.count))
        guard !windows.isEmpty else { throw ClaudeOAuthStrategyError.invalidResponse }

        return UsageSnapshot(
            providerID: .claude, windows: windows, costLine: nil, identity: nil,
            source: .providerAPI)
    }

    /// Claude's session limit is a rolling 5-hour window and every weekly
    /// limit is 7 days. The endpoint reports only `resets_at`, so the
    /// lengths come from Claude's documented limits; `UsagePace` needs them
    /// to find where each window started.
    static let sessionWindowMinutes = 5 * 60
    static let weeklyWindowMinutes = 7 * 24 * 60
    /// Bounds the snapshot: the two account-wide lanes plus up to four
    /// model-scoped weekly lanes. The notch shows the first three; Settings
    /// shows all of them.
    static let maximumWindows = 6

    /// Every model-scoped weekly lane, in a stable order: the dedicated
    /// top-level keys first (`seven_day_opus`, `seven_day_sonnet`), then
    /// each `limits` entry of kind `weekly_scoped`. A model appears at most
    /// once (the first valid entry wins), and "all models" is never a
    /// model lane because `seven_day` already is that lane.
    private static func modelScopedWeeklyWindows(_ response: Response, cap: Int) -> [UsageWindow] {
        guard cap > 0 else { return [] }
        var seenModels: Set<String> = []
        var windows: [UsageWindow] = []

        func append(model: String, identity: String?, percent: Double?, resetsAt: String?) {
            guard windows.count < cap, let percent = validPercent(percent),
                let modelName = nonEmpty(model)
            else { return }
            let normalizedIdentity = normalizedModelIdentity(nonEmpty(identity) ?? modelName)
            let normalizedName = normalizedModelIdentity(modelName)
            guard normalizedIdentity != "all models", normalizedIdentity != "all-models",
                !seenModels.contains(normalizedIdentity), !seenModels.contains(normalizedName)
            else { return }
            seenModels.insert(normalizedIdentity)
            seenModels.insert(normalizedName)
            windows.append(
                UsageWindow(
                    label: "\(modelName) 7d", percent: percent, tokens: nil,
                    resetsAt: resetsAt.flatMap(UsageDateParsing.parseISO8601Fractional),
                    windowMinutes: weeklyWindowMinutes))
        }

        for (model, window) in [("Opus", response.sevenDayOpus), ("Sonnet", response.sevenDaySonnet)]
        {
            guard let window else { continue }
            append(
                model: model, identity: nil, percent: window.utilization,
                resetsAt: window.resetsAt)
        }
        for limit in response.limits ?? [] {
            guard limit.kind == "weekly_scoped", limit.group == "weekly",
                let modelName = limit.scope?.model?.displayName
            else { continue }
            append(
                model: modelName, identity: limit.scope?.model?.id,
                percent: limit.percent ?? limit.utilization, resetsAt: limit.resetsAt)
        }
        return windows
    }

    private static func normalizedModelIdentity(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

    private static func mapWindow(
        _ source: Response.Window?, label: String, windowMinutes: Int
    ) -> UsageWindow? {
        guard let source, let percent = validPercent(source.utilization) else { return nil }
        return UsageWindow(
            label: label, percent: percent, tokens: nil,
            resetsAt: source.resetsAt.flatMap(UsageDateParsing.parseISO8601Fractional),
            windowMinutes: windowMinutes)
    }

    /// The largest over-limit value still treated as "at the limit". The
    /// endpoint can report a little over 100 once a window is exhausted.
    static let maximumReportedPercent: Double = 1_000

    /// `utilization` is a percentage on a 0–100 scale. A value from 0 to 1
    /// is a small percentage (0.5 means 0.5 %), never a fraction to
    /// multiply by 100: a fraction guess would show 1 % as 100 %. A value
    /// over 100 (an exhausted window) clamps to 100 instead of dropping the
    /// window. A negative, non-finite, or absurd value drops the window.
    static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...maximumReportedPercent).contains(value) else {
            return nil
        }
        return min(value, 100)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return if let trimmed, !trimmed.isEmpty { trimmed } else { nil }
    }

    private struct Response: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case limits
        }

        /// The two account-wide lanes and `limits` decode strictly, as
        /// before: a malformed value there hides the tile. The model lanes
        /// decode leniently, so an odd value in an optional lane cannot
        /// hide the session and weekly rings.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try container.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try container.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDayOpus = try? container.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? container.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
            limits = try container.decodeIfPresent([Limit].self, forKey: .limits)
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
            let utilization: Double?
            let resetsAt: String?
            let scope: Scope?

            enum CodingKeys: String, CodingKey {
                case kind, group, percent, utilization, scope
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
            costLine: nil, identity: nil, source: .localEstimate
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
            "Reads recent Claude Code transcripts locally for an estimate. Connect authorizes Rafu to read Claude Code credentials (again while connected, when the saved token expires) and make read-only exact usage requests only to api.anthropic.com; disconnect keeps local estimates enabled.",
        defaultEnabled: true,
        makeStrategies: { _ in [ClaudeOAuthStrategy(), ClaudeLocalTranscriptStrategy()] }
    )
}
