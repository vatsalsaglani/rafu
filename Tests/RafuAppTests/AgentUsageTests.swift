import Foundation
import Testing

@testable import RafuApp

/// terminal-notch-hud.md NC-D: the pure usage parsers (`CodexUsageParser`,
/// `ClaudeUsageParser`), the compact token-count formatter, and
/// `AgentUsageReader.tiles(now:)` composing both over INJECTED readers.
/// Every fixture here mirrors the real on-disk shapes verified 2026-07-22
/// (see `AgentUsage.swift`'s doc comments) — no test ever touches
/// `~/.codex`/`~/.claude`. The usage-strip VIEW and the off-main refresh
/// timing are GUI-only (NC-D "Tests" section) and are not covered here.

private func iso8601Fractional(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

// MARK: - CodexUsageParser

@Test("CodexUsageParser: the LAST line carrying rate_limits wins over an earlier one")
func codexParserLastLineWins() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        {"timestamp":"2026-07-18T14:49:39.662Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":2},"secondary":null}}}
        """
    let tile = CodexUsageParser.parse(rolloutContents: contents, now: Date())
    #expect(tile?.agent == "Codex")
    #expect(tile?.windows.count == 1)
    #expect(tile?.windows.first?.percent == 42.5)
    #expect(tile?.windows.first?.tokens == nil)
}

@Test("CodexUsageParser: primary+secondary map to correct 5h/7d labels and percentages")
func codexParserPrimaryAndSecondary() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":17.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":6.0,"window_minutes":10080,"resets_at":2}}}}
        """
    let tile = CodexUsageParser.parse(rolloutContents: contents, now: Date())
    #expect(tile?.windows.count == 2)
    #expect(tile?.windows[0] == AgentUsageWindow(label: "5h", percent: 17.0, tokens: nil))
    #expect(tile?.windows[1] == AgentUsageWindow(label: "7d", percent: 6.0, tokens: nil))
}

@Test("CodexUsageParser: a primary-only rate_limits (no secondary key) yields exactly one window")
func codexParserPrimaryOnly() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1784989552}}}}
        """
    let tile = CodexUsageParser.parse(rolloutContents: contents, now: Date())
    #expect(tile?.windows == [AgentUsageWindow(label: "7d", percent: 0.0, tokens: nil)])
}

@Test(
    "CodexUsageParser: an explicit secondary: null yields exactly one window, same as a missing key"
)
func codexParserSecondaryExplicitNull() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let tile = CodexUsageParser.parse(rolloutContents: contents, now: Date())
    #expect(tile?.windows == [AgentUsageWindow(label: "5h", percent: 3.0, tokens: nil)])
}

@Test("CodexUsageParser: no line anywhere carries rate_limits -> nil, never a crash")
func codexParserNoRateLimitsReturnsNil() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}}}}
        {"timestamp":"2026-07-18T14:49:30.000Z","type":"session_meta","payload":{"id":"abc"}}
        """
    #expect(CodexUsageParser.parse(rolloutContents: contents, now: Date()) == nil)
}

@Test(
    "CodexUsageParser: malformed JSON lines are skipped, not thrown; a later valid line still parses"
)
func codexParserSkipsMalformedLines() {
    let contents = """
        not even json
        {"broken
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let tile = CodexUsageParser.parse(rolloutContents: contents, now: Date())
    #expect(tile?.windows == [AgentUsageWindow(label: "5h", percent: 9.0, tokens: nil)])
}

@Test(
    "CodexUsageParser.label: sub-day rounds to hours, day-or-more rounds to days, invalid falls back"
)
func codexParserWindowLabels() {
    #expect(CodexUsageParser.label(forWindowMinutes: 300) == "5h")
    #expect(CodexUsageParser.label(forWindowMinutes: 10080) == "7d")
    #expect(CodexUsageParser.label(forWindowMinutes: 60) == "1h")
    #expect(CodexUsageParser.label(forWindowMinutes: 1440) == "1d")
    #expect(CodexUsageParser.label(forWindowMinutes: nil) == "usage")
    #expect(CodexUsageParser.label(forWindowMinutes: 0) == "usage")
    #expect(CodexUsageParser.label(forWindowMinutes: -5) == "usage")
}

// MARK: - ClaudeUsageParser

@Test(
    "ClaudeUsageParser: sums into 5h/7d buckets; a >7d-old message is excluded; a 5h message counts in both"
)
func claudeParserBuckets() {
    let now = Date()
    let withinFiveHours = now.addingTimeInterval(-1 * 60 * 60)
    let withinSevenDaysOnly = now.addingTimeInterval(-3 * 24 * 60 * 60)
    let olderThanSevenDays = now.addingTimeInterval(-8 * 24 * 60 * 60)

    func usageLine(timestamp: Date, inputTokens: Int) -> String {
        """
        {"timestamp":"\(iso8601Fractional(timestamp))","message":{"usage":{"input_tokens":\(inputTokens),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
    }

    let lines = [
        usageLine(timestamp: withinFiveHours, inputTokens: 100),
        usageLine(timestamp: withinSevenDaysOnly, inputTokens: 1_000),
        usageLine(timestamp: olderThanSevenDays, inputTokens: 1_000_000),
    ]

    let tile = ClaudeUsageParser.parse(transcriptLines: lines, now: now)
    #expect(tile?.agent == "Claude")
    let byLabel = Dictionary(uniqueKeysWithValues: (tile?.windows ?? []).map { ($0.label, $0) })
    #expect(byLabel["5h"]?.tokens == 100)
    #expect(byLabel["7d"]?.tokens == 1_100)
    #expect(byLabel["5h"]?.percent == nil)
    #expect(byLabel["7d"]?.percent == nil)
}

@Test("ClaudeUsageParser: no usage anywhere returns nil")
func claudeParserNoUsageReturnsNil() {
    let now = Date()
    let lines = [
        """
        {"timestamp":"\(iso8601Fractional(now))","type":"user","message":{"role":"user","content":"hi"}}
        """
    ]
    #expect(ClaudeUsageParser.parse(transcriptLines: lines, now: now) == nil)
}

@Test("ClaudeUsageParser: a line missing message.usage is skipped without affecting other lines")
func claudeParserSkipsLineMissingUsage() {
    let now = Date()
    // A moment strictly before `now`, not `now` itself — a formatted-then-
    // reparsed `now` can round up past the original instant (fractional-
    // second precision loss), which would otherwise flakily drop it outside
    // the parser's `timestamp <= now` window.
    let messageTimestamp = now.addingTimeInterval(-60)
    let withUsage = """
        {"timestamp":"\(iso8601Fractional(messageTimestamp))","message":{"usage":{"input_tokens":50,"output_tokens":25}}}
        """
    let withoutUsage = """
        {"timestamp":"\(iso8601Fractional(messageTimestamp))","message":{"role":"assistant","content":[]}}
        """
    let tile = ClaudeUsageParser.parse(transcriptLines: [withoutUsage, withUsage], now: now)
    let byLabel = Dictionary(uniqueKeysWithValues: (tile?.windows ?? []).map { ($0.label, $0) })
    #expect(byLabel["5h"]?.tokens == 75)
    #expect(byLabel["7d"]?.tokens == 75)
}

@Test("ClaudeUsageParser: a fractional-second ISO timestamp (as observed on disk) parses correctly")
func claudeParserParsesFractionalSecondTimestamp() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fixedTimestamp = "2026-07-13T04:57:21.205Z"
    let parsedDate = try #require(formatter.date(from: fixedTimestamp))
    let now = parsedDate.addingTimeInterval(60 * 60)

    let line = """
        {"timestamp":"\(fixedTimestamp)","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":29644,"cache_read_input_tokens":0,"output_tokens":53}}}
        """
    let tile = ClaudeUsageParser.parse(transcriptLines: [line], now: now)
    let byLabel = Dictionary(uniqueKeysWithValues: (tile?.windows ?? []).map { ($0.label, $0) })
    #expect(byLabel["5h"]?.tokens == 29_699)
    #expect(byLabel["7d"]?.tokens == 29_699)
}

// MARK: - AgentUsageFormat.compactTokenCount

@Test("compactTokenCount: below 1000 is exact; K/M round to one decimal, dropping a trailing .0")
func compactTokenCountFormatting() {
    #expect(AgentUsageFormat.compactTokenCount(999) == "999")
    #expect(AgentUsageFormat.compactTokenCount(1_234) == "1.2K")
    #expect(AgentUsageFormat.compactTokenCount(1_234_567) == "1.2M")
    #expect(AgentUsageFormat.compactTokenCount(1_000) == "1K")
    #expect(AgentUsageFormat.compactTokenCount(1_000_000) == "1M")
    #expect(AgentUsageFormat.compactTokenCount(0) == "0")
}

// MARK: - AgentUsageReader.tiles(now:)

@Test("AgentUsageReader.tiles: composes Claude and Codex tiles from injected readers, Claude first")
func agentUsageReaderComposesBothTiles() {
    let now = Date()
    // See `claudeParserSkipsLineMissingUsage`'s comment: strictly before
    // `now`, not `now` itself.
    let claudeLine = """
        {"timestamp":"\(iso8601Fractional(now.addingTimeInterval(-60)))","message":{"usage":{"input_tokens":10,"output_tokens":5}}}
        """
    let codexContents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let reader = AgentUsageReader(
        newestCodexRollout: { codexContents },
        recentClaudeTranscriptLines: { _ in [claudeLine] }
    )

    let tiles = reader.tiles(now: now)

    #expect(tiles.map(\.agent) == ["Claude", "Codex"])
}

@Test("AgentUsageReader.tiles: a nil codex reader yields only the Claude tile")
func agentUsageReaderMissingCodexOmitsThatTile() {
    let now = Date()
    let claudeLine = """
        {"timestamp":"\(iso8601Fractional(now.addingTimeInterval(-60)))","message":{"usage":{"input_tokens":10,"output_tokens":5}}}
        """
    let reader = AgentUsageReader(
        newestCodexRollout: { nil },
        recentClaudeTranscriptLines: { _ in [claudeLine] }
    )

    #expect(reader.tiles(now: now).map(\.agent) == ["Claude"])
}

@Test("AgentUsageReader.tiles: no Claude usage lines yields only the Codex tile")
func agentUsageReaderMissingClaudeOmitsThatTile() {
    let now = Date()
    let codexContents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let reader = AgentUsageReader(
        newestCodexRollout: { codexContents },
        recentClaudeTranscriptLines: { _ in [] }
    )

    #expect(reader.tiles(now: now).map(\.agent) == ["Codex"])
}

@Test("AgentUsageReader.tiles: both readers empty/nil yields an empty array, never a crash")
func agentUsageReaderBothMissingYieldsEmpty() {
    let reader = AgentUsageReader(
        newestCodexRollout: { nil },
        recentClaudeTranscriptLines: { _ in [] }
    )

    #expect(reader.tiles(now: Date()).isEmpty)
}
