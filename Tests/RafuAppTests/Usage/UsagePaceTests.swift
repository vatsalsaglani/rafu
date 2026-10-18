import Foundation
import Synchronization
import Testing

@testable import RafuApp

// Synthetic data only: no test here reads `~`, the network, or a Keychain.

private let paceNow = Date(timeIntervalSince1970: 1_800_000_000)

/// A 5-hour window that resets in 2 hours, so 3 hours have elapsed at
/// `paceNow`.
private func sessionWindow(
    percent: Double?, resetIn: TimeInterval? = 2 * 3_600, minutes: Int? = 300
) -> UsageWindow {
    UsageWindow(
        label: "5h", percent: percent, tokens: nil,
        resetsAt: resetIn.map { paceNow.addingTimeInterval($0) }, windowMinutes: minutes)
}

private func paceCredentials(token: String, expiresAt: Date) -> String {
    let milliseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000)
    return #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(milliseconds)}}"#
}

private let fullClaudeResponse = """
    {
      "five_hour": { "utilization": 42.0, "resets_at": "2026-07-23T12:00:00.123456+00:00" },
      "seven_day": { "utilization": 18.5, "resets_at": "2026-07-29T00:00:00+00:00" },
      "seven_day_oauth_apps": null,
      "seven_day_opus": { "utilization": 7.0, "resets_at": "2026-07-29T00:00:00.000Z" },
      "seven_day_sonnet": { "utilization": 3.0, "resets_at": null },
      "extra_usage": { "is_enabled": false },
      "limits": [
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 70,
          "resets_at": "2026-07-29T00:00:00.000Z",
          "scope": { "model": { "id": "claude-opus", "display_name": "Opus" } }
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 11,
          "resets_at": "2026-07-29T00:00:00.000Z",
          "scope": { "model": { "id": "claude-fable", "display_name": "Fable" } }
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 50,
          "scope": { "model": { "id": "all-models", "display_name": "All models" } }
        },
        {
          "kind": "daily", "group": "daily", "percent": 99,
          "scope": { "model": { "id": "claude-other", "display_name": "Other" } }
        }
      ]
    }
    """

// MARK: - Claude parsing

@Test("Claude parses every window Cider shows: session, weekly, and each model weekly")
func claudeParsesFullSyntheticResponse() throws {
    let snapshot = try ClaudeOAuthStrategy.parseUsage(Data(fullClaudeResponse.utf8))

    #expect(snapshot.source == .providerAPI)
    #expect(snapshot.windows.map(\.label) == ["5h", "7d", "Opus 7d", "Sonnet 7d", "Fable 7d"])
    #expect(snapshot.windows.map(\.percent) == [42, 18.5, 7, 3, 11])
    #expect(snapshot.windows.map(\.windowMinutes) == [300, 10_080, 10_080, 10_080, 10_080])

    let session = try #require(snapshot.windows[0].resetsAt)
    #expect(abs(session.timeIntervalSince1970 - 1_784_808_000.123) < 0.01)
    #expect(snapshot.windows[1].resetsAt == Date(timeIntervalSince1970: 1_785_283_200))
    #expect(snapshot.windows[2].resetsAt == Date(timeIntervalSince1970: 1_785_283_200))
    #expect(snapshot.windows[3].resetsAt == nil)
}

@Test("Claude utilization is a 0–100 percentage: small values stay, over-limit clamps")
func claudeUtilizationScale() throws {
    let body = """
        {
          "five_hour": { "utilization": 0.5 },
          "seven_day": { "utilization": 104.2 },
          "seven_day_opus": { "utilization": -1 },
          "seven_day_sonnet": { "utilization": 5000 }
        }
        """
    let snapshot = try ClaudeOAuthStrategy.parseUsage(Data(body.utf8))

    #expect(snapshot.windows.map(\.label) == ["5h", "7d"])
    #expect(snapshot.windows.map(\.percent) == [0.5, 100])
    #expect(ClaudeOAuthStrategy.validPercent(1) == 1)
    #expect(ClaudeOAuthStrategy.validPercent(nil) == nil)
    #expect(ClaudeOAuthStrategy.validPercent(.infinity) == nil)
}

@Test("A malformed optional model lane cannot hide the session and weekly windows")
func claudeMalformedModelLaneIsIgnored() throws {
    let body = """
        {
          "five_hour": { "utilization": 10 },
          "seven_day": { "utilization": 20 },
          "seven_day_opus": { "utilization": "not a number" }
        }
        """
    let snapshot = try ClaudeOAuthStrategy.parseUsage(Data(body.utf8))
    #expect(snapshot.windows.map(\.label) == ["5h", "7d"])
}

@Test("Claude caps a snapshot at six windows")
func claudeWindowCap() throws {
    let limits = (0..<8).map { index in
        """
        {"kind":"weekly_scoped","group":"weekly","percent":\(index),\
        "scope":{"model":{"id":"m\(index)","display_name":"M\(index)"}}}
        """
    }.joined(separator: ",")
    let body =
        #"{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"limits":["#
        + limits + "]}"
    let snapshot = try ClaudeOAuthStrategy.parseUsage(Data(body.utf8))
    #expect(snapshot.windows.count == ClaudeOAuthStrategy.maximumWindows)
    #expect(snapshot.windows.last?.label == "M3 7d")
}

@Test("Timestamps with microseconds and an offset parse to millisecond precision")
func usageDateParsingAcceptsMicroseconds() throws {
    #expect(
        UsageDateParsing.truncatingExtraFractionDigits("2026-07-23T12:00:00.123456+00:00")
            == "2026-07-23T12:00:00.123+00:00")
    #expect(UsageDateParsing.truncatingExtraFractionDigits("2026-07-23T12:00:00.123Z") == nil)
    #expect(UsageDateParsing.truncatingExtraFractionDigits("not a date") == nil)
    let date = try #require(
        UsageDateParsing.parseISO8601Fractional("2026-07-23T12:00:00.987654Z"))
    #expect(abs(date.timeIntervalSince1970 - 1_784_808_000.987) < 0.01)
}

@Test("The local transcript estimate is marked as an estimate")
func claudeLocalSnapshotIsEstimate() throws {
    let line =
        #"{"timestamp":"2026-07-23T11:00:00.000Z","message":{"usage":{"input_tokens":10,"output_tokens":5}}}"#
    let now = try #require(UsageDateParsing.parseISO8601Fractional("2026-07-23T12:00:00.000Z"))
    let snapshot = try #require(
        ClaudeLocalTranscriptStrategy.parse(transcriptLines: [line], now: now))
    #expect(snapshot.source == .localEstimate)
    #expect(snapshot.windows.allSatisfy { $0.percent == nil })
}

@Test("Codex exact windows carry their length; absurd lengths carry none")
func codexWindowMinutes() {
    #expect(CodexOAuthStrategy.windowMinutes(seconds: 18_000) == 300)
    #expect(CodexOAuthStrategy.windowMinutes(seconds: 604_800) == 10_080)
    #expect(CodexOAuthStrategy.windowMinutes(seconds: 10) == nil)
    #expect(CodexOAuthStrategy.windowMinutes(seconds: 1e300) == nil)
}

// MARK: - Pace

@Test("Pace: on pace when the projection stays well under the limit")
func paceEnough() {
    let pace = UsagePace.estimate(
        window: sessionWindow(percent: 30), observedAt: paceNow, now: paceNow)
    #expect(pace.state == .enough)
    #expect(pace.note == "On pace · ~50% spare at reset")
    #expect(!pace.warning)
    #expect(abs((pace.projectedUsedAtReset ?? 0) - 50) < 0.001)
    #expect(abs((pace.hourlyPercent ?? 0) - 10) < 0.001)
}

@Test("Pace: tight when the projection lands between 95 % and 100 %")
func paceTight() {
    let pace = UsagePace.estimate(
        window: sessionWindow(percent: 58), observedAt: paceNow, now: paceNow)
    #expect(pace.state == .tight)
    #expect(pace.note == "Tight · near the limit at reset")
    #expect(pace.warning)
}

@Test("Pace: running out estimates when the limit is reached")
func paceRunningOut() throws {
    let pace = UsagePace.estimate(
        window: sessionWindow(percent: 90), observedAt: paceNow, now: paceNow)
    #expect(pace.state == .runningOut)
    #expect(pace.note.hasPrefix("May run out in "))
    #expect(pace.warning)
    let exhaustion = try #require(pace.estimatedExhaustion)
    #expect(abs(exhaustion.timeIntervalSince(paceNow) - 1_200) < 1)
}

@Test("Pace: a reached limit is exhausted even without a reset time")
func paceExhausted() {
    let pace = UsagePace.estimate(
        window: sessionWindow(percent: 100, resetIn: nil), observedAt: nil, now: paceNow)
    #expect(pace.state == .exhausted)
    #expect(pace.note == "Limit reached · wait for reset")
    #expect(pace.warning)
}

@Test("Pace: every unknown reason has its own note")
func paceUnknownReasons() {
    func reason(_ window: UsageWindow, observedAt: Date? = paceNow) -> UsagePace.UnknownReason? {
        UsagePace.estimate(window: window, observedAt: observedAt, now: paceNow).unknownReason
    }
    #expect(reason(sessionWindow(percent: nil)) == .notReported)
    #expect(reason(sessionWindow(percent: 30), observedAt: nil) == .stale)
    #expect(
        reason(sessionWindow(percent: 30), observedAt: paceNow.addingTimeInterval(-30 * 60))
            == .stale)
    #expect(reason(sessionWindow(percent: 30, resetIn: nil)) == .resetUnavailable)
    #expect(reason(sessionWindow(percent: 30, resetIn: -60)) == .resetPassed)
    #expect(reason(sessionWindow(percent: 30, minutes: nil)) == .windowUnavailable)
    #expect(reason(sessionWindow(percent: 30, minutes: 0)) == .windowUnavailable)
    #expect(reason(sessionWindow(percent: 30, resetIn: 4 * 3_600 + 55 * 60)) == .tooEarly)

    let unknown = UsagePace.unknown(.tooEarly)
    #expect(unknown.state == .unknown)
    #expect(unknown.note == "Too early to estimate pace")
    #expect(!unknown.warning)
    #expect(UsagePace.note(for: .resetPassed) == "Reset passed · refreshing soon")
}

@Test("Duration labels round up and never read zero")
func paceDurationLabels() {
    #expect(UsagePace.durationLabel(0) == "1m")
    #expect(UsagePace.durationLabel(59) == "1m")
    #expect(UsagePace.durationLabel(61) == "2m")
    #expect(UsagePace.durationLabel(2 * 3_600 + 10 * 60) == "2h 10m")
    #expect(UsagePace.durationLabel(3 * 86_400 + 4 * 3_600) == "3d 4h")
    #expect(UsagePace.durationLabel(.infinity) == "1m")
    #expect(UsagePace.durationLabel(1e30) == "3650d 0h")
}

// MARK: - Labels, display mode, rings

@Test("Short labels keep Rafu's labels and replace generic ones with the window length")
func usageShortLabels() {
    func window(_ label: String, minutes: Int?) -> UsageWindow {
        UsageWindow(label: label, percent: 1, tokens: nil, resetsAt: nil, windowMinutes: minutes)
    }
    #expect(UsageWindowPresentation.shortLabel(for: window("5h", minutes: 300)) == "5h")
    #expect(
        UsageWindowPresentation.shortLabel(for: window("Opus 7d", minutes: 10_080)) == "Opus 7d")
    #expect(UsageWindowPresentation.shortLabel(for: window("Session", minutes: 300)) == "5h")
    #expect(UsageWindowPresentation.shortLabel(for: window("weekly", minutes: 10_080)) == "7d")
    #expect(UsageWindowPresentation.shortLabel(for: window("weekly", minutes: nil)) == "weekly")
    #expect(UsageWindowPresentation.shortLabel(for: window("daily", minutes: 90)) == "90m")

    #expect(UsageWindowPresentation.title(for: window("5h", minutes: nil)) == "5-hour session")
    #expect(UsageWindowPresentation.title(for: window("7d", minutes: nil)) == "Weekly")
    #expect(UsageWindowPresentation.title(for: window("30d", minutes: nil)) == "30-day")
    #expect(UsageWindowPresentation.title(for: window("Opus 7d", minutes: nil)) == "Opus weekly")
    #expect(UsageWindowPresentation.title(for: window("monthly", minutes: nil)) == "monthly")
}

@Test("Reset and age labels")
func usageResetAndAgeLabels() {
    #expect(
        UsageWindowPresentation.resetLabel(
            for: sessionWindow(percent: 10, resetIn: 2 * 3_600 + 10 * 60), now: paceNow)
            == "↻ 2h 10m")
    #expect(
        UsageWindowPresentation.resetLabel(
            for: sessionWindow(percent: 10, resetIn: -1), now: paceNow)
            == "Reset due")
    #expect(
        UsageWindowPresentation.resetLabel(
            for: sessionWindow(percent: 10, resetIn: nil), now: paceNow)
            == "Reset unknown")
    #expect(
        UsageWindowPresentation.resetLabel(
            for: sessionWindow(percent: nil, resetIn: nil), now: paceNow)
            == "Not reported")
    #expect(
        UsageWindowPresentation.ageLabel(observedAt: paceNow.addingTimeInterval(-30), now: paceNow)
            == "Just updated")
    #expect(
        UsageWindowPresentation.ageLabel(observedAt: paceNow.addingTimeInterval(-300), now: paceNow)
            == "5m ago")
}

@Test("The hourly average keeps at most two decimals and drops trailing zeros")
func usageHourlyAverageText() {
    #expect(UsageWindowPresentation.hourlyAverageText(10) == "Average 10% of this limit per hour")
    #expect(
        UsageWindowPresentation.hourlyAverageText(4.256) == "Average 4.26% of this limit per hour")
    #expect(UsageWindowPresentation.hourlyAverageText(0.5) == "Average 0.5% of this limit per hour")
    #expect(UsageWindowPresentation.hourlyAverageText(.nan) == "Average not available")
}

@Test("Used and Remaining map the same window to complementary percentages")
func usageDisplayModeMapping() {
    let window = sessionWindow(percent: 30)
    #expect(UsageDisplayMode.used.percent(for: window) == 30)
    #expect(UsageDisplayMode.remaining.percent(for: window) == 70)
    #expect(UsageDisplayMode.remaining.percent(for: sessionWindow(percent: nil)) == nil)
    #expect(UsageDisplayMode.used.percent(for: sessionWindow(percent: 140)) == nil)
    #expect(UsageDisplayMode.used.title == "Used")
    #expect(UsageDisplayMode.remaining.title == "Remaining")
}

@Test("The display mode persists in its store and defaults to Used")
func usageDisplayModeStoreRoundTrip() {
    let suite = "UsageDisplayModeStoreTests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = UsageDisplayModeStore(suiteName: suite)
    #expect(store.mode() == .used)
    store.setMode(.remaining)
    #expect(UsageDisplayModeStore(suiteName: suite).mode() == .remaining)
}

@Test("Ring fractions clamp to 0...1 and reject non-finite values")
func usageRingFractionClamping() {
    #expect(UsageRingLevel.fraction(percent: 50) == 0.5)
    #expect(UsageRingLevel.fraction(percent: -5) == 0)
    #expect(UsageRingLevel.fraction(percent: 140) == 1)
    #expect(UsageRingLevel.fraction(percent: nil) == nil)
    #expect(UsageRingLevel.fraction(percent: .nan) == nil)
    #expect(UsageRingLevel.fraction(percent: .infinity) == nil)
}

@Test("Ring levels follow the used share and the pace, never the display mode")
func usageRingLevels() {
    let calm = UsagePace.unknown(.tooEarly)
    #expect(UsageRingLevel.level(usedPercent: 10, pace: calm) == .normal)
    #expect(UsageRingLevel.level(usedPercent: 80, pace: calm) == .warning)
    #expect(UsageRingLevel.level(usedPercent: 95, pace: calm) == .critical)
    let tight = UsagePace.estimate(
        window: sessionWindow(percent: 58), observedAt: paceNow, now: paceNow)
    #expect(UsageRingLevel.level(usedPercent: 58, pace: tight) == .warning)
}

// MARK: - Card presentation

private func makeSnapshot(
    _ id: UsageProviderID, _ windows: [UsageWindow], source: UsageDataSource = .providerAPI
) -> UsageSnapshot {
    UsageSnapshot(providerID: id, windows: windows, costLine: nil, identity: nil, source: source)
}

@Test("The pace summary picks the most urgent window")
func usagePaceSummaryPicksWarning() throws {
    let calm = UsageWindow(
        label: "7d", percent: 10, tokens: nil, resetsAt: paceNow.addingTimeInterval(3 * 86_400),
        windowMinutes: 10_080)
    let urgent = sessionWindow(percent: 90)
    let summary = try #require(
        UsageCardPresentation.paceSummary(
            makeSnapshot(.claude, [calm, urgent]), observedAt: paceNow, now: paceNow))
    #expect(summary.warning)
    #expect(summary.text.hasPrefix("5h · May run out in "))
    #expect(
        UsageCardPresentation.paceSummary(
            makeSnapshot(.claude, []), observedAt: paceNow, now: paceNow) == nil)
}

@Test("Token-only windows render as one compact line and draw no ring")
func usageTokenLine() {
    let local = makeSnapshot(
        .claude,
        [
            UsageWindow(label: "5h", percent: nil, tokens: 120_000, resetsAt: nil),
            UsageWindow(label: "7d", percent: nil, tokens: 1_400_000, resetsAt: nil),
        ], source: .localEstimate)
    #expect(UsageCardPresentation.ringWindows(local).isEmpty)
    #expect(UsageCardPresentation.tokenLine(local) == "5h 120K tok · 7d 1.4M tok")
    let exact = makeSnapshot(.claude, [sessionWindow(percent: 1), sessionWindow(percent: 2)])
    #expect(UsageCardPresentation.tokenLine(exact) == nil)
    let many = makeSnapshot(.claude, Array(repeating: sessionWindow(percent: 1), count: 5))
    #expect(UsageCardPresentation.ringWindows(many, cap: 3).count == 3)
}

@Test("Local Claude and Codex cards offer Connect, or Reconnect once consent exists")
func usageConnectPrompts() {
    let local = makeSnapshot(.claude, [], source: .localEstimate)
    let exact = makeSnapshot(.claude, [sessionWindow(percent: 1)])
    #expect(
        UsageCardPresentation.connectPrompt(
            for: local, authPattern: .piggybackNetwork, hasNetworkConsent: false) == .connect)
    #expect(
        UsageCardPresentation.connectPrompt(
            for: local, authPattern: .piggybackNetwork, hasNetworkConsent: true) == .reconnect)
    #expect(
        UsageCardPresentation.connectPrompt(
            for: exact, authPattern: .piggybackNetwork, hasNetworkConsent: true) == nil)
    #expect(
        UsageCardPresentation.connectPrompt(
            for: local, authPattern: .apiKey, hasNetworkConsent: false) == nil)
    #expect(UsageConnectPrompt.connect.buttonTitle == "Connect for exact usage…")
    #expect(
        UsageCardPresentation.sourceLabel(for: local, displayName: "Claude")
            == "Estimated from local transcripts")
    #expect(
        UsageCardPresentation.sourceLabel(
            for: makeSnapshot(.codex, [], source: .localReport), displayName: "Codex")
            == "From the newest local Codex session")
    #expect(
        UsageCardPresentation.sourceLabel(
            for: makeSnapshot(.amp, [], source: .unspecified), displayName: "Amp") == nil)
}

@Test("Retention keeps the last good snapshot, marked stale, only while it is still allowed")
func usageSnapshotRetention() {
    let earlier = paceNow.addingTimeInterval(-600)
    let claude = makeSnapshot(.claude, [sessionWindow(percent: 40)])
    let codex = makeSnapshot(.codex, [sessionWindow(percent: 5)], source: .localReport)
    let order: [UsageProviderID] = [.claude, .codex]

    let kept = UsageSnapshotRetention.merge(
        previous: [claude, codex], previousObservedAt: [.claude: earlier, .codex: earlier],
        fresh: [codex], now: paceNow, enabled: [.claude, .codex], networkConsent: [.claude],
        registryOrder: order)
    #expect(kept.snapshots.map(\.providerID) == [.claude, .codex])
    #expect(kept.staleProviderIDs == [.claude])
    #expect(kept.observedAt[.claude] == earlier)
    #expect(kept.observedAt[.codex] == paceNow)

    let disconnected = UsageSnapshotRetention.merge(
        previous: [claude], previousObservedAt: [.claude: earlier], fresh: [], now: paceNow,
        enabled: [.claude], networkConsent: [], registryOrder: order)
    #expect(disconnected.snapshots.isEmpty)

    let disabled = UsageSnapshotRetention.merge(
        previous: [codex], previousObservedAt: [.codex: earlier], fresh: [], now: paceNow,
        enabled: [], networkConsent: [], registryOrder: order)
    #expect(disabled.snapshots.isEmpty)

    let tooOld = UsageSnapshotRetention.merge(
        previous: [codex],
        previousObservedAt: [.codex: paceNow.addingTimeInterval(-7 * 3_600)], fresh: [],
        now: paceNow, enabled: [.codex], networkConsent: [], registryOrder: order)
    #expect(tooOld.snapshots.isEmpty)
}

@Test("A full usage window stops reporting exhausted once its reset passes")
func paceExhaustedWindowAfterReset() {
    let window = sessionWindow(percent: 100, resetIn: -60)
    let pace = UsagePace.estimate(window: window, observedAt: paceNow, now: paceNow)
    #expect(pace.state == .unknown)
    #expect(pace.unknownReason == .resetPassed)
    #expect(!pace.warning)
}

@Test("In-flight usage results respect a later disconnect or disable")
func usageFreshResultsRespectCurrentConsent() {
    let exact = makeSnapshot(.claude, [sessionWindow(percent: 40)])
    let local = makeSnapshot(.codex, [sessionWindow(percent: 5)], source: .localReport)
    let result = UsageSnapshotRetention.merge(
        previous: [], previousObservedAt: [:], fresh: [exact, local], now: paceNow,
        enabled: [.claude], networkConsent: [], registryOrder: [.claude, .codex])
    #expect(result.snapshots.isEmpty)
    #expect(result.observedAt.isEmpty)
    #expect(result.staleProviderIDs.isEmpty)
}

// MARK: - Claude Code Keychain re-read after Connect

private final class PaceKeychainCounter: Sendable {
    private let storage = Mutex(0)
    var count: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

@Test("A refresh re-reads Claude Code's Keychain at most once per interval and caches it")
func claudeKeychainRefreshIsRateLimited() async throws {
    let store = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let reads = PaceKeychainCounter()
    let reader: @Sendable () -> UsageClaudeKeychainReadResult = {
        reads.increment()
        return .credential(
            paceCredentials(token: "keychain-token", expiresAt: paceNow.addingTimeInterval(3_600)))
    }

    let first = try #require(
        await store.refreshClaudeKeychainCredential(now: paceNow, keychainReader: reader))
    #expect(UsageExternalCredentialEnvelope.parse(first)?.accessToken == "keychain-token")
    #expect(await store.transientExternalCredential(for: .claude) == first)

    let throttled = await store.refreshClaudeKeychainCredential(
        now: paceNow.addingTimeInterval(60), keychainReader: reader)
    #expect(throttled == nil)
    #expect(reads.count == 1)

    let later = await store.refreshClaudeKeychainCredential(
        now: paceNow.addingTimeInterval(UsageCredentialStore.keychainRefreshInterval + 1),
        keychainReader: reader)
    #expect(later != nil)
    #expect(reads.count == 2)
}

@Test("A Keychain denial stops refresh re-reads until the next Connect or Disconnect")
func claudeKeychainDenialStopsRereads() async {
    let store = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let reads = PaceKeychainCounter()
    let denied: @Sendable () -> UsageClaudeKeychainReadResult = {
        reads.increment()
        return .accessDenied
    }

    #expect(
        await store.refreshClaudeKeychainCredential(now: paceNow, keychainReader: denied) == nil)
    let afterInterval = paceNow.addingTimeInterval(UsageCredentialStore.keychainRefreshInterval + 1)
    #expect(
        await store.refreshClaudeKeychainCredential(now: afterInterval, keychainReader: denied)
            == nil)
    #expect(reads.count == 1)

    await store.removeTransientExternalCredential(for: .claude)
    #expect(await store.claimKeychainRefresh(for: .claude, now: afterInterval))
    #expect(await !store.claimKeychainRefresh(for: .codex, now: afterInterval))
}

@Test("An expired Keychain credential is never cached")
func claudeKeychainExpiredCredentialIsIgnored() async {
    let store = UsageCredentialStore(servicePrefix: "test.claude.\(UUID().uuidString)")
    let expired: @Sendable () -> UsageClaudeKeychainReadResult = {
        .credential(paceCredentials(token: "old", expiresAt: paceNow.addingTimeInterval(-1)))
    }
    #expect(
        await store.refreshClaudeKeychainCredential(now: paceNow, keychainReader: expired) == nil)
    #expect(await store.transientExternalCredential(for: .claude) == nil)
}
