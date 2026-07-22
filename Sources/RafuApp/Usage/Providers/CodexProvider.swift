// Portions of the OAuth request/response shapes are adapted from CodexBar
// (https://github.com/steipete/CodexBar), used under its MIT license.
import Foundation
import RafuCore

/// The subset of Codex CLI `auth.json` required for the read-only wham usage
/// call. Both current snake_case and legacy camelCase token keys are accepted.
nonisolated struct CodexOAuthCredentials: Equatable, Sendable {
    let accessToken: String
    let accountID: String?
    let lastRefresh: Date?

    /// CodexBar treats credentials older than eight days (or missing
    /// `last_refresh`) as refresh candidates. Rafu deliberately does not
    /// refresh another app's token, so those records are unavailable and the
    /// local rollout strategy takes over.
    func isFresh(at now: Date) -> Bool {
        guard let lastRefresh else { return false }
        return now.timeIntervalSince(lastRefresh) <= 8 * 24 * 60 * 60
    }

    static func parse(contents: String) -> CodexOAuthCredentials? {
        guard let data = contents.data(using: .utf8),
            let root = try? JSONDecoder().decode(Root.self, from: data),
            let tokens = root.tokens,
            let accessToken = tokens.accessToken?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !accessToken.isEmpty
        else { return nil }

        let accountID = tokens.accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CodexOAuthCredentials(
            accessToken: accessToken,
            accountID: accountID.flatMap { $0.isEmpty ? nil : $0 },
            lastRefresh: root.lastRefresh.flatMap(UsageDateParsing.parseISO8601Fractional))
    }

    private struct Root: Decodable {
        let tokens: Tokens?
        let lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case lastRefreshSnake = "last_refresh"
            case lastRefreshCamel = "lastRefresh"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try container.decodeIfPresent(Tokens.self, forKey: .tokens)
            lastRefresh =
                try container.decodeIfPresent(String.self, forKey: .lastRefreshSnake)
                ?? container.decodeIfPresent(String.self, forKey: .lastRefreshCamel)
        }
    }

    private struct Tokens: Decodable {
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessTokenSnake = "access_token"
            case accessTokenCamel = "accessToken"
            case accountIDSnake = "account_id"
            case accountIDCamel = "accountId"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken =
                try container.decodeIfPresent(String.self, forKey: .accessTokenSnake)
                ?? container.decodeIfPresent(String.self, forKey: .accessTokenCamel)
            accountID =
                try container.decodeIfPresent(String.self, forKey: .accountIDSnake)
                ?? container.decodeIfPresent(String.self, forKey: .accountIDCamel)
        }
    }
}

nonisolated enum CodexOAuthStrategyError: Error, Equatable, Sendable {
    case credentialUnavailable
    case invalidResponse
}

/// Exact Codex rate-limit percentages from ChatGPT's wham endpoint. As with
/// Claude, `context.credential(.codex)` is a consent/connection gate checked
/// before any auth-file read. The auth-content closure makes `$CODEX_HOME`
/// behavior injectable, so tests never inspect the user's real files.
nonisolated struct CodexOAuthStrategy: UsageFetchStrategy {
    let id = "codex.oauth"

    private let authContents: @Sendable (UsageFetchContext) -> String?

    init(
        authContents: @escaping @Sendable (UsageFetchContext) -> String? = Self
            .productionAuthContents
    ) {
        self.authContents = authContents
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        guard let connectionCredential = Self.connectionCredential(in: context) else {
            return false
        }
        return resolvedCredentials(context: context, connectionCredential: connectionCredential)
            != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        try Task.checkCancellation()
        guard let connectionCredential = Self.connectionCredential(in: context),
            let credentials = resolvedCredentials(
                context: context, connectionCredential: connectionCredential)
        else {
            throw CodexOAuthStrategyError.credentialUnavailable
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexOAuthStrategyError.invalidResponse
        }

        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Rafu/\(RafuBuildInformation.version)", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID {
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

    static func productionAuthContents(_ context: UsageFetchContext) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let authURL = configuredAuthURL(environment: environment) {
            return try? String(contentsOf: authURL, encoding: .utf8)
        }
        return context.readFile(".codex/auth.json")
    }

    /// Resolves the CLI's explicit home without reading it, keeping
    /// `$CODEX_HOME` precedence independently testable without touching the
    /// developer's real filesystem.
    static func configuredAuthURL(environment: [String: String]) -> URL? {
        guard
            let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !configuredHome.isEmpty
        else { return nil }

        let expandedHome = (configuredHome as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedHome, isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    private func resolvedCredentials(
        context: UsageFetchContext, connectionCredential: String
    ) -> CodexOAuthCredentials? {
        if let contents = authContents(context) {
            guard let credentials = CodexOAuthCredentials.parse(contents: contents),
                credentials.isFresh(at: context.now)
            else { return nil }
            return credentials
        }
        return CodexOAuthCredentials(
            accessToken: connectionCredential, accountID: nil, lastRefresh: nil)
    }

    private static func connectionCredential(in context: UsageFetchContext) -> String? {
        let credential = context.credential(.codex)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return if let credential, !credential.isEmpty { credential } else { nil }
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
            "Reads the newest Codex rollout locally for last-seen usage. When explicitly connected, reads auth.json from $CODEX_HOME or ~/.codex and sends its OAuth token only to chatgpt.com for current percentages.",
        defaultEnabled: true,
        makeStrategies: { _ in [CodexOAuthStrategy(), CodexLocalRolloutStrategy()] }
    )
}
