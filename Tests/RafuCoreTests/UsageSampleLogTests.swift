import Foundation
import Testing

@testable import RafuCore

// Widget W2: the daily usage log and the day split. Every test passes its
// own `now` (the injected clock); nothing reads the real clock, `~`, or
// the network. The store tests use a temporary folder.

private let logT0 = Date(timeIntervalSince1970: 1_784_800_800)
private let minute: TimeInterval = 60
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

private func sample(
    _ used: Double, at time: Date, resetsAt: Date? = logT0.addingTimeInterval(5 * day),
    provider: String = "claude", window: String = "7d"
) -> UsageSampleRecord {
    UsageSampleRecord(
        providerID: provider, window: window, usedPercent: used, resetsAt: resetsAt,
        observedAt: time)
}

@Suite("Usage sample log")
struct UsageSampleLogTests {
    @Test("One record per window every 15 minutes, each window on its own")
    func cadence() {
        var log = UsageSampleLog()
        let changed1 = log.append(
            [sample(10, at: logT0), sample(3, at: logT0, window: "5h")], now: logT0)
        #expect(changed1)
        let five = logT0.addingTimeInterval(5 * minute)
        let changed2 = log.append([sample(11, at: five)], now: five)
        #expect(!changed2)
        let fifteen = logT0.addingTimeInterval(15 * minute)
        let changed3 = log.append([sample(12, at: fifteen)], now: fifteen)
        #expect(changed3)
        #expect(log.records(providerID: "claude", window: "7d").map(\.usedPercent) == [10, 12])
        #expect(log.records(providerID: "claude", window: "5h").count == 1)
        // The same observation published twice adds nothing.
        let changed4 = log.append([sample(12, at: fifteen)], now: fifteen.addingTimeInterval(hour))
        #expect(!changed4)
    }

    @Test("A new reset time adds a record at once; reset jitter does not")
    func resetChange() {
        var log = UsageSampleLog()
        log.append([sample(90, at: logT0)], now: logT0)
        let jitter = logT0.addingTimeInterval(2 * minute)
        let changed5 = log.append(
            [sample(91, at: jitter, resetsAt: logT0.addingTimeInterval(5 * day + 30))],
            now: jitter)
        #expect(!changed5)
        let reset = logT0.addingTimeInterval(3 * minute)
        let changed6 = log.append(
            [sample(0, at: reset, resetsAt: logT0.addingTimeInterval(12 * day))], now: reset)
        #expect(changed6)
        #expect(log.records.map(\.usedPercent) == [90, 0])
    }

    @Test("Records older than five weeks are pruned and the log is bounded")
    func pruning() {
        var log = UsageSampleLog()
        log.append([sample(5, at: logT0)], now: logT0)
        let later = logT0.addingTimeInterval(35 * day + minute)
        let changed7 = log.append([sample(1, at: later, resetsAt: nil)], now: later)
        #expect(changed7)
        #expect(log.records.count == 1)
        #expect(log.records[0].observedAt == later)

        let many = (0..<(UsageSampleLog.maximumRecords + 50)).map {
            sample(1, at: logT0.addingTimeInterval(Double($0)), window: "w\($0 % 7)")
        }
        let bounded = UsageSampleLog(records: many)
        #expect(bounded.records.count == UsageSampleLog.maximumRecords)
        #expect(bounded.records.first?.observedAt == logT0.addingTimeInterval(50))
    }

    @Test("A clock set back drops the records from the future")
    func clockSetBack() {
        var log = UsageSampleLog()
        let ahead = logT0.addingTimeInterval(2 * day)
        log.append([sample(10, at: logT0)], now: logT0)
        log.append([sample(30, at: ahead)], now: ahead)
        // The clock goes back to one hour after t0.
        let back = logT0.addingTimeInterval(hour)
        let changed8 = log.append([sample(12, at: back)], now: back)
        #expect(changed8)
        #expect(log.records.map(\.usedPercent) == [10, 12])
    }

    @Test("Older, future, and invalid samples are ignored; percents are clamped")
    func invalidSamples() {
        var log = UsageSampleLog()
        log.append([sample(10, at: logT0)], now: logT0)
        let now = logT0.addingTimeInterval(hour)
        let older = sample(9, at: logT0.addingTimeInterval(-hour))
        let future = sample(9, at: now.addingTimeInterval(10 * minute), window: "5h")
        let notFinite = sample(.nan, at: now, window: "x")
        let changed9 = log.append([older, future, notFinite], now: now)
        #expect(!changed9)
        let changed10 = log.append([sample(140, at: now, window: "y")], now: now)
        #expect(changed10)
        #expect(log.records(providerID: "claude", window: "y").first?.usedPercent == 100)
    }

    @Test("A percent that goes down within a window is still recorded")
    func decreasingPercentRecorded() {
        var log = UsageSampleLog()
        log.append([sample(30, at: logT0)], now: logT0)
        let later = logT0.addingTimeInterval(20 * minute)
        let changed11 = log.append([sample(25, at: later)], now: later)
        #expect(changed11)
        #expect(log.records.map(\.usedPercent) == [30, 25])
    }

    @Test("Encoding round-trips; damaged, newer, or oversized data reads as empty")
    func coding() throws {
        var log = UsageSampleLog()
        log.append(
            [sample(10, at: logT0), sample(4, at: logT0, resetsAt: nil, window: "5h")], now: logT0)
        #expect(log.records.count == 2)
        let data = try log.encoded()
        #expect(UsageSampleLog.decode(data) == log)
        #expect(UsageSampleLog.decode(Data("junk".utf8)).records.isEmpty)
        let newer = #"{"formatVersion": 9, "records": []}"#
        #expect(UsageSampleLog.decode(Data(newer.utf8)).records.isEmpty)
        let huge = Data(count: UsageSampleLog.maximumBytes + 1)
        #expect(UsageSampleLog.decode(huge).records.isEmpty)
        // No identity or credential fields: only the five short keys.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""p":"claude""#))
        #expect(!text.contains("identity"))
    }

    @Test("The store writes atomically, reloads, and appends across instances")
    func storeRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-usage-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = UsageSampleLogStore.fileURL(applicationSupport: directory, appName: "Rafu Test")
        #expect(url.path.hasSuffix("Rafu Test/Usage/usage-samples.json"))

        let store = UsageSampleLogStore(fileURL: url)
        #expect(await store.load().records.isEmpty)
        await store.record([sample(10, at: logT0)], now: logT0)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reopened = UsageSampleLogStore(fileURL: url)
        #expect(await reopened.load().records.map(\.usedPercent) == [10])
        let later = logT0.addingTimeInterval(20 * minute)
        let log = await reopened.record([sample(15, at: later)], now: later)
        #expect(log.records.map(\.usedPercent) == [10, 15])
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        #expect(contents == [UsageSampleLogStore.fileName])

        try Data("damaged".utf8).write(to: url)
        #expect(await UsageSampleLogStore(fileURL: url).load().records.isEmpty)
    }
}

@Suite("Usage daily breakdown")
struct UsageDailyBreakdownTests {
    /// A weekly window that resets 7 days after `start`.
    private let start = logT0
    private var reset: Date { start.addingTimeInterval(7 * day) }

    private func make(
        _ records: [UsageSampleRecord], current: Double, at observed: Date,
        resetsAt: Date? = nil, minutes: Int? = 10_080
    ) -> UsageDailyBreakdown? {
        UsageDailyBreakdown.make(
            records: records, providerID: "claude", window: "7d", currentPercent: current,
            observedAt: observed, resetsAt: resetsAt ?? reset, windowMinutes: minutes)
    }

    private func at(_ days: Double) -> Date { start.addingTimeInterval(days * day) }

    private func rounded(_ daily: [Double?]) -> [Double?] {
        daily.map { $0.map { ($0 * 1_000).rounded() / 1_000 } }
    }

    @Test("Day ends give each past day, today so far, and nil ahead")
    func steadyDays() throws {
        let records = [10.0, 18, 25].enumerated().map {
            sample($1, at: at(Double($0 + 1)), resetsAt: reset)
        }
        let result = try #require(make(records, current: 30, at: at(3.5)))
        #expect(result.windowStart == start)
        #expect(rounded(result.daily) == [10, 8, 7, 5, nil, nil, nil])
    }

    @Test("Records of the window before a reset do not count")
    func resetMidDay() throws {
        let oldReset = start
        let old = [
            sample(60, at: at(-0.5), resetsAt: oldReset),
            sample(70, at: at(-0.1), resetsAt: oldReset),
        ]
        let fresh = [sample(4, at: at(0.5), resetsAt: reset)]
        let result = try #require(make(old + fresh, current: 9, at: at(1.25)))
        // Level at the day-1 boundary: between 4 at 0.5 d and 9 at 1.25 d.
        let first = try #require(result.daily[0])
        #expect(abs(first - (4 + 5 * (0.5 / 0.75))) < 0.001)
        #expect(abs((result.daily[1] ?? 0) + first - 9) < 0.001)
        #expect(result.daily[2...].allSatisfy { $0 == nil })
    }

    @Test("A gap is spread over the days it covers")
    func gap() throws {
        let records = [
            sample(10, at: at(0.5), resetsAt: reset),
            sample(40, at: at(3.5), resetsAt: reset),
        ]
        let result = try #require(make(records, current: 45, at: at(3.75)))
        #expect(rounded(result.daily) == [15, 10, 10, 10, nil, nil, nil])
    }

    @Test("No samples yet: the current percent spreads from the window start")
    func noSamples() throws {
        let result = try #require(make([], current: 20, at: at(2)))
        #expect(rounded(result.daily) == [10, 10, 0, nil, nil, nil, nil])
    }

    @Test("A percent that goes down caps the days before it")
    func decreasingPercent() throws {
        let records = [
            sample(20, at: at(1), resetsAt: reset),
            sample(30, at: at(2), resetsAt: reset),
        ]
        let result = try #require(make(records, current: 25, at: at(2.5)))
        #expect(rounded(result.daily) == [20, 5, 0, nil, nil, nil, nil])
        #expect(result.daily.compactMap { $0 }.allSatisfy { $0 >= 0 })
    }

    @Test("Records after the observation (a clock that ran ahead) are ignored")
    func clockAhead() throws {
        let records = [
            sample(10, at: at(1), resetsAt: reset),
            sample(60, at: at(5), resetsAt: reset),
        ]
        let result = try #require(make(records, current: 15, at: at(2)))
        #expect(rounded(result.daily) == [10, 5, 0, nil, nil, nil, nil])
    }

    @Test("A provider turned off for days and back on")
    func providerOff() throws {
        // Samples on day 1, nothing on days 2 to 4, back on day 5.
        let records = [
            sample(5, at: at(0.9), resetsAt: reset),
            sample(8, at: at(1.0), resetsAt: reset),
        ]
        let result = try #require(make(records, current: 32, at: at(5)))
        #expect(rounded(result.daily) == [8, 6, 6, 6, 6, 0, nil])
        let total = result.daily.compactMap { $0 }.reduce(0, +)
        #expect(abs(total - 32) < 0.001)
    }

    @Test("Other providers and windows are ignored")
    func otherSeries() throws {
        let records = [
            sample(50, at: at(1), resetsAt: reset, provider: "codex"),
            sample(50, at: at(1), resetsAt: reset, window: "5h"),
            sample(4, at: at(1), resetsAt: reset),
        ]
        let result = try #require(make(records, current: 6, at: at(1.5)))
        #expect(rounded(result.daily) == [4, 2, nil, nil, nil, nil, nil])
    }

    @Test("Not weekly, no reset, or an observation outside the window gives nil")
    func unsupported() {
        #expect(make([], current: 10, at: at(1), minutes: 300) == nil)
        #expect(
            UsageDailyBreakdown.make(
                records: [], providerID: "claude", window: "7d", currentPercent: 10,
                observedAt: at(1), resetsAt: nil, windowMinutes: 10_080) == nil)
        #expect(make([], current: 10, at: at(-1)) == nil)
        #expect(make([], current: 10, at: at(7)) == nil)
        #expect(make([], current: .nan, at: at(1)) == nil)
    }

    private func makeToday(
        _ records: [UsageSampleRecord], current: Double, at observed: Date, todayStart: Date?
    ) -> UsageDailyBreakdown? {
        UsageDailyBreakdown.make(
            records: records, providerID: "claude", window: "7d", currentPercent: current,
            observedAt: observed, resetsAt: reset, windowMinutes: 10_080, todayStart: todayStart)
    }

    @Test("Without a today start there is no today value")
    func noTodayStart() throws {
        let result = try #require(make([], current: 10, at: at(1.5)))
        #expect(result.todayStart == nil)
        #expect(result.todayUsed == nil)
    }

    @Test("Today counts from the caller's midnight, not from the 24-hour slice")
    func todaySinceMidnight() throws {
        // The window starts at 13:00 UTC, like the Claude limit in
        // Asia/Kolkata (UTC+5:30). All 6% were used after the local
        // midnight (18:30 UTC) but before the next slice boundary
        // (13:00 UTC), so the slice for the current day holds 0.
        let formatter = ISO8601DateFormatter()
        let windowStart = try #require(formatter.date(from: "2026-11-16T13:00:00Z"))
        let windowReset = windowStart.addingTimeInterval(7 * day)
        let midnight = try #require(formatter.date(from: "2026-11-16T18:30:00Z"))
        let records = [
            sample(0, at: midnight, resetsAt: windowReset),
            sample(
                1, at: try #require(formatter.date(from: "2026-11-17T03:00:00Z")),
                resetsAt: windowReset),
            sample(
                6, at: try #require(formatter.date(from: "2026-11-17T12:54:00Z")),
                resetsAt: windowReset),
        ]
        let observed = try #require(formatter.date(from: "2026-11-17T13:10:00Z"))
        let result = try #require(
            UsageDailyBreakdown.make(
                records: records, providerID: "claude", window: "7d", currentPercent: 6,
                observedAt: observed, resetsAt: windowReset, windowMinutes: 10_080,
                todayStart: midnight))
        #expect(rounded(result.daily) == [6, 0, nil, nil, nil, nil, nil])
        #expect(result.todayStart == midnight)
        let today = try #require(result.todayUsed)
        #expect(abs(today - 6) < 0.001)
    }

    @Test("A today start before the window start counts the whole window so far")
    func todayStartBeforeWindow() throws {
        let records = [sample(10, at: at(0.5), resetsAt: reset)]
        let result = try #require(
            makeToday(records, current: 30, at: at(2.5), todayStart: at(-0.3)))
        let today = try #require(result.todayUsed)
        #expect(abs(today - 30) < 0.001)
        #expect(result.todayStart == at(-0.3))
        let atStart = try #require(makeToday(records, current: 30, at: at(2.5), todayStart: start))
        #expect(abs((atStart.todayUsed ?? 0) - 30) < 0.001)
    }

    @Test("The level at midnight is interpolated between the samples around it")
    func todayInterpolatesAcrossMidnight() throws {
        // 10% at day 1.0 and 30% at day 2.0; midnight at day 1.25 is 15%.
        let records = [
            sample(10, at: at(1), resetsAt: reset), sample(30, at: at(2), resetsAt: reset),
        ]
        let result = try #require(
            makeToday(records, current: 40, at: at(2.5), todayStart: at(1.25)))
        let today = try #require(result.todayUsed)
        #expect(abs(today - 25) < 0.001)
    }

    @Test("A midnight after the last observation, or a lower level, never gives a negative")
    func todayNeverNegative() throws {
        let records = [sample(20, at: at(1), resetsAt: reset)]
        let ahead = try #require(makeToday(records, current: 20, at: at(1.5), todayStart: at(3)))
        #expect(ahead.todayUsed == 0)
        let corrected = try #require(
            makeToday(records, current: 15, at: at(1.5), todayStart: at(1.2)))
        #expect((corrected.todayUsed ?? -1) >= 0)
    }

    @Test("The last day of the window holds today")
    func lastDay() throws {
        let result = try #require(make([], current: 70, at: at(6.5)))
        #expect(result.daily.count == 7)
        #expect(result.daily.allSatisfy { $0 != nil })
        let total = result.daily.compactMap { $0 }.reduce(0, +)
        #expect(abs(total - 70) < 0.001)
    }
}
