import Foundation

/// Audio format facts and level math for GPT-Live (Phase 0 report): mono
/// PCM16 little-endian at 24 kHz, 20 ms input frames, 100 ms output deltas.
public nonisolated enum VoiceAudioFormat {
    public static let sampleRate = 24_000.0
    public static let inputFrameSamples = 480
    public static let inputFrameBytes = inputFrameSamples * 2
    /// The server streams real zero samples for silence; above this RMS a
    /// delta holds audible speech (Phase 0 value).
    public static let audibleOutputRMS = 150.0
    /// Local speech on the converted microphone signal. Higher than the
    /// output value so room noise does not count; three frames in a row
    /// (60 ms) are needed before a reply is cut.
    public static let localSpeechRMS = 600.0
    public static let localSpeechFrames = 3
}

public nonisolated enum VoiceAudioLevel {
    /// Root mean square of little-endian Int16 samples; 0 for empty input.
    public static func rms(pcm16 data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                let sample = Double(Int16(bitPattern: low | high << 8))
                sum += sample * sample
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    /// 0…1 for a meter: 20·log10 scaled over a 50 dB range.
    public static func meterLevel(rms: Double) -> Double {
        guard rms > 1 else { return 0 }
        let decibels = 20 * log10(rms / 32_768)
        return min(1, max(0, (decibels + 50) / 50))
    }
}
