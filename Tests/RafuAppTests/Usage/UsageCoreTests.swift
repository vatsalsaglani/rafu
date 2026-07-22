import Foundation
import Testing

@testable import RafuApp

/// usage-providers/W0-shim.md: `resolveUsageSnapshot(strategies:context:)`'s
/// pipeline semantics (order, skip-unavailable, fallback-vs-stop, first
/// success wins, total failure ⇒ nil), plus a redaction audit for
/// `UsageHTTPError`. The migrated Claude/Codex local-provider tests
/// (formerly `Tests/RafuAppTests/AgentUsageTests.swift`) and the
/// front-line rendering parity assertion live in this same file — see the
/// "Claude/Codex provider parsing" and "Rendering parity" sections below.

private func fixtureContext(
    now: Date = Date(),
    readFile: @escaping @Sendable (String) -> String? = { _ in nil },
    http: UsageHTTPClient = .noop,
    credential: @escaping @Sendable (UsageProviderID) -> String? = { _ in nil },
    cookieHeader: @escaping @Sendable (UsageProviderID) -> String? = { _ in nil }
) -> UsageFetchContext {
    UsageFetchContext(
        now: now, readFile: readFile, http: http, credential: credential,
        cookieHeader: cookieHeader)
}

private struct StubStrategy: UsageFetchStrategy {
    let id: String
    var available = true
    var result: Result<UsageSnapshot, Error> = .failure(UsageLocalDataError.noData)
    var fallback = false

    func isAvailable(_ context: UsageFetchContext) async -> Bool { available }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        try result.get()
    }

    func shouldFallback(on error: Error) -> Bool { fallback }
}

private func snapshot(_ id: UsageProviderID = .claude, percent: Double = 10) -> UsageSnapshot {
    UsageSnapshot(
        providerID: id,
        windows: [UsageWindow(label: "5h", percent: percent, tokens: nil, resetsAt: nil)],
        costLine: nil, identity: nil)
}

private actor RegistryBridgeRecorder {
    private(set) var events: [String] = []
    private(set) var requestedIDs: [UsageProviderID] = []
    private(set) var credentials: [UsageProviderID: String?] = [:]

    func recordEvent(_ event: String) {
        events.append(event)
    }

    func recordRequestedIDs(_ ids: [UsageProviderID]) {
        requestedIDs = ids
    }

    func recordCredential(_ credential: String?, for id: UsageProviderID) {
        credentials[id] = credential
    }
}

private struct RegistryCredentialCaptureStrategy: UsageFetchStrategy {
    let id: String
    let providerID: UsageProviderID
    let recorder: RegistryBridgeRecorder

    func isAvailable(_ context: UsageFetchContext) async -> Bool { true }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        await recorder.recordCredential(context.credential(providerID), for: providerID)
        return snapshot(providerID)
    }

    func shouldFallback(on error: Error) -> Bool { false }
}

// MARK: - resolveUsageSnapshot pipeline

@Test("resolveUsageSnapshot: the first available, succeeding strategy wins")
func pipelineFirstSuccessWins() async {
    let first = StubStrategy(id: "first", result: .success(snapshot(percent: 1)))
    let second = StubStrategy(id: "second", result: .success(snapshot(percent: 2)))
    let result = await resolveUsageSnapshot(
        strategies: [first, second], context: fixtureContext())
    #expect(result?.windows.first?.percent == 1)
}

@Test("resolveUsageSnapshot: an unavailable strategy is skipped, not tried")
func pipelineSkipsUnavailable() async {
    let unavailable = StubStrategy(
        id: "unavailable", available: false, result: .success(snapshot(percent: 1)))
    let available = StubStrategy(id: "available", result: .success(snapshot(percent: 2)))
    let result = await resolveUsageSnapshot(
        strategies: [unavailable, available], context: fixtureContext())
    #expect(result?.windows.first?.percent == 2)
}

@Test("resolveUsageSnapshot: a throw with shouldFallback(true) continues to the next strategy")
func pipelineContinuesOnFallbackTrue() async {
    let failing = StubStrategy(
        id: "failing", result: .failure(UsageLocalDataError.noData), fallback: true)
    let succeeding = StubStrategy(id: "succeeding", result: .success(snapshot(percent: 3)))
    let result = await resolveUsageSnapshot(
        strategies: [failing, succeeding], context: fixtureContext())
    #expect(result?.windows.first?.percent == 3)
}

@Test("resolveUsageSnapshot: a throw with shouldFallback(false) stops the pipeline immediately")
func pipelineStopsOnFallbackFalse() async {
    let failing = StubStrategy(
        id: "failing", result: .failure(UsageLocalDataError.noData), fallback: false)
    let neverTried = StubStrategy(id: "never-tried", result: .success(snapshot(percent: 4)))
    let result = await resolveUsageSnapshot(
        strategies: [failing, neverTried], context: fixtureContext())
    #expect(result == nil)
}

@Test("resolveUsageSnapshot: every strategy failing/unavailable yields nil, never a crash")
func pipelineTotalFailureYieldsNil() async {
    let unavailable = StubStrategy(id: "unavailable", available: false)
    let failing = StubStrategy(
        id: "failing", result: .failure(UsageLocalDataError.noData), fallback: true)
    let result = await resolveUsageSnapshot(
        strategies: [unavailable, failing], context: fixtureContext())
    #expect(result == nil)
}

@Test("resolveUsageSnapshot: an empty strategy list yields nil")
func pipelineEmptyStrategiesYieldsNil() async {
    let result = await resolveUsageSnapshot(strategies: [], context: fixtureContext())
    #expect(result == nil)
}

// MARK: - UsageSnapshot.renderable

@Test("UsageSnapshot.renderable: false only when both windows and costLine are empty/nil")
func snapshotRenderable() {
    #expect(
        UsageSnapshot(providerID: .claude, windows: [], costLine: nil, identity: nil).renderable
            == false)
    #expect(
        UsageSnapshot(
            providerID: .claude,
            windows: [UsageWindow(label: "5h", percent: 1, tokens: nil, resetsAt: nil)],
            costLine: nil, identity: nil
        ).renderable == true)
    #expect(
        UsageSnapshot(providerID: .claude, windows: [], costLine: "$1.00", identity: nil)
            .renderable == true)
}

// MARK: - UsageHTTPClient redaction

@Test("UsageHTTPError: no case can carry a token, header, or body — String(describing:) is safe")
func usageHTTPErrorRedaction() {
    let cases: [UsageHTTPError] = [
        .rateLimited(retryAfter: 30), .httpStatus(429), .timedOut, .transportFailure,
        .invalidResponse,
    ]
    let secret = "sk-super-secret-token-should-never-appear"
    for error in cases {
        let described = String(describing: error)
        #expect(!described.contains(secret))
        #expect(!described.lowercased().contains("bearer"))
        #expect(!described.lowercased().contains("cookie"))
    }
}

@Test("UsageHTTPClient: a 429 response is surfaced as .rateLimited with the Retry-After value")
func usageHTTPClientSurfacesRateLimit() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let client = UsageHTTPClient(transport: { request in
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "5"]))
        return (Data(), response)
    })
    do {
        _ = try await client.send(URLRequest(url: url), provider: .claude)
        Issue.record("expected UsageHTTPError.rateLimited to be thrown")
    } catch UsageHTTPError.rateLimited(let retryAfter) {
        #expect(retryAfter == 5)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Test(
    "UsageHTTPClient: a subsequent request for the same provider is gated until Retry-After elapses"
)
func usageHTTPClientGatesSubsequentRequests() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let counter = CallCounter()
    let client = UsageHTTPClient(transport: { request in
        await counter.increment()
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "300"]))
        return (Data(), response)
    })
    _ = try? await client.send(URLRequest(url: url), provider: .claude)
    #expect(await counter.count == 1)
    // Second attempt should be gated in-memory without invoking the
    // transport at all.
    _ = try? await client.send(URLRequest(url: url), provider: .claude)
    #expect(await counter.count == 1)
}

@Test("UsageHTTPClient: a non-2xx, non-429 status throws .httpStatus")
func usageHTTPClientSurfacesHTTPStatus() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let client = UsageHTTPClient(transport: { request in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    })
    do {
        _ = try await client.send(URLRequest(url: url), provider: .codex)
        Issue.record("expected UsageHTTPError.httpStatus to be thrown")
    } catch UsageHTTPError.httpStatus(let status) {
        #expect(status == 500)
    }
}

@Test("UsageHTTPClient: a 2xx response returns the transport's data unchanged")
func usageHTTPClientSurfacesSuccess() async throws {
    let url = try #require(URL(string: "https://example.com/usage"))
    let payload = Data("{\"ok\":true}".utf8)
    let client = UsageHTTPClient(transport: { request in
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (payload, response)
    })
    let (data, response) = try await client.send(URLRequest(url: url), provider: .codex)
    #expect(data == payload)
    #expect(response.statusCode == 200)
}

// MARK: - Claude/Codex provider parsing (migrated from
// Tests/RafuAppTests/AgentUsageTests.swift — the pre-W0
// `CodexUsageParser`/`ClaudeUsageParser`/`AgentUsageReader.tiles(now:)`
// tests, adapted to `CodexLocalRolloutStrategy`/`ClaudeLocalTranscriptStrategy`
// /`UsageRegistryReader` producing `UsageSnapshot` instead of
// `AgentUsageTile`. Every fixture mirrors the real on-disk shapes verified
// 2026-07-22 (see `CodexProvider.swift`/`ClaudeProvider.swift`'s doc
// comments) — no test here ever touches `~/.codex`/`~/.claude`.

private func iso8601Fractional(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

@Test(
    "CodexLocalRolloutStrategy.parse: the LAST line carrying rate_limits wins over an earlier one")
func codexParserLastLineWins() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        {"timestamp":"2026-07-18T14:49:39.662Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":2},"secondary":null}}}
        """
    let snapshot = CodexLocalRolloutStrategy.parse(rolloutContents: contents, now: Date())
    #expect(snapshot?.providerID == .codex)
    #expect(snapshot?.windows.count == 1)
    #expect(snapshot?.windows.first?.percent == 42.5)
    #expect(snapshot?.windows.first?.tokens == nil)
}

@Test(
    "CodexLocalRolloutStrategy.parse: primary+secondary map to correct 5h/7d labels and percentages"
)
func codexParserPrimaryAndSecondary() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":17.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":6.0,"window_minutes":10080,"resets_at":2}}}}
        """
    let snapshot = CodexLocalRolloutStrategy.parse(rolloutContents: contents, now: Date())
    #expect(snapshot?.windows.count == 2)
    #expect(
        snapshot?.windows[0] == UsageWindow(label: "5h", percent: 17.0, tokens: nil, resetsAt: nil)
    )
    #expect(
        snapshot?.windows[1] == UsageWindow(label: "7d", percent: 6.0, tokens: nil, resetsAt: nil)
    )
}

@Test(
    "CodexLocalRolloutStrategy.parse: a primary-only rate_limits (no secondary key) yields exactly one window"
)
func codexParserPrimaryOnly() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1784989552}}}}
        """
    let snapshot = CodexLocalRolloutStrategy.parse(rolloutContents: contents, now: Date())
    #expect(
        snapshot?.windows == [UsageWindow(label: "7d", percent: 0.0, tokens: nil, resetsAt: nil)])
}

@Test(
    "CodexLocalRolloutStrategy.parse: an explicit secondary: null yields exactly one window, same as a missing key"
)
func codexParserSecondaryExplicitNull() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let snapshot = CodexLocalRolloutStrategy.parse(rolloutContents: contents, now: Date())
    #expect(
        snapshot?.windows == [UsageWindow(label: "5h", percent: 3.0, tokens: nil, resetsAt: nil)])
}

@Test("CodexLocalRolloutStrategy.parse: no line anywhere carries rate_limits -> nil, never a crash")
func codexParserNoRateLimitsReturnsNil() {
    let contents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}}}}
        {"timestamp":"2026-07-18T14:49:30.000Z","type":"session_meta","payload":{"id":"abc"}}
        """
    #expect(CodexLocalRolloutStrategy.parse(rolloutContents: contents, now: Date()) == nil)
}

@Test(
    "CodexLocalRolloutStrategy.parse: malformed JSON lines are skipped, not thrown; a later valid line still parses"
)
func codexParserSkipsMalformedLines() {
    let contents = """
        not even json
        {"broken
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let snapshot = CodexLocalRolloutStrategy.parse(rolloutContents: contents, now: Date())
    #expect(
        snapshot?.windows == [UsageWindow(label: "5h", percent: 9.0, tokens: nil, resetsAt: nil)])
}

@Test(
    "CodexLocalRolloutStrategy.label: sub-day rounds to hours, day-or-more rounds to days, invalid falls back"
)
func codexParserWindowLabels() {
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: 300) == "5h")
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: 10080) == "7d")
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: 60) == "1h")
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: 1440) == "1d")
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: nil) == "usage")
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: 0) == "usage")
    #expect(CodexLocalRolloutStrategy.label(forWindowMinutes: -5) == "usage")
}

@Test(
    "ClaudeLocalTranscriptStrategy.parse: sums into 5h/7d buckets; a >7d-old message is excluded; a 5h message counts in both"
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

    let snapshot = ClaudeLocalTranscriptStrategy.parse(transcriptLines: lines, now: now)
    #expect(snapshot?.providerID == .claude)
    let byLabel = Dictionary(uniqueKeysWithValues: (snapshot?.windows ?? []).map { ($0.label, $0) })
    #expect(byLabel["5h"]?.tokens == 100)
    #expect(byLabel["7d"]?.tokens == 1_100)
    #expect(byLabel["5h"]?.percent == nil)
    #expect(byLabel["7d"]?.percent == nil)
}

@Test("ClaudeLocalTranscriptStrategy.parse: no usage anywhere returns nil")
func claudeParserNoUsageReturnsNil() {
    let now = Date()
    let lines = [
        """
        {"timestamp":"\(iso8601Fractional(now))","type":"user","message":{"role":"user","content":"hi"}}
        """
    ]
    #expect(ClaudeLocalTranscriptStrategy.parse(transcriptLines: lines, now: now) == nil)
}

@Test(
    "ClaudeLocalTranscriptStrategy.parse: a line missing message.usage is skipped without affecting other lines"
)
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
    let snapshot = ClaudeLocalTranscriptStrategy.parse(
        transcriptLines: [withoutUsage, withUsage], now: now)
    let byLabel = Dictionary(uniqueKeysWithValues: (snapshot?.windows ?? []).map { ($0.label, $0) })
    #expect(byLabel["5h"]?.tokens == 75)
    #expect(byLabel["7d"]?.tokens == 75)
}

@Test(
    "ClaudeLocalTranscriptStrategy.parse: a fractional-second ISO timestamp (as observed on disk) parses correctly"
)
func claudeParserParsesFractionalSecondTimestamp() throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fixedTimestamp = "2026-07-13T04:57:21.205Z"
    let parsedDate = try #require(formatter.date(from: fixedTimestamp))
    let now = parsedDate.addingTimeInterval(60 * 60)

    let line = """
        {"timestamp":"\(fixedTimestamp)","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":29644,"cache_read_input_tokens":0,"output_tokens":53}}}
        """
    let snapshot = ClaudeLocalTranscriptStrategy.parse(transcriptLines: [line], now: now)
    let byLabel = Dictionary(uniqueKeysWithValues: (snapshot?.windows ?? []).map { ($0.label, $0) })
    #expect(byLabel["5h"]?.tokens == 29_699)
    #expect(byLabel["7d"]?.tokens == 29_699)
}

@Test("compactTokenCount: below 1000 is exact; K/M round to one decimal, dropping a trailing .0")
func compactTokenCountFormatting() {
    #expect(UsageFormat.compactTokenCount(999) == "999")
    #expect(UsageFormat.compactTokenCount(1_234) == "1.2K")
    #expect(UsageFormat.compactTokenCount(1_234_567) == "1.2M")
    #expect(UsageFormat.compactTokenCount(1_000) == "1K")
    #expect(UsageFormat.compactTokenCount(1_000_000) == "1M")
    #expect(UsageFormat.compactTokenCount(0) == "0")
}

@Test(
    "UsageRegistryReader.snapshots: composes Claude and Codex snapshots from the real descriptors, Claude first"
)
func usageRegistryReaderComposesBothSnapshots() async {
    let now = Date()
    let claudeLine = """
        {"timestamp":"\(iso8601Fractional(now.addingTimeInterval(-60)))","message":{"usage":{"input_tokens":10,"output_tokens":5}}}
        """
    let codexContents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let claudeDescriptor = UsageProviderDescriptor(
        id: .claude, displayName: "Claude", authPattern: .localZeroConfig, disclosure: "",
        defaultEnabled: true,
        makeStrategies: { _ in
            [ClaudeLocalTranscriptStrategy(recentTranscriptLines: { _ in [claudeLine] })]
        })
    let codexDescriptor = UsageProviderDescriptor(
        id: .codex, displayName: "Codex", authPattern: .localZeroConfig, disclosure: "",
        defaultEnabled: true,
        makeStrategies: { _ in
            [CodexLocalRolloutStrategy(newestRolloutContents: { codexContents })]
        })
    let reader = UsageRegistryReader(
        descriptors: [claudeDescriptor, codexDescriptor],
        makeContext: { now in fixtureContext(now: now) },
        isEnabled: { _ in true },
        resolveCredentials: { _, _ in [:] }
    )

    let snapshots = await reader.snapshots(now: now)

    #expect(snapshots.map(\.providerID) == [.claude, .codex])
}

@Test(
    "UsageRegistryReader.snapshots: a disabled descriptor is skipped even with working strategies")
func usageRegistryReaderSkipsDisabledDescriptor() async {
    let now = Date()
    let codexContents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    let codexDescriptor = UsageProviderDescriptor(
        id: .codex, displayName: "Codex", authPattern: .localZeroConfig, disclosure: "",
        defaultEnabled: true,
        makeStrategies: { _ in
            [CodexLocalRolloutStrategy(newestRolloutContents: { codexContents })]
        })
    let reader = UsageRegistryReader(
        descriptors: [codexDescriptor],
        makeContext: { now in fixtureContext(now: now) },
        isEnabled: { _ in false },
        resolveCredentials: { _, _ in [:] }
    )

    #expect(await reader.snapshots(now: now).isEmpty)
}

@Test(
    "UsageRegistryReader.snapshots: a stub descriptor (empty strategies) is skipped, never a crash")
func usageRegistryReaderSkipsEmptyStrategies() async {
    let reader = UsageRegistryReader(
        descriptors: [ClineProvider.descriptor],
        makeContext: { now in fixtureContext(now: now) },
        isEnabled: { _ in true },
        resolveCredentials: { _, _ in [:] }
    )
    #expect(await reader.snapshots(now: Date()).isEmpty)
}

@Test(
    "UsageRegistryReader resolves enabled IDs before context and captures resolved plus base credentials"
)
func usageRegistryReaderCredentialBridgeOrdering() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let recorder = RegistryBridgeRecorder()
    func descriptor(_ id: UsageProviderID) -> UsageProviderDescriptor {
        UsageProviderDescriptor(
            id: id, displayName: id.rawValue, authPattern: .localZeroConfig,
            disclosure: "fixture", defaultEnabled: true,
            makeStrategies: { _ in
                [
                    RegistryCredentialCaptureStrategy(
                        id: "\(id.rawValue).capture", providerID: id, recorder: recorder)
                ]
            })
    }
    let reader = UsageRegistryReader(
        descriptors: [descriptor(.claude), descriptor(.codex), descriptor(.cline)],
        makeContext: { now in
            await recorder.recordEvent("context")
            return fixtureContext(
                now: now,
                credential: { id in id == .codex ? "base-codex" : nil })
        },
        isEnabled: { $0 != .cline },
        resolveCredentials: { ids, _ in
            await recorder.recordEvent("resolver")
            await recorder.recordRequestedIDs(ids)
            return [.claude: "resolved-claude"]
        })

    let snapshots = await reader.snapshots(now: now)

    #expect(snapshots.map(\.providerID) == [.claude, .codex])
    #expect(await recorder.events == ["resolver", "context"])
    #expect(await recorder.requestedIDs == [.claude, .codex])
    #expect(await recorder.credentials[.claude] == "resolved-claude")
    #expect(await recorder.credentials[.codex] == "base-codex")
    #expect(await recorder.credentials[.cline] == nil)
}

@Test("UsageRegistryReader accepts a synchronous makeContext closure after the async bridge")
func usageRegistryReaderSyncContextClosureStillCompiles() async {
    let reader = UsageRegistryReader(
        descriptors: [],
        makeContext: { now in fixtureContext(now: now) },
        isEnabled: { _ in true },
        resolveCredentials: { _, _ in [:] })

    #expect(await reader.snapshots(now: Date()).isEmpty)
}

// MARK: - Rendering parity (agent-usage-providers.md, "Multi-provider
// display in the notch": Claude/Codex front-line tiles must render
// IDENTICALLY to the pre-W0 companion strip). `UsageDisplayPolicy` lives
// in `NotchCompanionPolicy.swift` (added alongside the companion
// migration); this test proves the new pure-text path produces the exact
// same string the OLD `CompanionUsageStripView.summary` built from
// `AgentUsageTile`s for the same fixture — a byte-for-byte comparison
// against a hardcoded "before" literal, not a screenshot (W0 stays
// headless; the coordinator's post-merge GUI pass covers the pixels).
@Test(
    "UsageDisplayPolicy front-line text for a Claude+Codex fixture matches the pre-W0 rendered string exactly"
)
func frontLineTextMatchesPreW0Rendering() {
    let claudeSnapshot = UsageSnapshot(
        providerID: .claude,
        windows: [
            UsageWindow(label: "5h", percent: nil, tokens: 100, resetsAt: nil),
            UsageWindow(label: "7d", percent: nil, tokens: 1_100, resetsAt: nil),
        ], costLine: nil, identity: nil)
    let codexSnapshot = UsageSnapshot(
        providerID: .codex,
        windows: [
            UsageWindow(label: "5h", percent: 3.0, tokens: nil, resetsAt: nil),
            UsageWindow(label: "7d", percent: 6.0, tokens: nil, resetsAt: nil),
        ], costLine: nil, identity: nil)

    let tiles = [
        UsageDisplayPolicy.renderedTile(for: claudeSnapshot, displayName: "Claude"),
        UsageDisplayPolicy.renderedTile(for: codexSnapshot, displayName: "Codex"),
    ]
    let rendered = UsageDisplayPolicy.plainFrontLineText(tiles)

    // The EXACT string the pre-W0 `CompanionUsageStripView.summary` /
    // `AgentUsageFormat.compactTokenCount` produced for this fixture —
    // computed by hand from the deleted `tileSummary`/`windowSummary`
    // logic, never re-derived from the new code under test.
    let preW0Rendering = "Claude · 5h 100 tok · 7d 1.1K tok    Codex · 5h 3% · 7d 6%"
    #expect(rendered == preW0Rendering)
}
