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

    public init(
        providerID: String, window: String, usedPercent: Double, resetsAt: Date?, observedAt: Date
    ) {
        self.providerID = providerID
        self.window = window
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "p"
        case window = "w"
        case usedPercent = "u"
        case resetsAt = "r"
        case observedAt = "o"
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
public struct UsageDailyBreakdown: Equatable, Sendable {
    public static let dayLength: TimeInterval = 86_400
    public static let weeklyWindowMinutes = 10_080
    public static let days = 7

    public let windowStart: Date
    /// `days` values: used percent for each past day, today's so far, and
    /// `nil` for each day after the current observation.
    public let daily: [Double?]

    public init(windowStart: Date, daily: [Double?]) {
        self.windowStart = windowStart
        self.daily = daily
    }

    /// `nil` for a window that is not weekly, has no reset, or does not
    /// contain `observedAt`. `records` may hold any provider windows; only
    /// those of `providerID`/`window` are read.
    public static func make(
        records: [UsageSampleRecord], providerID: String, window: String, currentPercent: Double,
        observedAt: Date, resetsAt: Date?, windowMinutes: Int?
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
        return UsageDailyBreakdown(windowStart: windowStart, daily: daily)
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
