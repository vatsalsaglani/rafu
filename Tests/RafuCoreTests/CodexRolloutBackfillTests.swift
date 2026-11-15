import Foundation
import Testing

@testable import RafuCore

// The Codex rollout backfill. Fixture rollouts only: every line is built here
// with made-up numbers (no real user data). Every test passes its own clock.
// Scan tests use a temporary folder and set file modification dates
// explicitly.

private let now = Date(timeIntervalSince1970: 1_784_800_800)
private let resetsAt = now.addingTimeInterval(3 * 86_400)
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

private func iso(_ date: Date, fractional: Bool = true) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: fractional))
}

private func window(_ percent: Double, minutes: Int, resets: Date? = resetsAt) -> String {
    var fields = "\"used_percent\":\(percent),\"window_minutes\":\(minutes)"
    if let resets { fields += ",\"resets_at\":\(Int(resets.timeIntervalSince1970))" }
    return "{\(fields)}"
}

/// One `token_count` rollout line.
private func tokenCount(
    at time: Date, primary: String? = nil, secondary: String? = nil,
    limitID: String? = "codex", type: String = "token_count", fractional: Bool = true,
    padding: Int = 0
) -> String {
    var limits = [
        "\"primary\":\(primary ?? "null")", "\"secondary\":\(secondary ?? "null")",
    ]
    if let limitID { limits.append("\"limit_id\":\"\(limitID)\"") }
    let pad = padding > 0 ? ",\"filler\":\"\(String(repeating: "x", count: padding))\"" : ""
    return
        "{\"timestamp\":\"\(iso(time, fractional: fractional))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"rate_limits\":{\(limits.joined(separator: ","))}\(pad)}}"
}

private func weekly(_ time: Date, _ percent: Double, resets: Date = resetsAt) -> String {
    tokenCount(at: time, primary: window(percent, minutes: 10_080, resets: resets))
}

private func parse(_ line: String) -> CodexRolloutBackfill.Sample? {
    CodexRolloutBackfill.parseLine(Data(line.utf8))
}

/// A fresh sessions folder with dated subfolders.
private final class Sessions {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(
            path: "rafu-backfill-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(
        _ lines: [String], name: String, folder: String = "2026/07/23", modified: Date
    ) throws -> URL {
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }
}

@Suite("Codex rollout backfill parsing")
struct CodexRolloutBackfillParsingTests {
    @Test("A weekly primary window is read: percent, reset, time")
    func weeklyPrimary() throws {
        let result = try #require(parse(weekly(now, 34)))
        #expect(result.usedPercent == 34)
        #expect(result.resetsAt == Date(timeIntervalSince1970: resetsAt.timeIntervalSince1970))
        #expect(abs(result.observedAt.timeIntervalSince(now)) < 0.001)
    }

    @Test("The weekly window is found by its length, not its slot")
    func weeklySecondary() throws {
        let line = tokenCount(
            at: now, primary: window(60, minutes: 300),
            secondary: window(12, minutes: 10_080))
        let result = try #require(parse(line))
        #expect(result.usedPercent == 12)
    }

    @Test("A 5-hour window alone gives no sample")
    func fiveHourOnly() {
        #expect(parse(tokenCount(at: now, primary: window(60, minutes: 300))) == nil)
    }

    @Test("Other events, other limits, and bad numbers are skipped")
    func rejects() {
        let good = window(5, minutes: 10_080)
        #expect(parse(tokenCount(at: now, primary: good, type: "agent_message")) == nil)
        #expect(parse(tokenCount(at: now, primary: good, limitID: "codex_other")) == nil)
        #expect(parse(tokenCount(at: now, primary: window(101, minutes: 10_080))) == nil)
        #expect(parse(tokenCount(at: now, primary: window(-1, minutes: 10_080))) == nil)
        #expect(parse(tokenCount(at: now, primary: window(5, minutes: 10_080, resets: nil))) == nil)
        #expect(parse("") == nil)
        #expect(parse("not json \"rate_limits\" \"token_count\"") == nil)
        #expect(parse("{\"payload\":{\"type\":\"token_count\",\"rate_limits\":7}}") == nil)
    }

    @Test("A line without limit_id (older rollouts) and whole-second times are accepted")
    func oldShape() throws {
        let line = tokenCount(
            at: now, primary: window(8, minutes: 10_080), limitID: nil, fractional: false)
        let result = try #require(parse(line))
        #expect(result.observedAt == now)
    }

    @Test("The parsed sample holds numbers and dates only, no text")
    func noText() throws {
        // The line carries text fields; none may reach the sample.
        let line = tokenCount(
            at: now, primary: window(8, minutes: 10_080), padding: 200)
        let result = try #require(parse(line))
        for child in Mirror(reflecting: result).children {
            #expect(!(child.value is String))
            #expect(child.value is Date || child.value is Double)
        }
        let record = try #require(CodexRolloutBackfill.records(from: [result]).first)
        #expect(record.providerID == "codex")
        #expect(record.window == "7d")
        #expect(record.isBackfill)
    }
}

@Suite("Codex rollout backfill scan")
struct CodexRolloutBackfillScanTests {
    @Test("Samples are read from recent rollouts, one per 15-minute bucket, oldest first")
    func scanBuckets() throws {
        let sessions = Sessions()
        let base = now.addingTimeInterval(-2 * day)
        try sessions.write(
            [
                weekly(base, 10), weekly(base.addingTimeInterval(60), 11),
                weekly(base.addingTimeInterval(20 * 60), 12),
                tokenCount(at: base.addingTimeInterval(30 * 60), primary: window(1, minutes: 300)),
                "{\"type\":\"response_item\",\"payload\":{\"text\":\"hello\"}}", "garbage {",
            ], name: "rollout-a.jsonl", modified: now.addingTimeInterval(-hour))
        let result = try CodexRolloutBackfill.scan(sessionsDirectory: sessions.root, now: now)
        #expect(result.map(\.usedPercent) == [11, 12])
        #expect(result.map(\.observedAt) == result.map(\.observedAt).sorted())
    }

    @Test("Old files, old samples, future samples, and other names are ignored")
    func filters() throws {
        let sessions = Sessions()
        try sessions.write(
            [weekly(now.addingTimeInterval(-hour), 50)], name: "rollout-old.jsonl",
            modified: now.addingTimeInterval(-8 * day))
        try sessions.write(
            [
                weekly(now.addingTimeInterval(-8 * day), 5),
                weekly(now.addingTimeInterval(hour), 6),
                weekly(now.addingTimeInterval(-2 * hour), 7),
            ],
            name: "rollout-new.jsonl", modified: now.addingTimeInterval(-hour))
        try sessions.write(
            [weekly(now.addingTimeInterval(-3 * hour), 9)], name: "notes.jsonl",
            modified: now.addingTimeInterval(-hour))
        try sessions.write(
            [weekly(now.addingTimeInterval(-4 * hour), 9)], name: "rollout-x.txt",
            modified: now.addingTimeInterval(-hour))
        let result = try CodexRolloutBackfill.scan(sessionsDirectory: sessions.root, now: now)
        #expect(result.map(\.usedPercent) == [7])
    }

    @Test("Only the newest files count, up to the file cap")
    func fileCap() throws {
        let sessions = Sessions()
        for index in 0..<4 {
            // File 0 is the oldest, file 3 the newest.
            try sessions.write(
                [weekly(now.addingTimeInterval(-Double(10 - index) * hour), Double(index))],
                name: "rollout-\(index).jsonl", folder: "2026/07/2\(index)",
                modified: now.addingTimeInterval(-Double(10 - index) * hour))
        }
        var limits = CodexRolloutBackfill.Limits()
        limits.maxFiles = 2
        let result = try CodexRolloutBackfill.scan(
            sessionsDirectory: sessions.root, now: now, limits: limits)
        #expect(result.map(\.usedPercent) == [2, 3])
    }

    @Test("Files touched together are ranked by the start stamp in their names")
    func sameModifiedDay() throws {
        let sessions = Sessions()
        let touched = now.addingTimeInterval(-hour)
        let names = [
            "rollout-2026-07-20T10-00-00-aaa.jsonl", "rollout-2026-07-22T10-00-00-bbb.jsonl",
            "rollout-2026-07-21T10-00-00-ccc.jsonl",
        ]
        for (index, name) in names.enumerated() {
            try sessions.write(
                [weekly(now.addingTimeInterval(-Double(5 - index) * hour), Double(index))],
                name: name, modified: touched)
        }
        var limits = CodexRolloutBackfill.Limits()
        limits.maxFiles = 2
        let result = try CodexRolloutBackfill.scan(
            sessionsDirectory: sessions.root, now: now, limits: limits)
        // The two newest names are index 1 (07-22) and index 2 (07-21).
        #expect(result.map(\.usedPercent) == [1, 2])
    }

    @Test("A line over the line cap is skipped; the next lines still count")
    func oversizeLine() throws {
        let sessions = Sessions()
        let big = tokenCount(
            at: now.addingTimeInterval(-3 * hour),
            primary: window(99, minutes: 10_080), padding: 4_000)
        try sessions.write(
            [big, weekly(now.addingTimeInterval(-2 * hour), 20)], name: "rollout-a.jsonl",
            modified: now.addingTimeInterval(-hour))
        var limits = CodexRolloutBackfill.Limits()
        limits.maxLineBytes = 1_000
        limits.chunkBytes = 300  // the long line spans many chunks
        let result = try CodexRolloutBackfill.scan(
            sessionsDirectory: sessions.root, now: now, limits: limits)
        #expect(result.map(\.usedPercent) == [20])
    }

    @Test("Only the tail of a large file is read, and the cut line is dropped")
    func byteCap() throws {
        let sessions = Sessions()
        let lines = (0..<40).map {
            weekly(now.addingTimeInterval(-Double(40 - $0) * hour / 2), Double($0))
        }
        try sessions.write(lines, name: "rollout-a.jsonl", modified: now.addingTimeInterval(-hour))
        var limits = CodexRolloutBackfill.Limits()
        limits.maxBytesPerFile = (lines[0].utf8.count + 1) * 5 + 20  // about 5 lines
        limits.chunkBytes = 128
        let result = try CodexRolloutBackfill.scan(
            sessionsDirectory: sessions.root, now: now, limits: limits)
        #expect(!result.isEmpty && result.count <= 5)
        #expect(result.last?.usedPercent == 39)
        #expect(result.allSatisfy { $0.usedPercent >= 35 })
    }

    @Test("The total byte budget stops the scan")
    func totalCap() throws {
        let sessions = Sessions()
        for index in 0..<3 {
            try sessions.write(
                [weekly(now.addingTimeInterval(-Double(10 - index) * hour), Double(index))],
                name: "rollout-\(index).jsonl", folder: "2026/07/2\(index)",
                modified: now.addingTimeInterval(-Double(10 - index) * hour))
        }
        var limits = CodexRolloutBackfill.Limits()
        limits.maxTotalBytes = 1  // the first file reads 1 byte, then the budget is gone
        let result = try CodexRolloutBackfill.scan(
            sessionsDirectory: sessions.root, now: now, limits: limits)
        #expect(result.isEmpty)
    }

    @Test("A missing folder gives no samples")
    func missingFolder() throws {
        let missing = FileManager.default.temporaryDirectory.appending(
            path: "rafu-backfill-missing-\(UUID().uuidString)")
        #expect(try CodexRolloutBackfill.scan(sessionsDirectory: missing, now: now).isEmpty)
    }

    @Test("A cancelled scan throws and returns nothing")
    func cancellation() async throws {
        let sessions = Sessions()
        try sessions.write(
            [weekly(now.addingTimeInterval(-hour), 5)], name: "rollout-a.jsonl",
            modified: now.addingTimeInterval(-hour))
        let root = sessions.root
        let task = Task {
            // Wait until the cancel lands, then scan: the first check throws.
            while !Task.isCancelled { await Task.yield() }
            return try CodexRolloutBackfill.scan(sessionsDirectory: root, now: now)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("The daily schedule: first run, a day later, and a clock set back")
    func schedule() {
        #expect(CodexRolloutBackfill.isDue(lastRun: nil, now: now))
        #expect(!CodexRolloutBackfill.isDue(lastRun: now.addingTimeInterval(-23 * hour), now: now))
        #expect(CodexRolloutBackfill.isDue(lastRun: now.addingTimeInterval(-day), now: now))
        #expect(CodexRolloutBackfill.isDue(lastRun: now.addingTimeInterval(hour), now: now))
    }

    @Test("run() scans and merges into the store, and a second run changes nothing")
    func endToEnd() async throws {
        let sessions = Sessions()
        try sessions.write(
            [
                weekly(now.addingTimeInterval(-3 * hour), 10),
                weekly(now.addingTimeInterval(-hour), 12),
            ],
            name: "rollout-a.jsonl", modified: now.addingTimeInterval(-hour))
        let file = sessions.root.appending(path: "log/usage-samples.json")
        let store = UsageSampleLogStore(fileURL: file)
        let first = try await CodexRolloutBackfill.run(
            store: store, sessionsDirectory: sessions.root, now: now)
        #expect(first)
        let second = try await CodexRolloutBackfill.run(
            store: store, sessionsDirectory: sessions.root, now: now)
        #expect(!second)
        let reloaded = await UsageSampleLogStore(fileURL: file).load()
        #expect(reloaded.records.count == 2)
        #expect(reloaded.records.allSatisfy { $0.isBackfill })
        #expect(reloaded.records.map(\.usedPercent) == [10, 12])
    }
}

private func backfillRecord(
    _ used: Double, at time: Date, resets: Date? = resetsAt, window: String = "7d"
) -> UsageSampleRecord {
    UsageSampleRecord(
        providerID: "codex", window: window, usedPercent: used, resetsAt: resets,
        observedAt: time, isBackfill: true)
}

private func live(
    _ used: Double, at time: Date, resets: Date? = resetsAt, window: String = "7d"
) -> UsageSampleRecord {
    UsageSampleRecord(
        providerID: "codex", window: window, usedPercent: used, resetsAt: resets,
        observedAt: time)
}

@Suite("Usage sample log backfill merge")
struct UsageSampleLogBackfillMergeTests {
    @Test("Backfill fills earlier days and is marked as backfill")
    func fillsEarlier() {
        var log = UsageSampleLog(records: [live(30, at: now)])
        let changed = log.mergeBackfill(
            [
                backfillRecord(10, at: now.addingTimeInterval(-2 * day)),
                backfillRecord(20, at: now.addingTimeInterval(-day)),
            ], now: now)
        #expect(changed)
        #expect(log.records.map(\.usedPercent) == [10, 20, 30])
        #expect(log.records.map(\.isBackfill) == [true, true, false])
    }

    @Test("A live record is never replaced; a backfill sample near it is dropped")
    func liveWins() {
        let liveRecord = live(30, at: now)
        var log = UsageSampleLog(records: [liveRecord])
        let changed = log.mergeBackfill(
            [
                backfillRecord(99, at: now),
                backfillRecord(98, at: now.addingTimeInterval(-5 * 60)),
                backfillRecord(97, at: now.addingTimeInterval(-14 * 60)),
            ], now: now)
        #expect(!changed)
        #expect(log.records == [liveRecord])
    }

    @Test("The cadence rule thins backfill; the same samples merge once")
    func dedupe() {
        var log = UsageSampleLog()
        let samples = (0..<10).map {
            backfillRecord(Double($0), at: now.addingTimeInterval(-Double(10 - $0) * 5 * 60))
        }
        let changed = log.mergeBackfill(samples, now: now)
        #expect(changed)
        // Every 5 minutes in, one in three is kept (15-minute cadence).
        #expect(log.records.count == 4)
        let again = log.mergeBackfill(samples, now: now)
        #expect(!again)
        let exact = log.mergeBackfill([backfillRecord(1, at: log.records[0].observedAt)], now: now)
        #expect(!exact)
    }

    @Test("A reset boundary keeps samples on both sides even when close")
    func resetBoundary() {
        var log = UsageSampleLog()
        let before = now.addingTimeInterval(-10 * 60)
        let after = now.addingTimeInterval(-9 * 60)
        let changed = log.mergeBackfill(
            [
                backfillRecord(95, at: before, resets: now.addingTimeInterval(-9 * 60)),
                backfillRecord(1, at: after, resets: now.addingTimeInterval(7 * day)),
            ],
            now: now)
        #expect(changed)
        #expect(log.records.map(\.usedPercent) == [95, 1])
        // Reset jitter is the same window, so it is a duplicate.
        var other = UsageSampleLog(records: [live(5, at: before)])
        let jitter = other.mergeBackfill(
            [backfillRecord(6, at: after, resets: resetsAt.addingTimeInterval(30))], now: now)
        #expect(!jitter)
    }

    @Test("Other windows and providers do not block each other")
    func windows() {
        var log = UsageSampleLog(records: [live(30, at: now)])
        let changed = log.mergeBackfill(
            [backfillRecord(5, at: now, window: "5h")], now: now)
        #expect(changed)
        #expect(log.records.count == 2)
    }

    @Test("Too-old, future, and non-finite samples are ignored; a percent is clamped")
    func bounds() {
        var log = UsageSampleLog()
        let changed = log.mergeBackfill(
            [
                backfillRecord(5, at: now.addingTimeInterval(-40 * day)),
                backfillRecord(6, at: now.addingTimeInterval(hour)),
                backfillRecord(.nan, at: now.addingTimeInterval(-hour)),
                backfillRecord(140, at: now.addingTimeInterval(-2 * hour)),
            ], now: now)
        #expect(changed)
        #expect(log.records.map(\.usedPercent) == [100])
    }

    @Test("One merge accepts a bounded number of samples")
    func sampleCap() {
        var log = UsageSampleLog()
        let samples = (0..<(UsageSampleLog.maximumBackfillSamples + 200)).map {
            backfillRecord(1, at: now.addingTimeInterval(-Double($0 + 1) * 20 * 60))
        }
        log.mergeBackfill(samples, now: now)
        #expect(log.records.count <= UsageSampleLog.maximumBackfillSamples)
    }

    @Test("A live append after a merge still follows the live rules")
    func liveAfterMerge() {
        var log = UsageSampleLog()
        log.mergeBackfill([backfillRecord(10, at: now.addingTimeInterval(-hour))], now: now)
        let appended = log.append([live(11, at: now)], now: now)
        #expect(appended)
        #expect(log.records.map(\.isBackfill) == [true, false])
    }

    @Test("The backfill mark is stored only when set, and an older log reads as live")
    func coding() throws {
        let log = UsageSampleLog(records: [
            live(1, at: now), backfillRecord(2, at: now.addingTimeInterval(-hour)),
        ])
        let data = try log.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"b\":true").count == 2)
        let decoded = UsageSampleLog.decode(data)
        #expect(decoded.records.map(\.isBackfill) == [true, false])
        let legacy = Data(
            "{\"formatVersion\":1,\"records\":[{\"p\":\"codex\",\"w\":\"7d\",\"u\":3,\"o\":\(Int(now.timeIntervalSince1970))}]}"
                .utf8)
        #expect(UsageSampleLog.decode(legacy).records.map(\.isBackfill) == [false])
    }
}

@Suite("Backfill and the estimated flag")
struct BackfillEstimatedTests {
    private let windowStart = resetsAt.addingTimeInterval(-7 * day)

    private func breakdown(_ records: [UsageSampleRecord], current: Double, at observed: Date)
        throws -> UsageDailyBreakdown
    {
        try #require(
            UsageDailyBreakdown.make(
                records: records, providerID: "codex", window: "7d", currentPercent: current,
                observedAt: observed, resetsAt: resetsAt, windowMinutes: 10_080))
    }

    @Test("Sparse backfill that spans a day boundary is an estimate; dense is not")
    func sparseVersusDense() throws {
        let observed = windowStart.addingTimeInterval(2.5 * day)
        let sparse = [
            backfillRecord(5, at: windowStart.addingTimeInterval(0.1 * day)),
            backfillRecord(20, at: windowStart.addingTimeInterval(1.6 * day)),
        ]
        #expect(try breakdown(sparse, current: 25, at: observed).estimated)

        let dense = (0..<240).map {
            backfillRecord(
                Double($0) / 10, at: windowStart.addingTimeInterval(Double($0 + 1) * 15 * 60 * 1))
        }
        let result = try breakdown(
            dense, current: 24, at: windowStart.addingTimeInterval(240 * 900 + 60))
        #expect(!result.estimated)
    }

    @Test("Backfilled days are used in the split and add up to the current percent")
    func split() throws {
        let records = [
            backfillRecord(10, at: windowStart.addingTimeInterval(0.9 * day)),
            backfillRecord(10, at: windowStart.addingTimeInterval(1.0 * day + 60)),
            backfillRecord(30, at: windowStart.addingTimeInterval(1.9 * day)),
        ]
        let result = try breakdown(
            records, current: 30, at: windowStart.addingTimeInterval(2.1 * day))
        let values = result.daily.compactMap { $0 }
        #expect(values.count == 3)
        #expect(abs(values.reduce(0, +) - 30) < 0.001)
        #expect(values[1] > values[0])
    }
}
