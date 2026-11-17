import Foundation

/// One observation of one provider window's used percent, for the daily
/// usage log. Only what the widget snapshot already has: no account
/// identity, no tokens, no credentials, no transcript text.
///
/// The coding keys are short because the log keeps up to five weeks of
/// records and is rewritten atomically on each append.
public struct UsageSampleRecord: Codable, Equatable, Sendable {
    /// `UsageProviderID.rawValue`, for example `"claude"`.
    public var providerID: String
    /// The window label, for example `"7d"` or `"5h"`.
    public var window: String
    /// Used percent, `0...100`.
    public var usedPercent: Double
    public var resetsAt: Date?
    public var observedAt: Date
    /// `true` for a record rebuilt from a local rollout after the fact
    /// (`UsageSampleLog.mergeBackfill`), `false` for a live observation.
    /// Stored only when `true`, so live records keep their short form and an
    /// older log reads as all live.
    public var isBackfill: Bool

    public init(
        providerID: String, window: String, usedPercent: Double, resetsAt: Date?, observedAt: Date,
        isBackfill: Bool = false
    ) {
        self.providerID = providerID
        self.window = window
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.isBackfill = isBackfill
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "p"
        case window = "w"
        case usedPercent = "u"
        case resetsAt = "r"
        case observedAt = "o"
        case isBackfill = "b"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        window = try container.decode(String.self, forKey: .window)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        isBackfill = try container.decodeIfPresent(Bool.self, forKey: .isBackfill) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(window, forKey: .window)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try container.encode(observedAt, forKey: .observedAt)
        if isBackfill { try container.encode(true, forKey: .isBackfill) }
    }
}

/// The daily usage log: a bounded, time-ordered list of
/// `UsageSampleRecord`s. Pure value type; `UsageSampleLogStore` owns the
/// file.
///
/// Rules:
/// - At most one record for each provider window every `minimumInterval`,
///   plus one record each time the window's `resetsAt` changes by more
///   than `resetTolerance` (a reset, or a new window).
/// - A record older than the newest record of its window is ignored.
/// - Records later than `now` come from a clock that ran ahead and was
///   set back; they are dropped, so the log stays in time order.
/// - A backfill merge (`mergeBackfill`) adds samples from local rollouts
///   without replacing any record that is already there.
/// - Records older than `retention` (five weeks) are pruned, and the log
///   never holds more than `maximumRecords` or encodes to more than
///   `maximumBytes`.
public struct UsageSampleLog: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let minimumInterval: TimeInterval = 15 * 60
    public static let retention: TimeInterval = 35 * 86_400
    /// A `resetsAt` that moves by this much or less is the same window
    /// (providers report the reset with some jitter).
    public static let resetTolerance: TimeInterval = 10 * 60
    /// A record this far after `now` is from a clock that ran ahead.
    public static let futureTolerance: TimeInterval = 60
    public static let maximumRecords = 20_000
    public static let maximumBytes = 2 << 20

    public var formatVersion: Int
    /// Sorted by `observedAt`, oldest first.
    public private(set) var records: [UsageSampleRecord]

    public init(records: [UsageSampleRecord] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.records = records.sorted { $0.observedAt < $1.observedAt }
        if self.records.count > Self.maximumRecords {
            self.records.removeFirst(self.records.count - Self.maximumRecords)
        }
    }

    /// `true` when `lhs` and `rhs` name different windows of one limit.
    public static func resetChanged(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): false
        case (let lhs?, let rhs?): abs(lhs.timeIntervalSince(rhs)) > resetTolerance
        default: true
        }
    }

    /// The records of one provider window, oldest first.
    public func records(providerID: String, window: String) -> [UsageSampleRecord] {
        records.filter { $0.providerID == providerID && $0.window == window }
    }

    /// Appends the samples that pass the cadence rules, then prunes.
    /// Returns `true` when the log changed and must be written.
    @discardableResult
    public mutating func append(_ samples: [UsageSampleRecord], now: Date) -> Bool {
        var changed = dropFuture(now: now)
        for sample in samples {
            guard sample.usedPercent.isFinite,
                sample.observedAt.timeIntervalSince(now) <= Self.futureTolerance
            else { continue }
            var clean = sample
            clean.usedPercent = min(max(sample.usedPercent, 0), 100)
            let last = records.last {
                $0.providerID == clean.providerID && $0.window == clean.window
            }
            if let last {
                guard clean.observedAt > last.observedAt else { continue }
                let due =
                    clean.observedAt.timeIntervalSince(last.observedAt) >= Self.minimumInterval
                guard due || Self.resetChanged(last.resetsAt, clean.resetsAt) else { continue }
            }
            insert(clean)
            changed = true
        }
        return prune(now: now) || changed
    }

    /// Most backfill samples one merge accepts.
    public static let maximumBackfillSamples = 1_000

    /// Merges samples rebuilt from local rollouts (`isBackfill` is set on
    /// each). Live records are never changed or replaced: a sample is added
    /// only when no record of the same window lies within `minimumInterval`
    /// of it, unless both name a known `resetsAt` and the two differ by more
    /// than `resetTolerance` (a reset boundary). The same rule dedupes
    /// backfill against backfill, so a second merge of the same samples adds
    /// nothing. A sample at or before `now - retention`, or later than `now`
    /// plus `futureTolerance`, or with a non-finite percent, is ignored.
    /// Returns `true` when the log changed and must be written.
    @discardableResult
    public mutating func mergeBackfill(_ samples: [UsageSampleRecord], now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let limit = now.addingTimeInterval(Self.futureTolerance)
        let accepted = samples.prefix(Self.maximumBackfillSamples).filter {
            $0.usedPercent.isFinite && $0.observedAt > cutoff && $0.observedAt <= limit
        }.sorted { $0.observedAt < $1.observedAt }

        // Per window: the observation times and resets already in the log,
        // sorted, so each sample is checked against its two neighbours.
        struct Key: Hashable {
            var providerID: String
            var window: String
        }
        var existing: [Key: [(at: Date, resetsAt: Date?)]] = [:]
        for record in records {
            existing[Key(providerID: record.providerID, window: record.window), default: []]
                .append((record.observedAt, record.resetsAt))
        }

        var added: [UsageSampleRecord] = []
        for sample in accepted {
            var clean = sample
            clean.usedPercent = min(max(sample.usedPercent, 0), 100)
            clean.isBackfill = true
            let key = Key(providerID: clean.providerID, window: clean.window)
            let observed = clean.observedAt
            let resets = clean.resetsAt
            // Check the two neighbours inside a block, so the borrowed
            // array is released before it is mutated (no copy).
            let (index, blocked): (Int, Bool) = {
                let neighbours = existing[key] ?? []
                // First index at or after the sample.
                var low = 0
                var high = neighbours.count
                while low < high {
                    let middle = (low + high) / 2
                    if neighbours[middle].at < observed { low = middle + 1 } else { high = middle }
                }
                func conflicts(_ other: (at: Date, resetsAt: Date?)) -> Bool {
                    let distance = abs(other.at.timeIntervalSince(observed))
                    if distance == 0 { return true }
                    guard distance < Self.minimumInterval else { return false }
                    if let lhs = other.resetsAt, let rhs = resets {
                        return !Self.resetChanged(lhs, rhs)
                    }
                    return true
                }
                let before = low > 0 && conflicts(neighbours[low - 1])
                let after = low < neighbours.count && conflicts(neighbours[low])
                return (low, before || after)
            }()
            if blocked { continue }
            existing[key, default: []].insert((observed, resets), at: index)
            added.append(clean)
        }
        if !added.isEmpty {
            records.append(contentsOf: added)
            records.sort { $0.observedAt < $1.observedAt }
        }
        return prune(now: now) || !added.isEmpty
    }

    /// Removes records older than `retention` and the oldest records past
    /// `maximumRecords`. Returns `true` when a record was removed.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let count = records.count
        let cutoff = now.addingTimeInterval(-Self.retention)
        records.removeAll { $0.observedAt < cutoff }
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
        return records.count != count
    }

    /// Drops records later than `now`: the clock was set back.
    private mutating func dropFuture(now: Date) -> Bool {
        let count = records.count
        let limit = now.addingTimeInterval(Self.futureTolerance)
        records.removeAll { $0.observedAt > limit }
        return records.count != count
    }

    private mutating func insert(_ record: UsageSampleRecord) {
        if let last = records.last, last.observedAt > record.observedAt {
            let index = records.firstIndex { $0.observedAt > record.observedAt } ?? records.endIndex
            records.insert(record, at: index)
        } else {
            records.append(record)
        }
    }

    /// Decodes a stored log. Damaged data, an oversized file, or a newer
    /// format reads as an empty log: the log is a convenience for the
    /// daily view, never the only copy of anything.
    public static func decode(_ data: Data) -> UsageSampleLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard data.count <= maximumBytes,
            let log = try? decoder.decode(UsageSampleLog.self, from: data),
            log.formatVersion == currentFormatVersion
        else { return UsageSampleLog() }
        return UsageSampleLog(records: log.records)
    }

    /// Encodes the log, dropping the oldest records until it fits
    /// `maximumBytes`.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var log = self
        var data = try encoder.encode(log)
        while data.count > Self.maximumBytes, !log.records.isEmpty {
            log.records.removeFirst(max(1, log.records.count / 10))
            data = try encoder.encode(log)
        }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, records
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        records = try container.decode([UsageSampleRecord].self, forKey: .records)
    }
}

/// How much of a weekly limit was used on each day of the current limit
/// window, derived from the sample log.
///
/// A day is a 24-hour slice from the window start (`resetsAt` minus the
/// window length), not a calendar day, so a time-zone change or a
/// daylight-saving change does not move the slices, and a reset always
/// starts day 1.
///
/// Derivation:
/// - Only records of the current window count: the same `resetsAt`
///   (within `UsageSampleLog.resetTolerance`), observed between the window
///   start and the current observation. Records of an earlier window (a
///   reset) and records after the current observation (a clock that ran
///   ahead) are ignored.
/// - The level at the window start is 0. The last point is the current
///   percent.
/// - A level that later goes down (the provider corrected it) caps every
///   earlier level, so no day is negative and the days add up to the
///   current percent.
/// - The level at a day boundary is interpolated linearly between the
///   samples around it, so a gap (Rafu closed, provider turned off) is
///   spread over the days it covers instead of landing on one day.
/// - The split is `estimated` when such an interpolation moved usage
///   across a day boundary: two neighbouring points more than
///   `estimateGap` apart, with a day boundary between them and a rise in
///   the level. This covers a log that starts after the window start
///   (the first span runs from the window start at 0) and a gap while
///   Rafu was closed. A long gap with no rise, or one inside a single
///   day, does not change any day's value, so it is not an estimate.
public struct UsageDailyBreakdown: Equatable, Sendable {
    public static let dayLength: TimeInterval = 86_400
    public static let weeklyWindowMinutes = 10_080
    public static let days = 7
    /// Neighbouring samples further apart than this are a gap.
    public static let estimateGap: TimeInterval = 2 * 3_600

    public let windowStart: Date
    /// `days` values: used percent for each past day, today's so far, and
    /// `nil` for each day after the current observation.
    public let daily: [Double?]
    /// `true` when a gap in the log was spread over more than one day.
    public let estimated: Bool
    /// The caller's start of the calendar day (local midnight) that
    /// `todayUsed` counts from, as given to `make`. `nil` when the caller
    /// gave none.
    public let todayStart: Date?
    /// Used percent since `todayStart`, from the same levels as `daily`. A
    /// `todayStart` at or before the window start counts the whole window
    /// so far. `nil` when the caller gave no `todayStart`.
    public let todayUsed: Double?

    public init(
        windowStart: Date, daily: [Double?], estimated: Bool = false, todayStart: Date? = nil,
        todayUsed: Double? = nil
    ) {
        self.windowStart = windowStart
        self.daily = daily
        self.estimated = estimated
        self.todayStart = todayStart
        self.todayUsed = todayUsed
    }

    /// `nil` for a window that is not weekly, has no reset, or does not
    /// contain `observedAt`. `records` may hold any provider windows; only
    /// those of `providerID`/`window` are read. `todayStart` is the start
    /// of the user's calendar day; the caller owns the calendar, so this
    /// type stays pure.
    public static func make(
        records: [UsageSampleRecord], providerID: String, window: String, currentPercent: Double,
        observedAt: Date, resetsAt: Date?, windowMinutes: Int?, todayStart: Date? = nil
    ) -> UsageDailyBreakdown? {
        guard windowMinutes == weeklyWindowMinutes, let resetsAt, currentPercent.isFinite else {
            return nil
        }
        let windowStart = resetsAt.addingTimeInterval(-Double(days) * dayLength)
        guard observedAt >= windowStart, observedAt < resetsAt else { return nil }
        let latest = min(days - 1, Int(observedAt.timeIntervalSince(windowStart) / dayLength))

        var points: [(time: Date, value: Double)] = [(windowStart, 0)]
        let current = records.filter {
            $0.providerID == providerID && $0.window == window
                && !UsageSampleLog.resetChanged($0.resetsAt, resetsAt)
                && $0.observedAt > windowStart && $0.observedAt < observedAt
                && $0.usedPercent.isFinite
        }.sorted { $0.observedAt < $1.observedAt }
        points += current.map { ($0.observedAt, min(max($0.usedPercent, 0), 100)) }
        points.append((observedAt, min(max(currentPercent, 0), 100)))
        // A later, lower level caps every earlier one.
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            points[index].value = min(points[index].value, points[index + 1].value)
        }

        func level(at boundary: Date) -> Double {
            guard let after = points.firstIndex(where: { $0.time >= boundary }) else {
                return points[points.count - 1].value
            }
            guard after > 0 else { return points[0].value }
            let lower = points[after - 1]
            let upper = points[after]
            let span = upper.time.timeIntervalSince(lower.time)
            guard span > 0 else { return upper.value }
            let share = boundary.timeIntervalSince(lower.time) / span
            return lower.value + (upper.value - lower.value) * share
        }

        var levels: [Double] = [0]
        if latest >= 1 {
            for day in 1...latest {
                levels.append(level(at: windowStart.addingTimeInterval(Double(day) * dayLength)))
            }
        }
        levels.append(points[points.count - 1].value)
        var daily: [Double?] = Array(repeating: nil, count: days)
        for day in 0...latest {
            daily[day] = max(0, levels[day + 1] - levels[day])
        }
        let estimated = zip(points, points.dropFirst()).contains { lower, upper in
            guard upper.time.timeIntervalSince(lower.time) > estimateGap,
                upper.value > lower.value
            else { return false }
            // A day boundary strictly between the two points.
            let lowerDay = Int(lower.time.timeIntervalSince(windowStart) / dayLength)
            let boundary = windowStart.addingTimeInterval(Double(lowerDay + 1) * dayLength)
            return boundary < upper.time
        }
        let finalLevel = points[points.count - 1].value
        let todayUsed = todayStart.map { start in
            max(0, finalLevel - level(at: max(start, windowStart)))
        }
        return UsageDailyBreakdown(
            windowStart: windowStart, daily: daily, estimated: estimated, todayStart: todayStart,
            todayUsed: todayUsed)
    }
}

/// Owns the daily usage log file. All disk access runs on this actor,
/// never on the main actor. Every write is atomic (temporary file, then
/// rename) and every read is bounded.
///
/// The app keeps the file in `~/Library/Application Support/<App
/// Name>/Usage/`, not in the widget folder: the extension never reads the
/// log; the app writes the derived daily values into the widget snapshot.
public actor UsageSampleLogStore {
    public static let fileName = "usage-samples.json"

    public let fileURL: URL
    private var log: UsageSampleLog?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `<applicationSupport>/<appName>/Usage/usage-samples.json`.
    public static func fileURL(applicationSupport: URL, appName: String) -> URL {
        applicationSupport.appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "Usage", directoryHint: .isDirectory)
            .appending(path: fileName, directoryHint: .notDirectory)
    }

    /// The log as stored (read once, then kept in memory).
    public func load() -> UsageSampleLog {
        if let log { return log }
        let loaded =
            Self.readBounded(fileURL, limit: UsageSampleLog.maximumBytes).map(
                UsageSampleLog.decode) ?? UsageSampleLog()
        log = loaded
        return loaded
    }

    /// Appends `samples` under the log's cadence rules, prunes, and writes
    /// the file when the log changed. A write error keeps the in-memory
    /// log; the next change tries again. Returns the current log.
    @discardableResult
    public func record(_ samples: [UsageSampleRecord], now: Date) -> UsageSampleLog {
        var current = load()
        if current.append(samples, now: now) {
            log = current
            try? write(current)
        }
        return current
    }

    /// Merges backfill samples (`UsageSampleLog.mergeBackfill`) and writes
    /// the file when the log changed. Returns whether it changed.
    @discardableResult
    public func backfill(_ samples: [UsageSampleRecord], now: Date) -> Bool {
        var current = load()
        guard current.mergeBackfill(samples, now: now) else { return false }
        log = current
        try? write(current)
        return true
    }

    private func write(_ log: UsageSampleLog) throws {
        let data = try log.encoded()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Reads at most `limit` bytes; a larger file reads as absent.
    static func readBounded(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else {
            return nil
        }
        return data
    }
}
