import AVFoundation
import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Regression: with voice processing on (macOS 27), the input node has 9
/// channels, and an `AVAudioConverter` from that format writes only zeros.
/// GPT-Live then heard silence and never replied.
@Suite("Voice capture framer")
struct VoiceCaptureFramerTests {
    @Test(
        "A tone on channel 0 of a multichannel tap buffer reaches the frames",
        arguments: [1, 2, 9] as [AVAudioChannelCount])
    func multichannelToneIsNotSilent(channels: AVAudioChannelCount) async throws {
        let inputRate = 48_000.0
        // More than 2 channels needs an explicit layout, as the voice
        // processing input node has.
        let layout = try #require(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let tap = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, interleaved: false,
            channelLayout: layout)
        let mono = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1,
                interleaved: false))
        let output = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: VoiceAudioFormat.sampleRate,
                channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: mono, to: output))
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .unbounded)
        let framer = VoiceCaptureFramer(
            converter: converter, monoFormat: mono, outputFormat: output,
            continuation: continuation)

        // 200 ms of a 440 Hz tone at 0.25 on every channel, in 4 tap buffers.
        let length: AVAudioFrameCount = 2_400
        var phase = 0
        for _ in 0..<4 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: length))
            buffer.frameLength = length
            let data = try #require(buffer.floatChannelData)
            for index in 0..<Int(length) {
                let sample = Float(0.25 * sin(2 * Double.pi * 440 * Double(phase) / inputRate))
                for channel in 0..<Int(channels) { data[channel][index] = sample }
                phase += 1
            }
            framer.consume(buffer)
        }
        continuation.finish()

        var frames: [Data] = []
        for await frame in stream { frames.append(frame) }
        #expect(frames.count >= 8)
        #expect(frames.allSatisfy { $0.count == VoiceAudioFormat.inputFrameSamples * 2 })
        let loudest = frames.map { VoiceAudioLevel.rms(pcm16: $0) }.max() ?? 0
        // A 0.25 sine is about 5,800 RMS in PCM16; zeros would be 0.
        #expect(loudest > VoiceAudioFormat.localSpeechRMS)
    }
}
