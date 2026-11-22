import Darwin
import Foundation

/// What recovery did for one track.
public struct MeetingTrackRecovery: Hashable, Sendable {
    public var track: MeetingTrack
    /// Segments that passed the checks (synced and not yet renamed ones
    /// included when their checksum is good).
    public var segmentsUsed: Int
    /// Segments that failed a check and were left out.
    public var segmentsDropped: Int
    /// Frames in the final file, gap silence included.
    public var frames: Int64
    /// The final file, when one was written.
    public var file: URL?

    public var seconds: TimeInterval { Double(frames) / MeetingAudioFormat.sampleRate }
}

/// The result of one recovery.
public struct MeetingJournalRecoveryReport: Hashable, Sendable {
    public var tracks: [MeetingTrackRecovery]

    public var result: MeetingJournalRecoveryResult {
        let used = tracks.reduce(0) { $0 + $1.segmentsUsed }
        let dropped = tracks.reduce(0) { $0 + $1.segmentsDropped }
        if used == 0 { return dropped == 0 ? .nothingToRecover : .failed }
        return dropped == 0 ? .recovered : .partlyRecovered
    }

    public var recoveredSeconds: TimeInterval {
        tracks.map(\.seconds).max() ?? 0
    }

    public func track(_ track: MeetingTrack) -> MeetingTrackRecovery? {
        tracks.first { $0.track == track }
    }
}

/// Makes the final `<track>.caf` files from the journal. It reads every
/// segment that passes its checks, places each one at its meeting-clock
/// time (silence fills the gaps, so a file position is a meeting-clock
/// time), and writes the file atomically. The same journal always gives the
/// same bytes, so a second recovery is safe. Recovery never deletes the
/// journal; `removeJournal(in:)` does that after the caller has the files.
public enum MeetingAudioJournalRecovery {
    /// A segment placed later than this is treated as damaged.
    public static let maximumStartTime: TimeInterval = 24 * 60 * 60

    public static func recover(
        audioFolder: URL, diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        meeting: MeetingID? = nil
    ) throws -> MeetingJournalRecoveryReport {
        var tracks: [MeetingTrackRecovery] = []
        for track in MeetingTrack.allCases {
            tracks.append(try recoverTrack(track, audioFolder: audioFolder))
        }
        let report = MeetingJournalRecoveryReport(tracks: tracks)
        diagnostics.record(
            .journalRecovery(result: report.result, recoveredSeconds: report.recoveredSeconds),
            meeting: meeting)
        return report
    }

    /// Deletes the journal folder.
    public static func removeJournal(in audioFolder: URL) throws {
        let folder = MeetingJournalLayout.journalFolder(in: audioFolder)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// True when the folder holds journal segments.
    public static func hasJournal(in audioFolder: URL) -> Bool {
        MeetingTrack.allCases.contains { track in
            let folder = MeetingJournalLayout.trackFolder(track, in: audioFolder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return !names.isEmpty
        }
    }

    private struct Placed {
        var url: URL
        var header: MeetingJournalSegmentHeader
        var position: Int64
    }

    private static func recoverTrack(_ track: MeetingTrack, audioFolder: URL) throws
        -> MeetingTrackRecovery
    {
        let folder = MeetingJournalLayout.trackFolder(track, in: audioFolder)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter {
                $0.hasSuffix("." + MeetingJournalLayout.segmentExtension)
                    || $0.hasSuffix("." + MeetingJournalLayout.partialExtension)
            }
        var placed: [Placed] = []
        var dropped = 0
        for name in names {
            let url = folder.appending(path: name)
            guard let header = validHeader(url, track: track) else {
                dropped += 1
                continue
            }
            let position = Int64((header.startTime * MeetingAudioFormat.sampleRate).rounded())
            placed.append(Placed(url: url, header: header, position: max(0, position)))
        }
        // The same segment can exist as `.seg` and `.partial` only after a
        // crash between the rename and its retry; keep one per index.
        var seen = Set<UInt32>()
        placed = placed.sorted {
            ($0.header.index, $0.url.pathExtension) < ($1.header.index, $1.url.pathExtension)
        }
        .filter { seen.insert($0.header.index).inserted }
        .sorted { ($0.position, $0.header.index) < ($1.position, $1.header.index) }

        guard !placed.isEmpty else {
            return MeetingTrackRecovery(
                track: track, segmentsUsed: 0, segmentsDropped: dropped, frames: 0, file: nil)
        }
        var total: Int64 = 0
        for segment in placed {
            total = max(total, segment.position + Int64(segment.header.frameCount))
        }
        let destination = MeetingJournalLayout.finalAudioFile(track, in: audioFolder)
        let temporary = audioFolder.appending(path: ".\(track.rawValue).caf.writing")
        let writer = try MeetingCAFFileWriter(url: temporary, frameCount: total)
        do {
            var cursor: Int64 = 0
            for segment in placed {
                guard let payload = payload(of: segment.url, header: segment.header) else {
                    continue
                }
                if segment.position > cursor {
                    try writer.writeSilence(frames: segment.position - cursor)
                    cursor = segment.position
                }
                let skip = Int(cursor - segment.position)
                let frames = Int(segment.header.frameCount)
                guard skip < frames else { continue }
                try payload.withUnsafeBytes { raw in
                    try writer.write(
                        UnsafeRawBufferPointer(rebasing: raw[(skip * 2)..<(frames * 2)]))
                }
                cursor += Int64(frames - skip)
            }
            if cursor < total { try writer.writeSilence(frames: total - cursor) }
            try writer.finish()
        } catch {
            writer.abandon()
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw MeetingJournalError.io(errno: errno)
        }
        return MeetingTrackRecovery(
            track: track, segmentsUsed: placed.count, segmentsDropped: dropped, frames: total,
            file: destination)
    }

    private static func validHeader(_ url: URL, track: MeetingTrack)
        -> MeetingJournalSegmentHeader?
    {
        guard let data = try? Data(contentsOf: url),
            let header = MeetingJournalSegmentHeader.decode(data),
            header.track == track,
            header.sampleRate == UInt32(MeetingAudioFormat.sampleRate),
            header.startTime.isFinite, header.startTime > -1,
            header.startTime < maximumStartTime,
            data.count == MeetingJournalSegmentHeader.size + Int(header.frameCount) * 2
        else { return nil }
        let checksum = data.withUnsafeBytes { raw in
            MeetingCRC32.checksum(
                UnsafeRawBufferPointer(rebasing: raw[MeetingJournalSegmentHeader.size...]))
        }
        return checksum == header.payloadChecksum ? header : nil
    }

    private static func payload(of url: URL, header: MeetingJournalSegmentHeader) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.subdata(in: MeetingJournalSegmentHeader.size..<data.count)
    }
}

/// Writes a CAF file of 16 kHz mono 16-bit little-endian linear PCM. The
/// frame count is known before the first sample, so the file has exact
/// chunk sizes and the same input always gives the same bytes.
public final class MeetingCAFFileWriter {
    public static let headerSize = 8 + 12 + 32 + 12 + 4

    private let url: URL
    private let descriptor: Int32
    private let zeros = [UInt8](repeating: 0, count: 64 * 1024)

    public init(url: URL, frameCount: Int64) throws {
        self.url = url
        descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw MeetingJournalError.io(errno: errno) }
        let header = Self.header(frameCount: frameCount)
        try header.withUnsafeBytes { try write($0) }
    }

    /// The CAF header: file header, `desc` chunk, and the `data` chunk
    /// header with its edit count.
    public static func header(frameCount: Int64) -> Data {
        var data = Data()
        data.append(contentsOf: Array("caff".utf8))
        data.appendJournalBigEndian(UInt16(1))  // file version
        data.appendJournalBigEndian(UInt16(0))  // flags
        data.append(contentsOf: Array("desc".utf8))
        data.appendJournalBigEndian(Int64(32))
        data.appendJournalBigEndian(MeetingAudioFormat.sampleRate.bitPattern)
        data.append(contentsOf: Array("lpcm".utf8))
        data.appendJournalBigEndian(UInt32(2))  // kCAFLinearPCMFormatFlagIsLittleEndian
        data.appendJournalBigEndian(UInt32(MeetingAudioFormat.bytesPerFrame))  // bytes per packet
        data.appendJournalBigEndian(UInt32(1))  // frames per packet
        data.appendJournalBigEndian(UInt32(MeetingAudioFormat.channelCount))
        data.appendJournalBigEndian(UInt32(MeetingAudioFormat.bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendJournalBigEndian(Int64(4) + frameCount * Int64(MeetingAudioFormat.bytesPerFrame))
        data.appendJournalBigEndian(UInt32(0))  // edit count
        return data
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw errno == ENOSPC ? MeetingJournalError.diskFull : .io(errno: errno)
            }
            offset += written
        }
    }

    public func writeSilence(frames: Int64) throws {
        var remaining = frames * Int64(MeetingAudioFormat.bytesPerFrame)
        while remaining > 0 {
            let count = Int(min(remaining, Int64(zeros.count)))
            try zeros.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            remaining -= Int64(count)
        }
    }

    public func finish() throws {
        guard fsync(descriptor) == 0 else { throw MeetingJournalError.io(errno: errno) }
        Darwin.close(descriptor)
    }

    public func abandon() {
        Darwin.close(descriptor)
        unlink(url.path)
    }
}
