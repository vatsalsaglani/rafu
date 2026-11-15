import Foundation

/// Rebuilds the weekly Codex usage history from the local rollout logs
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), so the daily split has
/// earlier days even when Rafu was not running.
///
/// Verified shape (2026-11-15): every `token_count` line is
/// `{"timestamp", "type": "event_msg", "payload": {"type": "token_count",
/// "rate_limits": {"limit_id", "primary": {"used_percent", "window_minutes",
/// "resets_at"}, "secondary": {...} | null, ...}}}`. `resets_at` is epoch
/// seconds. The weekly window is the one whose `window_minutes` is 10080.
/// It is `primary` on a plan without a 5-hour window and `secondary` when
/// `primary` is the 5-hour window (300), so the slot is never used to pick
/// it. A `limit_id` other than `codex` (a separate per-model limit) is a
/// different counter and is skipped; a line without `limit_id` is accepted.
///
/// Privacy and bounds:
/// - Only the timestamp, used percent, window length, and reset time are
///   decoded, and only those leave the line parser. No message text is read
///   into a kept value, logged, or stored. `Sample` has no string field.
/// - Files: only rollouts modified in the trailing window, newest first, at
///   most `Limits.maxFiles`. Bytes: only the last `maxBytesPerFile` of a file
///   and `maxTotalBytes` in all. Lines: read in chunks; a line longer than
///   `maxLineBytes` is skipped without being kept (real rollouts hold lines
///   of many megabytes).
/// - One autorelease pool for each chunk and each file entry, and a
///   cancellation check between chunks and entries.
///
/// Claude has no percent in its logs, so there is no Claude backfill.
public enum CodexRolloutBackfill {
    public static let providerID = "codex"
    /// The log window label for the weekly Codex window (the label the
    /// Codex usage provider gives a 10080-minute window).
    public static let windowLabel = "7d"
    /// The backfill runs at most this often.
    public static let minimumRunInterval: TimeInterval = 24 * 3_600
    static let newline: UInt8 = 0x0A

    public struct Limits: Equatable, Sendable {
        public var maxFiles = 40
        public var maxBytesPerFile = 8 << 20
        public var maxTotalBytes = 128 << 20
        public var maxLineBytes = 64 << 10
        public var chunkBytes = 256 << 10
        public var maxEnumeratedEntries = 50_000

        public init() {}
    }

    /// One weekly-window observation. Numbers and dates only.
    public struct Sample: Equatable, Sendable {
        public var observedAt: Date
        public var usedPercent: Double
        public var resetsAt: Date
    }

    /// `true` when the backfill is due: it never ran, the last run is a day
    /// old or more, or the last run is in the future (the clock was set back).
    public static func isDue(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        let age = now.timeIntervalSince(lastRun)
        return age >= minimumRunInterval || age < -UsageSampleLog.futureTolerance
    }

    /// The log records for `samples`, marked `isBackfill`.
    public static func records(from samples: [Sample]) -> [UsageSampleRecord] {
        samples.map {
            UsageSampleRecord(
                providerID: providerID, window: windowLabel, usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt, observedAt: $0.observedAt, isBackfill: true)
        }
    }

    /// Scans, then merges into `store`. Returns whether the log changed.
    /// Throws `CancellationError` when the task is cancelled; nothing is
    /// merged then.
    public static func run(
        store: UsageSampleLogStore, sessionsDirectory: URL, now: Date,
        limits: Limits = Limits()
    ) async throws -> Bool {
        let samples = try scan(sessionsDirectory: sessionsDirectory, now: now, limits: limits)
        try Task.checkCancellation()
        return await store.backfill(records(from: samples), now: now)
    }

    // MARK: - Scan

    /// Weekly samples from the newest rollouts under `sessionsDirectory`,
    /// at most one per 15-minute bucket (the last one), oldest first. An
    /// unreadable file is skipped. Throws only `CancellationError`.
    public static func scan(
        sessionsDirectory: URL, now: Date, limits: Limits = Limits()
    ) throws -> [Sample] {
        let cutoff = now.addingTimeInterval(-7 * 24 * 3_600)
        let latest = now.addingTimeInterval(UsageSampleLog.futureTolerance)
        var buckets: [Int: Sample] = [:]
        var bytesRead = 0
        for file in try candidateFiles(
            under: sessionsDirectory, modifiedOnOrAfter: cutoff, limits: limits)
        {
            try Task.checkCancellation()
            guard bytesRead < limits.maxTotalBytes else { break }
            let budget = min(limits.maxBytesPerFile, limits.maxTotalBytes - bytesRead)
            let read = try withAutoreleasePool { () throws -> Int in
                try forEachLine(file.url, maxBytes: budget, limits: limits) { line in
                    guard let sample = parseLine(line), sample.observedAt >= cutoff,
                        sample.observedAt <= latest
                    else { return }
                    let bucket = Int(
                        sample.observedAt.timeIntervalSince1970 / UsageSampleLog.minimumInterval)
                    if let kept = buckets[bucket], kept.observedAt >= sample.observedAt { return }
                    buckets[bucket] = sample
                }
            }
            bytesRead += read
        }
        return buckets.values.sorted { $0.observedAt < $1.observedAt }
    }

    struct Candidate {
        var url: URL
        var modified: Date

        /// The start stamp in `rollout-YYYY-MM-DDThh-mm-ss-<id>.jsonl`; it
        /// sorts as text. `nil` for a name without one.
        var startStamp: String? {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-") else { return nil }
            let stamp = name.dropFirst("rollout-".count).prefix(19)
            return stamp.count == 19 ? String(stamp) : nil
        }

        /// Newest first: by modification day, then by start stamp, then by
        /// modification time. Modification time alone cannot rank files:
        /// on one machine every rollout of a year had the same day as its
        /// modification date (the files had been touched together), so the
        /// start stamp in the name breaks the tie.
        func isNewer(than other: Candidate) -> Bool {
            let day = (modified.timeIntervalSince1970 / 86_400).rounded(.down)
            let otherDay = (other.modified.timeIntervalSince1970 / 86_400).rounded(.down)
            if day != otherDay { return day > otherDay }
            if let stamp = startStamp, let otherStamp = other.startStamp, stamp != otherStamp {
                return stamp > otherStamp
            }
            return modified > other.modified
        }
    }

    /// Rollout files modified on or after `cutoff`, newest first, at most
    /// `limits.maxFiles` (see `Candidate.isNewer`). No `skipDescendants`: nothing is pruned, and the
    /// entry count is capped instead.
    static func candidateFiles(
        under directory: URL, modifiedOnOrAfter cutoff: Date, limits: Limits
    ) throws -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return [] }
        var found: [Candidate] = []
        var entries = 0
        while entries < limits.maxEnumeratedEntries {
            try Task.checkCancellation()
            let finished = withAutoreleasePool { () -> Bool in
                guard let url = enumerator.nextObject() as? URL else { return true }
                entries += 1
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                    let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true,
                    let modified = values.contentModificationDate, modified >= cutoff
                else { return false }
                found.append(Candidate(url: url, modified: modified))
                return false
            }
            if finished { break }
        }
        found.sort { $0.isNewer(than: $1) }
        return Array(found.prefix(limits.maxFiles))
    }

    // MARK: - Line reading

    /// Calls `body` for each complete line in the last `maxBytes` of the
    /// file. A cut that starts mid-line drops that first partial line. A line
    /// longer than `limits.maxLineBytes` is skipped. Returns the bytes read.
    /// An unreadable file returns 0.
    @discardableResult
    static func forEachLine(
        _ url: URL, maxBytes: Int, limits: Limits, _ body: (Data) -> Void
    ) throws -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return 0 }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil else { return 0 }

        var remaining = Int(size - offset)
        let total = remaining
        var skippingPartial = offset > 0
        var line = Data()
        var overflow = false
        var finished = false
        while remaining > 0, !finished {
            try Task.checkCancellation()
            // One pool for each chunk: the read data is freed here.
            finished = withAutoreleasePool { () -> Bool in
                guard let chunk = try? handle.read(upToCount: min(limits.chunkBytes, remaining)),
                    !chunk.isEmpty
                else { return true }
                remaining -= chunk.count
                chunk.withUnsafeBytes { raw in
                    var start = 0
                    while start < raw.count {
                        let rest = raw.baseAddress.unsafelyUnwrapped + start
                        let found = memchr(rest, Int32(newline), raw.count - start)
                        let end = found.map { raw.baseAddress.unsafelyUnwrapped.distance(to: $0) }
                        let stop = end ?? raw.count
                        if skippingPartial {
                            if end != nil { skippingPartial = false }
                        } else if !overflow {
                            if line.count + (stop - start) > limits.maxLineBytes {
                                overflow = true
                                line = Data()
                            } else {
                                line.append(
                                    contentsOf: UnsafeRawBufferPointer(
                                        rebasing: raw[start..<stop]))
                            }
                        }
                        guard end != nil else { break }
                        if !skippingPartial, !overflow, !line.isEmpty { body(line) }
                        line.removeAll(keepingCapacity: true)
                        overflow = false
                        start = stop + 1
                    }
                }
                return false
            }
        }
        // A final line without a newline: the file may still be written, so
        // it can be cut mid-object; the parser rejects it then.
        if !skippingPartial, !overflow, !line.isEmpty { body(line) }
        return total - remaining
    }

    // MARK: - Line parsing

    private static let rateLimitsMarker = Data("\"rate_limits\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)

    /// The weekly-window sample of one rollout line, or `nil` when the line
    /// is not a `token_count` event with a weekly window. Never throws and
    /// keeps no text.
    public static func parseLine(_ line: Data) -> Sample? {
        guard line.range(of: tokenCountMarker) != nil, line.range(of: rateLimitsMarker) != nil,
            let decoded = try? JSONDecoder().decode(Line.self, from: line),
            decoded.payload?.type == "token_count",
            let limits = decoded.payload?.rateLimits,
            limits.limitID == nil || limits.limitID == providerID,
            let timestamp = decoded.timestamp, let observedAt = parseTimestamp(timestamp)
        else { return nil }
        for window in [limits.primary, limits.secondary] {
            guard let window, let minutes = window.windowMinutes,
                minutes == Double(UsageDailyBreakdown.weeklyWindowMinutes),
                let percent = window.usedPercent, percent.isFinite, (0...100).contains(percent),
                let resets = window.resetsAt, resets.isFinite, resets > 0, resets < 4_102_444_800
            else { continue }
            return Sample(
                observedAt: observedAt, usedPercent: percent,
                resetsAt: Date(timeIntervalSince1970: resets))
        }
        return nil
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    private struct Line: Decodable {
        let timestamp: String?
        let payload: Payload?

        struct Payload: Decodable {
            let type: String?
            let rateLimits: RateLimits?

            enum CodingKeys: String, CodingKey {
                case type
                case rateLimits = "rate_limits"
            }
        }
    }

    private struct RateLimits: Decodable {
        let limitID: String?
        let primary: Window?
        let secondary: Window?

        enum CodingKeys: String, CodingKey {
            case limitID = "limit_id"
            case primary, secondary
        }
    }

    private struct Window: Decodable {
        let usedPercent: Double?
        let windowMinutes: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }
}
