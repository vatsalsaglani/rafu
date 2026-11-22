import Foundation

/// One live audio frame on the helper's standard input: 1 byte track
/// (0 = me, 1 = them), 8 bytes meeting-clock time of the first sample
/// (a little-endian `Double`), 4 bytes sample count (little-endian
/// `UInt32`), then that many Int16 little-endian samples at 16 kHz.
public struct MeetingWorkerFrame: Equatable, Sendable {
    public var track: MeetingTrack
    public var startTime: Double
    /// Int16 little-endian samples.
    public var samples: Data

    public init(track: MeetingTrack, startTime: Double, samples: Data) {
        self.track = track
        self.startTime = startTime
        self.samples = samples
    }

    public init(chunk: MeetingAudioChunk) {
        self.init(track: chunk.track, startTime: chunk.startTime, samples: chunk.samples)
    }

    public var sampleCount: Int { samples.count / MeetingAudioFormat.bytesPerFrame }

    static func trackByte(_ track: MeetingTrack) -> UInt8 {
        switch track {
        case .me: 0
        case .them: 1
        }
    }

    /// The frame on the wire. A frame longer than 1 s must be split first
    /// (`split(_:)`).
    public func encoded() -> Data {
        var data = Data(capacity: MeetingWorkerProtocol.frameHeaderBytes + samples.count)
        data.append(Self.trackByte(track))
        withUnsafeBytes(of: startTime.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleCount).littleEndian) { data.append(contentsOf: $0) }
        data.append(samples.prefix(sampleCount * MeetingAudioFormat.bytesPerFrame))
        return data
    }

    /// Splits an audio chunk into frames of at most 1 s, each with the
    /// meeting-clock time of its own first sample.
    public static func split(_ chunk: MeetingAudioChunk) -> [MeetingWorkerFrame] {
        let bytesPerFrame = MeetingAudioFormat.bytesPerFrame
        let total = chunk.samples.count / bytesPerFrame
        guard total > 0 else { return [] }
        var frames: [MeetingWorkerFrame] = []
        var offset = 0
        while offset < total {
            let count = min(MeetingWorkerProtocol.maximumFrameSamples, total - offset)
            let start = chunk.samples.startIndex + offset * bytesPerFrame
            let bytes = chunk.samples[start..<(start + count * bytesPerFrame)]
            frames.append(
                MeetingWorkerFrame(
                    track: chunk.track,
                    startTime: chunk.startTime + Double(offset) / MeetingAudioFormat.sampleRate,
                    samples: Data(bytes)))
            offset += count
        }
        return frames
    }
}

/// Why a frame stream was refused.
public enum MeetingWorkerFrameError: Error, Equatable, Sendable {
    case unknownTrack
    case tooManySamples
    case badTime
}

/// Reads frames from a byte stream that can split anywhere, also inside a
/// header.
public struct MeetingWorkerFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Bytes not yet part of a whole frame.
    public var pendingByteCount: Int { buffer.count }

    public mutating func append(_ bytes: Data) throws(MeetingWorkerFrameError)
        -> [MeetingWorkerFrame]
    {
        buffer.append(bytes)
        var frames: [MeetingWorkerFrame] = []
        var cursor = buffer.startIndex
        let header = MeetingWorkerProtocol.frameHeaderBytes
        while buffer.endIndex - cursor >= header {
            let trackByte = buffer[cursor]
            let track: MeetingTrack
            switch trackByte {
            case 0: track = .me
            case 1: track = .them
            default: throw .unknownTrack
            }
            var timeBits: UInt64 = 0
            for index in 0..<8 {
                timeBits |= UInt64(buffer[cursor + 1 + index]) << (8 * UInt64(index))
            }
            var count: UInt32 = 0
            for index in 0..<4 {
                count |= UInt32(buffer[cursor + 9 + index]) << (8 * UInt32(index))
            }
            guard count <= MeetingWorkerProtocol.maximumFrameSamples else { throw .tooManySamples }
            let time = Double(bitPattern: timeBits)
            guard time.isFinite, time >= 0 else { throw .badTime }
            let sampleBytes = Int(count) * MeetingAudioFormat.bytesPerFrame
            guard buffer.endIndex - cursor >= header + sampleBytes else { break }
            let start = cursor + header
            frames.append(
                MeetingWorkerFrame(
                    track: track, startTime: time,
                    samples: Data(buffer[start..<(start + sampleBytes)])))
            cursor = start + sampleBytes
        }
        if cursor > buffer.startIndex {
            buffer = Data(buffer[cursor...])
        }
        return frames
    }
}

/// Splits a byte stream into lines (newline removed), and refuses a line
/// longer than `maximumBytes`.
public struct MeetingWorkerLineSplitter: Sendable {
    public let maximumBytes: Int
    private var buffer = Data()

    public init(maximumBytes: Int = MeetingWorkerProtocol.maximumLineBytes) {
        self.maximumBytes = maximumBytes
    }

    /// Bytes after the last newline.
    public var pendingBytes: Data { buffer }

    public mutating func append(_ bytes: Data) throws(MeetingWorkerLineError) -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        var cursor = buffer.startIndex
        while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
            let line = buffer[cursor..<newline]
            guard line.count <= maximumBytes else { throw .oversize }
            lines.append(Data(line))
            cursor = buffer.index(after: newline)
        }
        if cursor > buffer.startIndex {
            buffer = Data(buffer[cursor...])
        }
        guard buffer.count <= maximumBytes else { throw .oversize }
        return lines
    }
}
