import Foundation

/// Turns Nemotron 3 frame probabilities into speaker segments while they
/// stream, so the helper never keeps all frame probabilities of a long
/// meeting. The result is the same as FluidAudio's
/// `Nemotron3Diarizer.segments(probabilities:frameCount:numSpeakers:
/// threshold:frameSeconds:minDurationSeconds:)` on the whole list: a frame
/// counts for a speaker slot when its probability is strictly greater than
/// the threshold, contiguous frames are one segment, and a segment shorter
/// than `minimumDurationSeconds` is dropped (Rafu uses 0, as FluidAudio's
/// own benchmark does).
public struct MeetingStreamingSpeakerSegmenter: Sendable {
    public let speakerSlots: Int
    public let threshold: Float
    public let frameSeconds: Double
    public let minimumDurationSeconds: Double

    private var openStart: [Int?]
    private var frameIndex = 0
    private var closed: [MeetingSpeakerSegment] = []

    public init(
        speakerSlots: Int = 8, threshold: Float = 0.5, frameSeconds: Double = 0.01,
        minimumDurationSeconds: Double = 0
    ) {
        self.speakerSlots = speakerSlots
        self.threshold = threshold
        self.frameSeconds = frameSeconds
        self.minimumDurationSeconds = minimumDurationSeconds
        self.openStart = Array(repeating: nil, count: speakerSlots)
    }

    /// Frames seen so far.
    public var frameCount: Int { frameIndex }

    /// Adds `frameCount` frames of `[frames × speakerSlots]` probabilities.
    public mutating func append(probabilities: [Float], frameCount: Int) {
        let frames = min(frameCount, probabilities.count / max(1, speakerSlots))
        for frame in 0..<frames {
            let base = frame * speakerSlots
            for slot in 0..<speakerSlots {
                let active = probabilities[base + slot] > threshold
                if active, openStart[slot] == nil {
                    openStart[slot] = frameIndex
                } else if !active, let start = openStart[slot] {
                    close(slot: slot, start: start, end: frameIndex)
                    openStart[slot] = nil
                }
            }
            frameIndex += 1
        }
    }

    /// Closes the open segments and gives all segments, by start time.
    /// Speaker numbers are slot + 1 (slots are in order of first arrival).
    public mutating func finish() -> [MeetingSpeakerSegment] {
        for slot in 0..<speakerSlots {
            if let start = openStart[slot] {
                close(slot: slot, start: start, end: frameIndex)
                openStart[slot] = nil
            }
        }
        // A stable sort by start keeps the slot order for equal starts,
        // like FluidAudio's per-slot loop followed by its sort.
        return closed.enumerated()
            .sorted { lhs, rhs in
                lhs.element.start == rhs.element.start
                    ? lhs.offset < rhs.offset : lhs.element.start < rhs.element.start
            }
            .map(\.element)
    }

    private mutating func close(slot: Int, start: Int, end: Int) {
        let duration = Double(end - start) * frameSeconds
        guard duration >= minimumDurationSeconds else { return }
        closed.append(
            MeetingSpeakerSegment(
                speaker: slot + 1, start: Double(start) * frameSeconds,
                end: Double(end) * frameSeconds))
    }
}
