import CoreAudio
import RafuCore
import Synchronization

// AUDIO THREAD FILE. Everything that runs inside an audio callback lives in
// this file, and only here. Rules (a source-scan test checks the words):
// no allocation after start, no mutex, no logging, no file write, no
// suspension point and no actor hop. The callback copies channel 0 into a
// preallocated single-producer, single-consumer ring and adds to atomic
// counters. A drain task off the audio thread converts and writes.
//
// The blocks are built in `nonisolated static` functions: a block formed
// inside an isolated type inherits that isolation under Swift 6 and traps
// on the audio thread (`_swift_task_checkIsolatedSwift`, measured in the
// capture check). The ring is not `Sendable`: the source actor owns it and
// is its only reader; the block is its only writer; the two indices are
// atomics (the pattern of `VoicePlaybackRing`).

/// A ring of fixed slots of mono Float32 samples. Each slot holds one
/// callback buffer (or part of a large one), its host time and its rate.
nonisolated final class MeetingCaptureRing {
    let slotCount: Int
    let slotCapacity: Int

    private let samples: UnsafeMutablePointer<Float>
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let frameCounts: UnsafeMutablePointer<Int>
    private let rates: UnsafeMutablePointer<Double>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// Host ticks per second, for the host time of the second part of a
    /// buffer that does not fit in one slot.
    private let ticksPerSecond: Double

    // Callback counters. The callback adds; the drain takes.
    let buffers = Atomic<Int>(0)
    let frames = Atomic<Int>(0)
    let droppedBuffers = Atomic<Int>(0)
    let formatErrors = Atomic<Int>(0)

    /// 256 slots of 8192 frames: about 21 s at 48 kHz with 4096-frame
    /// buffers, 8 MB for each track.
    init(slotCount: Int = 256, slotCapacity: Int = 8_192, timebase: MeetingHostTimebase = .current)
    {
        self.slotCount = slotCount
        self.slotCapacity = slotCapacity
        samples = .allocate(capacity: slotCount * slotCapacity)
        samples.initialize(repeating: 0, count: slotCount * slotCapacity)
        hostTimes = .allocate(capacity: slotCount)
        hostTimes.initialize(repeating: 0, count: slotCount)
        frameCounts = .allocate(capacity: slotCount)
        frameCounts.initialize(repeating: 0, count: slotCount)
        rates = .allocate(capacity: slotCount)
        rates.initialize(repeating: 0, count: slotCount)
        ticksPerSecond = Double(timebase.ticks(seconds: 1))
    }

    deinit {
        samples.deallocate()
        hostTimes.deallocate()
        frameCounts.deallocate()
        rates.deallocate()
    }

    // MARK: Producer (the audio callback only)

    /// Copies `frameCount` frames of channel 0 from `source`, which has
    /// `stride` floats between frames (the channel count when interleaved,
    /// 1 when not). Splits a buffer that is larger than one slot. Drops the
    /// buffer, and counts it, when the ring is full.
    func writeChannelZero(
        _ source: UnsafePointer<Float>, stride: Int, frameCount: Int, hostTime: UInt64,
        sampleRate: Double
    ) {
        buffers.add(1, ordering: .relaxed)
        frames.add(frameCount, ordering: .relaxed)
        var offset = 0
        while offset < frameCount {
            let write = writeIndex.load(ordering: .relaxed)
            let read = readIndex.load(ordering: .acquiring)
            guard write - read < slotCount else {
                droppedBuffers.add(1, ordering: .relaxed)
                return
            }
            let slot = write % slotCount
            let count = min(slotCapacity, frameCount - offset)
            let target = samples + slot * slotCapacity
            var index = 0
            while index < count {
                target[index] = source[(offset + index) * stride]
                index += 1
            }
            let extraTicks = offset == 0 ? 0 : UInt64(Double(offset) / sampleRate * ticksPerSecond)
            hostTimes[slot] = hostTime &+ extraTicks
            frameCounts[slot] = count
            rates[slot] = sampleRate
            writeIndex.store(write + 1, ordering: .releasing)
            offset += count
        }
    }

    // MARK: Consumer (the source actor only)

    /// Reads the oldest slot; returns false when the ring is empty.
    func read(_ body: (UnsafeBufferPointer<Float>, UInt64, Double) -> Void) -> Bool {
        let read = readIndex.load(ordering: .relaxed)
        guard read < writeIndex.load(ordering: .acquiring) else { return false }
        let slot = read % slotCount
        body(
            UnsafeBufferPointer(start: samples + slot * slotCapacity, count: frameCounts[slot]),
            hostTimes[slot], rates[slot])
        readIndex.store(read + 1, ordering: .releasing)
        return true
    }

    /// The callback counters since the last call.
    func takeCounters() -> MeetingCallbackCounters {
        MeetingCallbackCounters(
            buffers: buffers.exchange(0, ordering: .relaxed),
            frames: frames.exchange(0, ordering: .relaxed),
            droppedBuffers: droppedBuffers.exchange(0, ordering: .relaxed),
            converterErrors: formatErrors.exchange(0, ordering: .relaxed))
    }
}

/// The layout of a device's input buffers (the call-audio tap or the
/// microphone), read once before start.
nonisolated struct MeetingTapLayout: Sendable {
    var channelCount: Int
    var isInterleaved: Bool
    var isFloat32: Bool
    var sampleRate: Double
}

/// Builds the audio callbacks outside any actor.
nonisolated enum MeetingAudioCallbacks {
    /// The IO block of a Core Audio device: the call-audio aggregate device
    /// ("Them") and the input device ("Me"). Reads the input AudioBufferList
    /// in place (no `AVAudioPCMBuffer` per callback) and writes only silence
    /// to the output list: a device with input and output streams (a USB
    /// headset) gives this block its output buffers too.
    static func deviceIOBlock(ring: MeetingCaptureRing, layout: MeetingTapLayout)
        -> AudioDeviceIOBlock
    {
        { _, inputData, inputTime, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            copyChannelZero(
                from: inputData, layout: layout, hostTime: inputTime.pointee.mHostTime,
                ring: ring)
        }
    }

    /// Copies channel 0 of an AudioBufferList into the ring. Shared by the
    /// device IO block and the converter test.
    static func copyChannelZero(
        from list: UnsafePointer<AudioBufferList>, layout: MeetingTapLayout, hostTime: UInt64,
        ring: MeetingCaptureRing
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard layout.isFloat32, buffers.count > 0, let data = buffers[0].mData else {
            ring.formatErrors.add(1, ordering: .relaxed)
            return
        }
        // The buffer states its own channel count: correct for interleaved
        // and non-interleaved buffers even if the stream changed after start.
        let stride = max(1, Int(buffers[0].mNumberChannels))
        let bytesPerFrame = MemoryLayout<Float>.size * stride
        let frameCount = Int(buffers[0].mDataByteSize) / bytesPerFrame
        guard frameCount > 0 else { return }
        ring.writeChannelZero(
            data.assumingMemoryBound(to: Float.self), stride: stride, frameCount: frameCount,
            hostTime: hostTime, sampleRate: layout.sampleRate)
    }
}
