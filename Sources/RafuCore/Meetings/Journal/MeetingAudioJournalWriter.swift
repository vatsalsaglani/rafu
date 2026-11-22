import Darwin
import Foundation

/// The points where the journal writer makes a segment durable, in order.
/// Tests inject a failure at each one and check recovery.
public enum MeetingJournalSyncPoint: Hashable, Sendable, CaseIterable {
    /// The segment bytes are in `<n>.partial`, not synced.
    case segmentWritten
    /// `fsync` returned; the file is still `<n>.partial`.
    case segmentSynced
    /// The file is renamed to `<n>.seg`; the index is not updated yet.
    case segmentRenamed
    /// The index is written.
    case indexWritten
}

/// A journal write error.
public enum MeetingJournalError: Error, Hashable, Sendable {
    case diskFull
    /// A POSIX call failed with this `errno`.
    case io(errno: Int32)
    /// A test stopped the writer at this point.
    case injected(MeetingJournalSyncPoint)
}

/// Writes the crash-safe audio journal of one recording: for each track,
/// 16 kHz mono Int16 audio in fixed segments (10 s by default). A segment is
/// written to `<n>.partial`, synced with `fsync`, renamed to `<n>.seg`, and
/// the index is replaced atomically. A crash loses at most the open segment.
///
/// Not `Sendable`: the recorder actor owns it and is its only user.
public final class MeetingAudioJournalWriter {
    public typealias FaultInjector = (MeetingJournalSyncPoint, MeetingTrack) throws -> Void

    /// Start a new segment when a block starts more than this far from the
    /// end of the open segment (a gap, a drop, or clock drift).
    public static let reanchorTolerance: TimeInterval = 0.1

    public let audioFolder: URL
    public let segmentFrames: Int
    private let diagnostics: any MeetingDiagnosticsRecording
    private let meeting: MeetingID?
    private let faultInjector: FaultInjector?

    private struct OpenSegment {
        var index: UInt32
        var startTime: TimeInterval
        var samples: [Int16]
    }

    private var open: [MeetingTrack: OpenSegment] = [:]
    private var nextIndex: [MeetingTrack: UInt32] = [.me: 1, .them: 1]
    private var index = MeetingJournalIndex()

    public init(
        audioFolder: URL, segmentSeconds: TimeInterval = 10,
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        meeting: MeetingID? = nil, faultInjector: FaultInjector? = nil
    ) {
        self.audioFolder = audioFolder
        self.segmentFrames = max(1, Int(segmentSeconds * MeetingAudioFormat.sampleRate))
        self.diagnostics = diagnostics
        self.meeting = meeting
        self.faultInjector = faultInjector
    }

    /// Makes the journal folders (mode 0700). Continues the numbering of
    /// segments already on disk, so a second writer never overwrites them.
    public func prepare() throws {
        for track in MeetingTrack.allCases {
            let folder = MeetingJournalLayout.trackFolder(track, in: audioFolder)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let highest =
                existing.compactMap { name -> UInt32? in
                    UInt32(name.split(separator: ".").first ?? "")
                }.max() ?? 0
            nextIndex[track] = highest + 1
        }
    }

    /// Frames in the open segment of a track.
    public func openFrames(_ track: MeetingTrack) -> Int { open[track]?.samples.count ?? 0 }

    /// Adds samples whose first sample is at `startTime` on the meeting
    /// clock. Closes a segment when it is full or when the block does not
    /// follow the open segment.
    public func append(track: MeetingTrack, samples: [Int16], startTime: TimeInterval) throws {
        guard !samples.isEmpty else { return }
        if let segment = open[track] {
            let expected =
                segment.startTime + Double(segment.samples.count) / MeetingAudioFormat.sampleRate
            if abs(startTime - expected) > Self.reanchorTolerance { try close(track) }
        }
        if open[track] == nil { open[track] = newSegment(track, startTime: startTime) }
        open[track]?.samples.append(contentsOf: samples)
        while let count = open[track]?.samples.count, count >= segmentFrames,
            let segmentStart = open[track]?.startTime
        {
            let rest = open[track].map { Array($0.samples[segmentFrames...]) } ?? []
            open[track]?.samples.removeLast(rest.count)
            try close(track)
            if !rest.isEmpty {
                let restStart = segmentStart + Double(segmentFrames) / MeetingAudioFormat.sampleRate
                var next = newSegment(track, startTime: restStart)
                next.samples.append(contentsOf: rest)
                open[track] = next
            }
        }
    }

    /// Closes the open segments of both tracks (at Pause, Stop, or a gap).
    public func flush() throws {
        for track in MeetingTrack.allCases { try close(track) }
    }

    /// Closes the open segment of one track.
    public func close(_ track: MeetingTrack) throws {
        guard let segment = open.removeValue(forKey: track), !segment.samples.isEmpty else {
            return
        }
        try write(segment, track: track)
    }

    private func newSegment(_ track: MeetingTrack, startTime: TimeInterval) -> OpenSegment {
        let number = nextIndex[track] ?? 1
        nextIndex[track] = number + 1
        var samples: [Int16] = []
        samples.reserveCapacity(segmentFrames)
        return OpenSegment(index: number, startTime: startTime, samples: samples)
    }

    private func write(_ segment: OpenSegment, track: MeetingTrack) throws {
        let folder = MeetingJournalLayout.trackFolder(track, in: audioFolder)
        let name = MeetingJournalLayout.segmentName(segment.index)
        let final = folder.appending(path: name)
        let partial = final.deletingPathExtension().appendingPathExtension(
            MeetingJournalLayout.partialExtension)
        let payload = segment.samples.withUnsafeBytes { Data($0) }
        let header = MeetingJournalSegmentHeader(
            track: track, index: segment.index, startTime: segment.startTime,
            frameCount: UInt32(segment.samples.count),
            payloadChecksum: MeetingCRC32.checksum(payload))
        let bytes = header.encoded() + payload
        do {
            let descriptor = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard descriptor >= 0 else { throw Self.error(errno) }
            defer { Darwin.close(descriptor) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.error(errno)
                    }
                    offset += written
                }
            }
            try faultInjector?(.segmentWritten, track)
            guard fsync(descriptor) == 0 else { throw Self.error(errno) }
            try faultInjector?(.segmentSynced, track)
            guard rename(partial.path, final.path) == 0 else { throw Self.error(errno) }
            Self.syncDirectory(folder)
            try faultInjector?(.segmentRenamed, track)
            index.lastSyncedSegment[track] = segment.index
            index.syncedFrames[track, default: 0] += Int64(segment.samples.count)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(index).write(
                to: MeetingJournalLayout.journalFolder(in: audioFolder).appending(
                    path: MeetingJournalLayout.indexFileName),
                options: .atomic)
            try faultInjector?(.indexWritten, track)
            diagnostics.record(.journalSync(bytes: Int64(bytes.count), ok: true), meeting: meeting)
        } catch {
            diagnostics.record(.journalSync(bytes: Int64(bytes.count), ok: false), meeting: meeting)
            throw Self.classify(error)
        }
    }

    private static func error(_ code: Int32) -> MeetingJournalError {
        code == ENOSPC || code == EDQUOT ? .diskFull : .io(errno: code)
    }

    private static func classify(_ error: any Error) -> MeetingJournalError {
        if let journal = error as? MeetingJournalError { return journal }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            posix.domain == NSPOSIXErrorDomain
        {
            return Self.error(Int32(posix.code))
        }
        if ns.domain == NSPOSIXErrorDomain { return Self.error(Int32(ns.code)) }
        return .io(errno: 0)
    }

    private static func syncDirectory(_ folder: URL) {
        let descriptor = Darwin.open(folder.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        Darwin.close(descriptor)
    }
}
