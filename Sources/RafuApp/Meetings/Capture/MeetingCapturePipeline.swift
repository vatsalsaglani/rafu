import AVFoundation
import RafuCore

/// Converts mono Float32 audio at any device rate to the analyzer format
/// (16 kHz mono Int16, CHECKED in the capture check). Runs off the audio
/// thread; it is made again when the device rate changes.
nonisolated final class MeetingPCMConverter {
    static let pieceFrames = 1_024

    let inputRate: Double
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    init?(inputRate: Double, maximumInputFrames: Int = 8_192) {
        guard inputRate > 0,
            let inFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1,
                interleaved: false),
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: MeetingAudioFormat.sampleRate,
                channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let input = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(maximumInputFrames)),
            let output = AVAudioPCMBuffer(
                pcmFormat: outFormat,
                frameCapacity: AVAudioFrameCount(
                    Double(maximumInputFrames) * MeetingAudioFormat.sampleRate / inputRate) + 64)
        else { return nil }
        converter.primeMethod = .none
        self.inputRate = inputRate
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// Converts one block of mono samples; appends the result to `into`.
    /// Returns false on a converter error.
    func convert(_ samples: UnsafeBufferPointer<Float>, into result: inout [Int16]) -> Bool {
        var offset = 0
        while offset < samples.count {
            // One call takes at most 4096 input frames and drops the rest
            // (measured: 4800 frames at 48 kHz gave 1365 frames, 4096 / 3),
            // so feed small pieces.
            let count = min(Self.pieceFrames, Int(input.frameCapacity), samples.count - offset)
            guard let target = input.floatChannelData?[0], let base = samples.baseAddress else {
                return false
            }
            target.update(from: base + offset, count: count)
            input.frameLength = AVAudioFrameCount(count)
            output.frameLength = 0
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [input] _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, let converted = output.int16ChannelData?[0] else {
                return false
            }
            result.append(
                contentsOf: UnsafeBufferPointer(start: converted, count: Int(output.frameLength)))
            offset += count
        }
        return true
    }
}

/// The drain side of one track: reads the ring, converts, and yields
/// blocks. Consecutive slots that follow each other in time are joined
/// into one block (about 20 blocks a second at a 50 ms drain interval).
/// Owned by one source actor; not `Sendable`.
nonisolated final class MeetingTrackPipeline {
    let ring: MeetingCaptureRing
    private let continuation: AsyncStream<MeetingCapturedBlock>.Continuation
    private let timebase: MeetingHostTimebase
    private var converter: MeetingPCMConverter?
    private(set) var converterErrors = 0

    init(
        ring: MeetingCaptureRing, continuation: AsyncStream<MeetingCapturedBlock>.Continuation,
        timebase: MeetingHostTimebase = .current
    ) {
        self.ring = ring
        self.continuation = continuation
        self.timebase = timebase
    }

    /// Reads every waiting slot. Returns the number of blocks yielded.
    @discardableResult
    func drain() -> Int {
        var yielded = 0
        var pending: [Int16] = []
        var pendingHostTime: UInt64 = 0
        var pendingRate = 0.0
        var expectedNextHostTime: UInt64?
        let tolerance = UInt64(max(0, timebase.ticks(seconds: 0.01)))

        func emit() {
            guard !pending.isEmpty else { return }
            continuation.yield(
                MeetingCapturedBlock(
                    hostTime: pendingHostTime, samples: pending, sourceSampleRate: pendingRate))
            yielded += 1
            pending = []
        }

        while ring.read({ samples, hostTime, rate in
            let follows =
                expectedNextHostTime.map {
                    rate == pendingRate
                        && (hostTime > $0 ? hostTime - $0 : $0 - hostTime) <= tolerance
                } ?? false
            if !follows {
                emit()
                pendingHostTime = hostTime
                pendingRate = rate
            }
            if converter?.inputRate != rate {
                converter = MeetingPCMConverter(inputRate: rate)
            }
            if let converter, converter.convert(samples, into: &pending) {
                // converted
            } else {
                converterErrors += 1
            }
            let duration = UInt64(max(0, timebase.ticks(seconds: Double(samples.count) / rate)))
            expectedNextHostTime = hostTime &+ duration
        }) {}
        emit()
        return yielded
    }

    func finish() {
        continuation.finish()
    }

    /// Callback counters plus the drain's converter errors, since the last
    /// call.
    func takeCounters() -> MeetingCallbackCounters {
        var counters = ring.takeCounters()
        counters.converterErrors += converterErrors
        converterErrors = 0
        return counters
    }
}
