import Foundation

/// One event with the time and meeting clock that the recorder stamped.
public struct MeetingDiagnosticsEntry: Sendable {
    public var meeting: MeetingID?
    public var event: MeetingDiagnosticEvent
    public var time: Date
    public var clock: Double?

    public init(
        meeting: MeetingID?, event: MeetingDiagnosticEvent, time: Date, clock: Double?
    ) {
        self.meeting = meeting
        self.event = event
        self.time = time
        self.clock = clock
    }
}

/// The limits of the diagnostics files.
public struct MeetingDiagnosticsLimits: Hashable, Sendable {
    /// At the limit, a file moves to `<name>.1.jsonl` and a new file starts.
    public var rotationBytes: Int
    /// Rafu keeps the files of the newest meetings only.
    public var retainedMeetings: Int
    /// The write buffer flushes when it holds this many bytes.
    public var maximumBufferedBytes: Int

    public static let standard = MeetingDiagnosticsLimits(
        rotationBytes: 2 * 1024 * 1024, retainedMeetings: 20, maximumBufferedBytes: 64 * 1024)

    public init(rotationBytes: Int, retainedMeetings: Int, maximumBufferedBytes: Int) {
        self.rotationBytes = rotationBytes
        self.retainedMeetings = retainedMeetings
        self.maximumBufferedBytes = maximumBufferedBytes
    }
}

/// Writes JSON lines to the diagnostics folder: one file for each meeting
/// (`<meeting id>.jsonl`) and `app.jsonl` for events with no meeting.
///
/// - The folder is mode 0700 and each file 0600.
/// - Lines wait in a bounded buffer that flushes every `flushInterval` and
///   at `stop()`.
/// - A file rotates to `.1.jsonl` at the limit, so a meeting holds at most
///   two files. Rafu keeps the newest `retainedMeetings` meetings.
/// - A write error never reaches the caller. The lost lines go into a drop
///   counter, and the next line that is written reports it as `dropped`.
/// - The folder is the injected one; the writer writes nowhere else.
public actor MeetingDiagnosticsFileWriter {
    /// The file that a line goes to.
    public enum FileKey: Hashable, Sendable {
        case app
        case meeting(MeetingID)

        var stem: String {
            switch self {
            case .app: "app"
            case .meeting(let id): id.uuidString
            }
        }
    }

    public static let appFileStem = "app"

    private let directory: URL
    private let limits: MeetingDiagnosticsLimits
    private let flushInterval: Duration
    private let header: @Sendable () -> MeetingDiagnosticEvent?
    private let now: @Sendable () -> Date

    private var buffers: [FileKey: Data] = [:]
    private var bufferedBytes = 0
    private var pendingDropped = 0
    private var flushTask: Task<Void, Never>?
    /// Files this process has written to, which have their header already.
    private var headerWritten: Set<FileKey> = []
    private var touched: Set<FileKey> = []

    /// - Parameters:
    ///   - directory: the diagnostics folder (the only place the writer writes).
    ///   - header: the header event that starts each file (when a process first
    ///     writes to it and after a rotation); nil writes none.
    public init(
        directory: URL, limits: MeetingDiagnosticsLimits = .standard,
        flushInterval: Duration = .seconds(2),
        header: @escaping @Sendable () -> MeetingDiagnosticEvent? = { nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.limits = limits
        self.flushInterval = flushInterval
        self.header = header
        self.now = now
    }

    // MARK: Writing

    /// Adds one line to the buffer. `queueDropped` is the number of events
    /// that the recorder's queue lost since the previous line.
    public func append(_ entry: MeetingDiagnosticsEntry, queueDropped: Int = 0) {
        pendingDropped += max(0, queueDropped)
        let line = MeetingDiagnosticsEncoder.line(
            for: entry.event, time: entry.time, clock: entry.clock, dropped: pendingDropped)
        pendingDropped = 0
        let key: FileKey = entry.meeting.map(FileKey.meeting) ?? .app
        var data = Data(line.utf8)
        data.append(0x0A)
        buffers[key, default: Data()].append(data)
        bufferedBytes += data.count
        if bufferedBytes >= limits.maximumBufferedBytes {
            flush()
        } else {
            scheduleFlush()
        }
    }

    /// Writes the buffer now.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffers.isEmpty else { return }
        let pending = buffers
        buffers = [:]
        bufferedBytes = 0
        for (key, data) in pending {
            write(data, to: key)
        }
    }

    /// Writes the buffer and stops the timer.
    public func stop() {
        flush()
    }

    /// The number of lines that were lost and are not reported yet.
    public var unreportedDroppedCount: Int { pendingDropped }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let interval = flushInterval
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        flushTask = nil
        flush()
    }

    private func write(_ data: Data, to key: FileKey) {
        let lineCount = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        do {
            try prepareDirectory()
            let url = fileURL(key, rotated: false)
            var size = Self.size(of: url)
            if size > 0, size + data.count > limits.rotationBytes {
                try rotate(key)
                size = 0
                headerWritten.remove(key)
            }
            var payload = Data()
            if !headerWritten.contains(key), let headerEvent = header() {
                payload.append(
                    Data(
                        MeetingDiagnosticsEncoder.line(
                            for: headerEvent, time: now(), clock: nil
                        ).utf8))
                payload.append(0x0A)
            }
            payload.append(data)
            try append(payload, to: url)
            headerWritten.insert(key)
            if touched.insert(key).inserted, case .meeting = key {
                enforceRetention(keeping: key)
            }
        } catch {
            pendingDropped += lineCount
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard
                manager.createFile(
                    atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rotate(_ key: FileKey) throws {
        let manager = FileManager.default
        let current = fileURL(key, rotated: false)
        let rotated = fileURL(key, rotated: true)
        if manager.fileExists(atPath: rotated.path) {
            try manager.removeItem(at: rotated)
        }
        try manager.moveItem(at: current, to: rotated)
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    // MARK: Retention

    /// Deletes the files of the oldest meetings beyond the limit. The meeting
    /// just written is never deleted.
    private func enforceRetention(keeping kept: FileKey) {
        let manager = FileManager.default
        guard
            let names = try? manager.contentsOfDirectory(atPath: directory.path)
        else { return }
        var newest: [String: Date] = [:]
        for name in names {
            guard let stem = Self.meetingStem(ofFileName: name) else { continue }
            let url = directory.appending(path: name)
            let modified =
                (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                ?? .distantPast
            newest[stem] = max(newest[stem] ?? .distantPast, modified)
        }
        let ordered = newest.sorted { $0.value > $1.value }.map(\.key)
        guard ordered.count > limits.retainedMeetings else { return }
        for stem in ordered.dropFirst(limits.retainedMeetings) where stem != kept.stem {
            Self.removeFiles(stem: stem, in: directory)
        }
    }

    /// The meeting part of `<id>.jsonl` or `<id>.1.jsonl`; nil for `app` files
    /// and other files.
    private static func meetingStem(ofFileName name: String) -> String? {
        let stem: String
        if name.hasSuffix(".1.jsonl") {
            stem = String(name.dropLast(".1.jsonl".count))
        } else if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else {
            return nil
        }
        return stem == appFileStem ? nil : stem
    }

    private static func removeFiles(stem: String, in directory: URL) {
        for name in ["\(stem).jsonl", "\(stem).1.jsonl"] {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    // MARK: Delete and export

    /// Deletes the diagnostics files of one meeting, and any lines that wait.
    public func delete(meeting: MeetingID) {
        let key = FileKey.meeting(meeting)
        if let waiting = buffers.removeValue(forKey: key) {
            bufferedBytes -= waiting.count
        }
        headerWritten.remove(key)
        touched.remove(key)
        Self.removeFiles(stem: key.stem, in: directory)
    }

    /// Flushes, then lists the files for an export: `app.jsonl` (and its
    /// rotated file) and the files of the newest `meetings` meetings.
    public func exportFiles(newestMeetings meetings: Int) -> [URL] {
        flush()
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var newest: [String: Date] = [:]
        var result: [URL] = []
        for name in names {
            if name == "\(Self.appFileStem).jsonl" || name == "\(Self.appFileStem).1.jsonl" {
                result.append(directory.appending(path: name))
            } else if let stem = Self.meetingStem(ofFileName: name) {
                let modified =
                    (try? manager.attributesOfItem(
                        atPath: directory.appending(path: name).path)[.modificationDate] as? Date)
                    ?? .distantPast
                newest[stem] = max(newest[stem] ?? .distantPast, modified)
            }
        }
        let chosen = Set(newest.sorted { $0.value > $1.value }.prefix(max(0, meetings)).map(\.key))
        for name in names {
            if let stem = Self.meetingStem(ofFileName: name), chosen.contains(stem) {
                result.append(directory.appending(path: name))
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Helpers

    private func fileURL(_ key: FileKey, rotated: Bool) -> URL {
        directory.appending(path: "\(key.stem)\(rotated ? ".1" : "").jsonl")
    }

    private static func size(of url: URL) -> Int {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.intValue ?? 0
    }
}
