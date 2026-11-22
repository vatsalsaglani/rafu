import Foundation

/// CRC-32 (IEEE 802.3, the zlib polynomial), for journal segments.
public enum MeetingCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    public static func checksum(_ bytes: UnsafeRawBufferPointer, seed: UInt32 = 0) -> UInt32 {
        var crc = ~seed
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    public static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { checksum($0, seed: seed) }
    }
}

/// The header of one journal segment: a fixed 40-byte little-endian block
/// in front of the 16 kHz mono Int16 samples.
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 4 | magic `RMJ1` |
/// | 4 | 1 | track (0 = me, 1 = them) |
/// | 5 | 3 | zero |
/// | 8 | 4 | segment index |
/// | 12 | 8 | meeting-clock seconds of the first sample (Float64 bits) |
/// | 20 | 4 | sample rate (16000) |
/// | 24 | 4 | frame count |
/// | 28 | 4 | CRC-32 of the samples |
/// | 32 | 4 | zero |
/// | 36 | 4 | CRC-32 of bytes 0 to 35 |
public struct MeetingJournalSegmentHeader: Hashable, Sendable {
    public static let size = 40
    public static let magic: [UInt8] = Array("RMJ1".utf8)

    public var track: MeetingTrack
    public var index: UInt32
    public var startTime: TimeInterval
    public var sampleRate: UInt32
    public var frameCount: UInt32
    public var payloadChecksum: UInt32

    public init(
        track: MeetingTrack, index: UInt32, startTime: TimeInterval,
        sampleRate: UInt32 = UInt32(MeetingAudioFormat.sampleRate), frameCount: UInt32,
        payloadChecksum: UInt32
    ) {
        self.track = track
        self.index = index
        self.startTime = startTime
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.payloadChecksum = payloadChecksum
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.append(contentsOf: Self.magic)
        data.append(track == .me ? 0 : 1)
        data.append(contentsOf: [0, 0, 0])
        data.appendJournalLittleEndian(index)
        data.appendJournalLittleEndian(startTime.bitPattern)
        data.appendJournalLittleEndian(sampleRate)
        data.appendJournalLittleEndian(frameCount)
        data.appendJournalLittleEndian(payloadChecksum)
        data.appendJournalLittleEndian(UInt32(0))
        data.appendJournalLittleEndian(MeetingCRC32.checksum(data))
        return data
    }

    /// Decodes and checks a header; nil when it is damaged.
    public static func decode(_ data: Data) -> MeetingJournalSegmentHeader? {
        guard data.count >= size else { return nil }
        let bytes = [UInt8](data.prefix(size))
        guard Array(bytes[0..<4]) == magic else { return nil }
        let stored = bytes.readJournalLittleEndian(UInt32.self, at: 36)
        let computed = bytes[0..<36].withUnsafeBytes { MeetingCRC32.checksum($0) }
        guard stored == computed else { return nil }
        let track: MeetingTrack
        switch bytes[4] {
        case 0: track = .me
        case 1: track = .them
        default: return nil
        }
        return MeetingJournalSegmentHeader(
            track: track,
            index: bytes.readJournalLittleEndian(UInt32.self, at: 8),
            startTime: Double(bitPattern: bytes.readJournalLittleEndian(UInt64.self, at: 12)),
            sampleRate: bytes.readJournalLittleEndian(UInt32.self, at: 20),
            frameCount: bytes.readJournalLittleEndian(UInt32.self, at: 24),
            payloadChecksum: bytes.readJournalLittleEndian(UInt32.self, at: 28))
    }
}

/// The layout of a meeting's audio folder.
///
/// ```
/// <audio folder>/
///   journal/
///     index.json
///     me/000001.seg …
///     them/000001.seg …
///   me.caf          (made at Stop or by recovery)
///   them.caf
///   recording.json  (MeetingRecordingFacts)
/// ```
public enum MeetingJournalLayout {
    public static let journalFolderName = "journal"
    public static let indexFileName = "index.json"
    public static let segmentExtension = "seg"
    public static let partialExtension = "partial"

    public static func journalFolder(in audioFolder: URL) -> URL {
        audioFolder.appending(path: journalFolderName, directoryHint: .isDirectory)
    }

    public static func trackFolder(_ track: MeetingTrack, in audioFolder: URL) -> URL {
        journalFolder(in: audioFolder).appending(path: track.rawValue, directoryHint: .isDirectory)
    }

    public static func segmentName(_ index: UInt32) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits + "."
            + segmentExtension
    }

    /// The final audio file of a track: `<track>.caf`.
    public static func finalAudioFile(_ track: MeetingTrack, in audioFolder: URL) -> URL {
        audioFolder.appending(path: "\(track.rawValue).caf")
    }
}

/// The journal index: written atomically at each segment end. Recovery
/// trusts the segments, not the index; the index tells what the writer had
/// confirmed.
public struct MeetingJournalIndex: Hashable, Codable, Sendable {
    public var version: Int
    /// The number of the last segment that was synced, for each track.
    public var lastSyncedSegment: [MeetingTrack: UInt32]
    public var syncedFrames: [MeetingTrack: Int64]

    public init(
        version: Int = 1, lastSyncedSegment: [MeetingTrack: UInt32] = [:],
        syncedFrames: [MeetingTrack: Int64] = [:]
    ) {
        self.version = version
        self.lastSyncedSegment = lastSyncedSegment
        self.syncedFrames = syncedFrames
    }
}

extension Data {
    mutating func appendJournalLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendJournalBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension Array where Element == UInt8 {
    func readJournalLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(self[offset + index]) << (8 * index)
        }
        return value
    }
}
