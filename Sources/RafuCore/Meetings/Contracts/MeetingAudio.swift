import Foundation

/// The one audio format that capture hands to speech: 16 kHz, mono,
/// signed 16-bit little-endian integers. Both Apple speech and the helper
/// read it.
public enum MeetingAudioFormat {
    public static let sampleRate: Double = 16_000
    public static let channelCount: Int = 1
    public static let bitsPerSample: Int = 16
    public static let bytesPerFrame: Int = 2
}

/// One block of converted audio from one track.
public struct MeetingAudioChunk: Hashable, Sendable {
    public var track: MeetingTrack
    /// `frameCount` samples in `MeetingAudioFormat` (Int16, little-endian).
    public var samples: Data
    /// Seconds on the meeting clock of the first sample.
    public var startTime: TimeInterval
    public var frameCount: Int

    public init(track: MeetingTrack, samples: Data, startTime: TimeInterval, frameCount: Int) {
        self.track = track
        self.samples = samples
        self.startTime = startTime
        self.frameCount = frameCount
    }

    /// The length of this chunk in seconds.
    public var duration: TimeInterval {
        Double(frameCount) / MeetingAudioFormat.sampleRate
    }

    /// True when the byte count matches the frame count.
    public var isWellFormed: Bool {
        frameCount >= 0 && samples.count == frameCount * MeetingAudioFormat.bytesPerFrame
    }
}
