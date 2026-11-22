// Builds an AVAudioPCMBuffer (16 kHz mono Float32) from plain samples, for
// feeding FluidAudio's streaming managers. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.
import AVFoundation

public enum PCMBuffer {
    public static func make(from samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { pointer in
            channelData[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
