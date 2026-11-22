import AVFoundation
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Meeting capture: channel 0, ring and conversion to 16 kHz")
struct MeetingCaptureConversionTests {
    /// Fills each channel with a 440 Hz tone (amplitude from `amplitudes`).
    private static func fill(_ buffer: AVAudioPCMBuffer, amplitudes: [Float]) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard let data = buffer.floatChannelData else { return }
        for frame in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / rate))
            for channel in 0..<channels {
                let sample = value * amplitudes[channel]
                if buffer.format.isInterleaved {
                    data[0][frame * channels + channel] = sample
                } else {
                    data[channel][frame] = sample
                }
            }
        }
    }

    private static func drain(_ ring: MeetingCaptureRing) async -> [MeetingCapturedBlock] {
        let (stream, continuation) = AsyncStream.makeStream(of: MeetingCapturedBlock.self)
        let pipeline = MeetingTrackPipeline(
            ring: ring, continuation: continuation, timebase: .nanoseconds)
        pipeline.drain()
        pipeline.finish()
        var blocks: [MeetingCapturedBlock] = []
        for await block in stream { blocks.append(block) }
        return blocks
    }

    private static func peak(_ samples: [Int16]) -> Double {
        samples.withUnsafeBufferPointer { MeetingBlockLevels.measure($0) }.peakDBFS
    }

    @Test("48 kHz stereo float, interleaved (the tap format): channel 0 at 16 kHz")
    func stereo48kInterleaved() async throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2,
                interleaved: true))
        let layout = MeetingTapLayout(
            channelCount: 2, isInterleaved: true, isFloat32: true, sampleRate: 48_000)

        for (amplitudes, expectSound) in [([Float(0.5), 0], true), ([0, 0.9], false)] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            Self.fill(buffer, amplitudes: amplitudes)
            let ring = MeetingCaptureRing(slotCount: 8, slotCapacity: 8_192, timebase: .nanoseconds)
            MeetingAudioCallbacks.copyChannelZero(
                from: buffer.audioBufferList, layout: layout, hostTime: 1_000, ring: ring)
            let counters = ring.takeCounters()
            #expect(counters.buffers == 1 && counters.frames == 4_800)

            let blocks = await Self.drain(ring)
            #expect(blocks.count == 1)
            let block = try #require(blocks.first)
            #expect(block.hostTime == 1_000)
            #expect(block.sourceSampleRate == 48_000)
            #expect(abs(block.samples.count - 1_600) <= 32, "\(block.samples.count)")
            if expectSound {
                #expect(Self.peak(block.samples) > -12)
            } else {
                #expect(block.samples.allSatisfy { $0 == 0 })
            }
        }
    }

    @Test("24 kHz mono from the microphone tap block")
    func mono24k() async throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1,
                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
        buffer.frameLength = 2_400
        Self.fill(buffer, amplitudes: [0.5])
        let ring = MeetingCaptureRing(slotCount: 8, slotCapacity: 8_192, timebase: .nanoseconds)
        let block = MeetingAudioCallbacks.microphoneTapBlock(
            ring: ring, channelCount: 1, sampleRate: 24_000)
        block(buffer, AVAudioTime(hostTime: 5_000))
        let blocks = await Self.drain(ring)
        let first = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(first.hostTime == 5_000)
        #expect(first.sourceSampleRate == 24_000)
        #expect(abs(first.samples.count - 1_600) <= 32, "\(first.samples.count)")
        #expect(Self.peak(first.samples) > -12)
    }

    @Test("3-channel input (voice-processing layout): channel 0 is used")
    func threeChannels() async throws {
        let channelLayout = try #require(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24_000, interleaved: false,
            channelLayout: channelLayout)
        #expect(format.channelCount == 3)
        for (amplitudes, expectSound) in [([Float(0.5), 0, 0], true), ([0, 0.7, 0.7], false)] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400))
            buffer.frameLength = 2_400
            Self.fill(buffer, amplitudes: amplitudes)
            let ring = MeetingCaptureRing(slotCount: 8, slotCapacity: 8_192, timebase: .nanoseconds)
            MeetingAudioCallbacks.microphoneTapBlock(
                ring: ring, channelCount: 3, sampleRate: 24_000)(buffer, AVAudioTime(hostTime: 9))
            let blocks = await Self.drain(ring)
            let first = try #require(blocks.first)
            #expect(abs(first.samples.count - 1_600) <= 32)
            if expectSound {
                #expect(Self.peak(first.samples) > -12)
            } else {
                #expect(first.samples.allSatisfy { $0 == 0 })
            }
        }
    }

    @Test("Buffers that follow in time join one block; a rate change starts a new one")
    func joinsAndSplits() async throws {
        let ring = MeetingCaptureRing(slotCount: 8, slotCapacity: 1_024, timebase: .nanoseconds)
        let tone = (0..<2_048).map { Float(sin(Double($0) / 10)) * 0.5 }
        tone.withUnsafeBufferPointer { samples in
            // 2048 frames at 48 kHz split into two slots of 1024.
            ring.writeChannelZero(
                samples.baseAddress!, stride: 1, frameCount: 2_048, hostTime: 0,
                sampleRate: 48_000)
            // Then 24 kHz, right after (42.67 ms later).
            ring.writeChannelZero(
                samples.baseAddress!, stride: 1, frameCount: 960, hostTime: 42_666_667,
                sampleRate: 24_000)
        }
        let blocks = await Self.drain(ring)
        #expect(blocks.count == 2)
        #expect(blocks.first?.sourceSampleRate == 48_000)
        #expect(blocks.last?.sourceSampleRate == 24_000)
        #expect(blocks.last?.hostTime == 42_666_667)
    }

    @Test("A full ring drops the buffer and counts it")
    func fullRingDrops() {
        let ring = MeetingCaptureRing(slotCount: 2, slotCapacity: 16, timebase: .nanoseconds)
        let samples = [Float](repeating: 0.1, count: 16)
        samples.withUnsafeBufferPointer { pointer in
            for index in 0..<3 {
                ring.writeChannelZero(
                    pointer.baseAddress!, stride: 1, frameCount: 16, hostTime: UInt64(index),
                    sampleRate: 16_000)
            }
        }
        let counters = ring.takeCounters()
        #expect(counters.buffers == 3)
        #expect(counters.droppedBuffers == 1)
        #expect(ring.read { _, _, _ in })
        #expect(ring.read { _, _, _ in })
        #expect(!ring.read { _, _, _ in })
    }
}

@Suite("Meeting capture source rules")
struct MeetingCaptureSourceScanTests {
    private static func root(file: StaticString = #filePath) -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path)
        {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    private static func sources(in folder: String) throws -> [(String, String)] {
        let url = root().appending(path: folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map {
            ($0, try String(contentsOf: url.appending(path: $0), encoding: .utf8))
        }
    }

    @Test("The audio callback file has no logging, print, await, mutex, file write or task")
    func callbackFileRules() throws {
        let source = try String(
            contentsOf: Self.root().appending(
                path: "Sources/RafuApp/Meetings/Capture/MeetingAudioCallbacks.swift"),
            encoding: .utf8)
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for forbidden in [
            "Logger", "print(", "os_log", "NSLog", "await", "async", "Mutex", "withLock", "NSLock",
            "os_unfair_lock", "DispatchSemaphore", "FileHandle", "write(to", "Task {", "Task(",
            "actor ", ".append(", "Array(", "Data(", "diagnostics",
        ] {
            #expect(!code.contains(forbidden), "\(forbidden)")
        }
        // Only the ring's init allocates.
        #expect(code.components(separatedBy: ".allocate(").count - 1 == 4)
    }

    @Test("No recording code holds a workspace value")
    func noWorkspaceInRecording() throws {
        let files =
            try Self.sources(in: "Sources/RafuApp/Meetings/Capture")
            + Self.sources(in: "Sources/RafuApp/Meetings/Recorder")
            + Self.sources(in: "Sources/RafuCore/Meetings/Recording")
            + Self.sources(in: "Sources/RafuCore/Meetings/Journal")
        #expect(files.count >= 10)
        for (name, source) in files {
            #expect(!source.contains("WorkspaceSession"), "\(name)")
            #expect(!source.contains("WorkspaceDescriptor"), "\(name)")
            #expect(!source.contains("@unchecked Sendable"), "\(name)")
            #expect(!source.contains("setVoiceProcessingEnabled"), "\(name)")
        }
    }
}
