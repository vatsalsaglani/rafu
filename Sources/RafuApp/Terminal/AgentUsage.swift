import Foundation

/// One usage window for a companion usage-strip tile (terminal-notch-hud.md
/// NC-D): Codex reports a real percentage, Claude reports a token total —
/// never both, never a fabricated one to fill the missing field. `nil`
/// `percent`/`tokens` simply means that source has nothing to show for that
/// window; the VIEW decides what to render, this type only carries data.
nonisolated struct AgentUsageWindow: Equatable, Sendable {
    /// "5h" / "7d" (or whatever `CodexUsageParser.label(forWindowMinutes:)`
    /// derives from a real `window_minutes` value).
    let label: String
    /// Codex only: a real rate-limit percentage.
    let percent: Double?
    /// Claude only: a summed token count.
    let tokens: Int?
}

/// One agent's usage-strip tile. An empty `windows` array means "hide this
/// tile entirely" — `AgentUsageReader.tiles(now:)` never appends a tile with
/// no windows (terminal-notch-hud.md: "hidden entirely otherwise").
nonisolated struct AgentUsageTile: Equatable, Sendable {
    /// "Claude" / "Codex" — display name, not an internal identifier.
    let agent: String
    let windows: [AgentUsageWindow]
}

/// Compact token-count formatting shared by the usage strip
/// (terminal-notch-hud.md NC-D: "1_234_567 → \"1.2M\"").
nonisolated enum AgentUsageFormat {
    /// `999` → `"999"`, `1_234` → `"1.2K"`, `1_234_567` → `"1.2M"`. Rounds to
    /// one decimal place and drops a trailing `.0` (`1_000` → `"1K"`, not
    /// `"1.0K"`).
    static func compactTokenCount(_ value: Int) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case ..<1_000:
            return "\(value)"
        case ..<1_000_000:
            return scaled(value, by: 1_000, suffix: "K")
        default:
            return scaled(value, by: 1_000_000, suffix: "M")
        }
    }

    private static func scaled(_ value: Int, by divisor: Double, suffix: String) -> String {
        let rounded = ((Double(value) / divisor) * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.1f%@", rounded, suffix)
    }
}

/// Parses `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` rollout logs
/// (terminal-notch-hud.md, "Data sources", verified shape 2026-07-22): each
/// line is `{"timestamp", "type", "payload"}`; `event_msg` lines carry
/// `payload.rate_limits = {"primary": {"used_percent", "window_minutes",
/// "resets_at"}, "secondary": ... | null, ...}`. Pure and version-tolerant —
/// every field is optional, an unrecognized/malformed line is skipped (never
/// thrown), and only the LAST line carrying `rate_limits` in the file is
/// used (rollout logs append a fresh snapshot on every turn).
///
/// `parse`/`label(forWindowMinutes:)` live directly in this enum's primary
/// declaration, not a later `extension` — see `CompanionEditorRow`'s doc
/// comment (NotchCompanionPolicy.swift) for why: the `RafuApp` target's
/// `.defaultIsolation(MainActor.self)` does not propagate through a bare
/// `extension` on a `nonisolated` type, so a static function added there
/// silently becomes `@MainActor` and traps the first time it runs off-main
/// (as every headless test and the off-main `Task.detached` refresh here
/// does).
nonisolated enum CodexUsageParser {
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
    static func parse(rolloutContents: String, now: Date) -> AgentUsageTile? {
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

        var windows: [AgentUsageWindow] = []
        if let primary = rateLimits.primary, let percent = primary.usedPercent {
            windows.append(
                AgentUsageWindow(
                    label: label(forWindowMinutes: primary.windowMinutes), percent: percent,
                    tokens: nil))
        }
        if let secondary = rateLimits.secondary, let percent = secondary.usedPercent {
            windows.append(
                AgentUsageWindow(
                    label: label(forWindowMinutes: secondary.windowMinutes), percent: percent,
                    tokens: nil))
        }
        guard !windows.isEmpty else { return nil }
        return AgentUsageTile(agent: "Codex", windows: windows)
    }

    /// `window_minutes` → a human label, generic rather than hardcoded to
    /// the two values observed on this machine (300/10080) so a future Codex
    /// release choosing a different window still renders something sensible:
    /// under a day → rounded hours ("5h"); a day or more → rounded days
    /// ("7d"). `nil`/non-positive → "usage" (never a 0-labeled window).
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

/// Parses `~/.claude/projects/**/*.jsonl` transcripts (terminal-notch-hud.md,
/// "Data sources", verified shape 2026-07-22): each assistant-message line
/// carries a top-level `timestamp` (ISO 8601, fractional seconds, e.g.
/// `"2026-07-13T04:57:21.205Z"`) and `message.usage = {"input_tokens",
/// "cache_creation_input_tokens", "cache_read_input_tokens",
/// "output_tokens", ...}`. Claude exposes no rate-limit percentage, so this
/// sums token counts into trailing 5h/7d buckets instead — the tile's
/// `percent` is always `nil`, `tokens` is always set.
///
/// `parse`/its helpers live directly in this enum's primary declaration —
/// see `CodexUsageParser`'s doc comment for why.
nonisolated enum ClaudeUsageParser {
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
    static func parse(transcriptLines: [String], now: Date) -> AgentUsageTile? {
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
                let timestamp = parseTimestamp(timestampString),
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
        return AgentUsageTile(
            agent: "Claude",
            windows: [
                AgentUsageWindow(label: "5h", percent: nil, tokens: fiveHourTokens),
                AgentUsageWindow(label: "7d", percent: nil, tokens: sevenDayTokens),
            ]
        )
    }

    /// `ISO8601DateFormatter` with `.withFractionalSeconds` — the plain
    /// `Date(iso8601String:)`/default `ISO8601DateFormatter` configuration
    /// rejects Claude's `.205Z`-style fractional-second timestamps outright,
    /// so every timestamp in a transcript would otherwise silently fail to
    /// parse.
    private static func parseTimestamp(_ string: String) -> Date? {
        Self.fractionalFormatter.date(from: string) ?? Self.formatter.date(from: string)
    }

    /// A fresh formatter per call, matching `ISO8601DateFormatter.git`'s
    /// convention (GitHistoryParser.swift) — `ISO8601DateFormatter` is not
    /// `Sendable`, so a cached `static let` trips Swift 6 strict-concurrency
    /// global-state checking; the formatter is cheap to construct and this
    /// scan is already bounded.
    private static var fractionalFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var formatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }
}

/// The ONLY file-touching type in this file — every parser above is pure
/// over already-read strings. Mirrors `TerminalShellCatalog`'s injectable
/// shape exactly: production closures do the real (bounded) file walking,
/// tests inject fixtures and never touch `~/.codex`/`~/.claude`.
///
/// Privacy (terminal-notch-hud.md, "Data sources"): read-only, local-only.
/// Only token counts, percentages, `window_minutes`, and timestamps are ever
/// parsed — never prompt/response text. Nothing here is logged (no
/// `print`/`os_log`/`Logger`) or cached to disk; a fresh read happens on
/// every `tiles(now:)` call, subject to `NotchCompanionModel`'s in-memory
/// TTL. All filesystem work is bounded: the Codex reader touches at most one
/// file, and the Claude reader caps both the number of files considered and
/// the bytes read per file (see `maxClaudeTranscriptFiles`/
/// `maxBytesPerClaudeFile`) — reading other tools' local files is a new
/// capability with no reason to become an unbounded scan.
nonisolated struct AgentUsageReader: Sendable {
    /// Newest-by-mtime Claude transcript files considered per scan. Well
    /// above what a single active project needs (one live conversation file
    /// plus its `subagents/*.jsonl` children) while still bounding a
    /// multi-project `~/.claude/projects` tree.
    static let maxClaudeTranscriptFiles = 30
    /// Bytes read from the TAIL of each considered transcript — recent
    /// messages (what the 5h/7d windows care about) live at the end of an
    /// append-only transcript, so a bounded tail read captures them without
    /// ever loading a multi-hundred-megabyte log in full.
    static let maxBytesPerClaudeFile = 256 * 1_024

    private let newestCodexRolloutContents: @Sendable () -> String?
    private let recentClaudeTranscriptLines: @Sendable (Date) -> [String]

    init(
        newestCodexRollout: @escaping @Sendable () -> String? = AgentUsageReader
            .productionNewestCodexRollout,
        recentClaudeTranscriptLines: @escaping @Sendable (Date) -> [String] = AgentUsageReader
            .productionRecentClaudeTranscriptLines
    ) {
        self.newestCodexRolloutContents = newestCodexRollout
        self.recentClaudeTranscriptLines = recentClaudeTranscriptLines
    }

    /// Composes both parsers into the tiles the companion panel shows, in
    /// display order (Claude, then Codex — terminal-notch-hud.md's example
    /// strip). Either or both may be absent; a reader/parse failure on one
    /// side never suppresses the other.
    func tiles(now: Date) -> [AgentUsageTile] {
        var tiles: [AgentUsageTile] = []
        if let claudeTile = ClaudeUsageParser.parse(
            transcriptLines: recentClaudeTranscriptLines(now), now: now)
        {
            tiles.append(claudeTile)
        }
        if let rolloutContents = newestCodexRolloutContents(),
            let codexTile = CodexUsageParser.parse(rolloutContents: rolloutContents, now: now)
        {
            tiles.append(codexTile)
        }
        return tiles
    }

    // MARK: - Production file access

    private static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// The newest `rollout-*.jsonl` anywhere under `~/.codex/sessions`, read
    /// in full (bounded to exactly one file — a session's rollout log is
    /// this machine's largest observed shape, but never more than one is
    /// ever opened).
    static func productionNewestCodexRollout() -> String? {
        let sessionsDirectory = homeDirectory.appending(
            path: ".codex/sessions", directoryHint: .isDirectory)
        guard
            let newestURL = newestFile(
                under: sessionsDirectory,
                matching: { url in
                    url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
                })
        else { return nil }
        return try? String(contentsOf: newestURL, encoding: .utf8)
    }

    /// The newest `maxClaudeTranscriptFiles` `*.jsonl` files anywhere under
    /// `~/.claude/projects` whose modification time falls within the
    /// trailing 7-day window (files older than that cannot contribute to
    /// either bucket), each capped to its last `maxBytesPerClaudeFile`
    /// bytes.
    static func productionRecentClaudeTranscriptLines(now: Date) -> [String] {
        let projectsDirectory = homeDirectory.appending(
            path: ".claude/projects", directoryHint: .isDirectory)
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let candidates = filesSortedByModificationDate(
            under: projectsDirectory, matching: { $0.pathExtension == "jsonl" },
            modifiedOnOrAfter: cutoff
        )
        var lines: [String] = []
        for url in candidates.prefix(maxClaudeTranscriptFiles) {
            lines.append(contentsOf: tailLines(of: url, maxBytes: maxBytesPerClaudeFile))
        }
        return lines
    }

    // MARK: - Filesystem helpers

    private static func newestFile(
        under directory: URL, matching predicate: (URL) -> Bool
    ) -> URL? {
        var newestURL: URL?
        var newestDate = Date.distantPast
        enumerateFiles(under: directory) { url, modificationDate in
            guard predicate(url) else { return }
            if modificationDate > newestDate {
                newestDate = modificationDate
                newestURL = url
            }
        }
        return newestURL
    }

    private static func filesSortedByModificationDate(
        under directory: URL, matching predicate: (URL) -> Bool, modifiedOnOrAfter cutoff: Date
    ) -> [URL] {
        var results: [(url: URL, date: Date)] = []
        enumerateFiles(under: directory) { url, modificationDate in
            guard predicate(url), modificationDate >= cutoff else { return }
            results.append((url, modificationDate))
        }
        return results.sorted { $0.date > $1.date }.map(\.url)
    }

    private static func enumerateFiles(under directory: URL, _ body: (URL, Date) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else { return }
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let modificationDate = values.contentModificationDate
            else { continue }
            body(url, modificationDate)
        }
    }

    /// Reads at most `maxBytes` from the END of `url`. When that tail read
    /// did not start at the true beginning of the file, the first line is
    /// discarded as possibly truncated mid-object.
    private static func tailLines(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return [] }
        let readSize = min(Int(fileSize), maxBytes)
        let offset = fileSize - UInt64(readSize)
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.read(upToCount: readSize),
            let text = String(data: data, encoding: .utf8)
        else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }
}
