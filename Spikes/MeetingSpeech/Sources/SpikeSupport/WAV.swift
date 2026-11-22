// Reads a PCM WAV file to 16 kHz mono Float samples in [-1, 1]. Throw-away
// spike code; see .rafu/plans/meeting-speech-spike.md. Supports 16-bit and
// 32-bit float PCM; mixes multi-channel down by averaging; resamples with
// linear interpolation if the file's rate is not 16 kHz (the test-set
// generator writes 16 kHz mono already, so this is a safety net, not the
// common path).
import Foundation

public enum WAVError: Error, CustomStringConvertible {
    case notRIFF
    case notWAVE
    case missingFormatChunk
    case missingDataChunk
    case unsupportedFormat(UInt16, UInt16)

    public var description: String {
        switch self {
        case .notRIFF: return "not a RIFF file"
        case .notWAVE: return "not a WAVE file"
        case .missingFormatChunk: return "missing fmt chunk"
        case .missingDataChunk: return "missing data chunk"
        case .unsupportedFormat(let tag, let bits): return "unsupported format tag \(tag) at \(bits) bits"
        }
    }
}

public enum WAV {
    public static func readMono16k(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count >= 12 else { throw WAVError.notRIFF }
        guard data[0..<4].elementsEqual("RIFF".utf8) else { throw WAVError.notRIFF }
        guard data[8..<12].elementsEqual("WAVE".utf8) else { throw WAVError.notWAVE }

        var offset = 12
        var sampleRate: UInt32 = 0
        var channels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var formatTag: UInt16 = 0
        var samples: [Float] = []
        var sawFormat = false
        var sawData = false

        while offset + 8 <= data.count {
            let chunkID = data[offset..<offset + 4]
            let chunkSize = Int(readUInt32LE(data, offset + 4))
            let chunkStart = offset + 8
            guard chunkStart + chunkSize <= data.count else { break }

            if chunkID.elementsEqual("fmt ".utf8) {
                formatTag = readUInt16LE(data, chunkStart)
                channels = readUInt16LE(data, chunkStart + 2)
                sampleRate = readUInt32LE(data, chunkStart + 4)
                bitsPerSample = readUInt16LE(data, chunkStart + 14)
                sawFormat = true
            } else if chunkID.elementsEqual("data".utf8) {
                samples = try decodeSamples(
                    data[chunkStart..<chunkStart + chunkSize], formatTag: formatTag,
                    channels: channels, bitsPerSample: bitsPerSample
                )
                sawData = true
            }

            offset = chunkStart + chunkSize + (chunkSize % 2) // chunks are word-aligned
        }

        guard sawFormat else { throw WAVError.missingFormatChunk }
        guard sawData else { throw WAVError.missingDataChunk }

        if sampleRate != 16000 {
            return resample(samples, from: Double(sampleRate), to: 16000)
        }
        return samples
    }

    private static func decodeSamples(
        _ bytes: Data, formatTag: UInt16, channels: UInt16, bitsPerSample: UInt16
    ) throws -> [Float] {
        let channelCount = max(1, Int(channels))
        var mono: [Float] = []
        let byteCount = bytes.count
        let bytesArray = [UInt8](bytes)

        switch (formatTag, bitsPerSample) {
        case (1, 16): // PCM int16
            let frameBytes = 2 * channelCount
            let frameCount = byteCount / frameBytes
            mono.reserveCapacity(frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    let base = frame * frameBytes + ch * 2
                    let raw = Int16(bitPattern: UInt16(bytesArray[base]) | (UInt16(bytesArray[base + 1]) << 8))
                    sum += Float(raw) / 32768.0
                }
                mono.append(sum / Float(channelCount))
            }
        case (3, 32): // IEEE float32
            let frameBytes = 4 * channelCount
            let frameCount = byteCount / frameBytes
            mono.reserveCapacity(frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    let base = frame * frameBytes + ch * 4
                    let bits = UInt32(bytesArray[base]) | (UInt32(bytesArray[base + 1]) << 8)
                        | (UInt32(bytesArray[base + 2]) << 16) | (UInt32(bytesArray[base + 3]) << 24)
                    sum += Float(bitPattern: bits)
                }
                mono.append(sum / Float(channelCount))
            }
        default:
            throw WAVError.unsupportedFormat(formatTag, bitsPerSample)
        }
        return mono
    }

    private static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, !samples.isEmpty else { return samples }
        let ratio = to / from
        let outCount = Int(Double(samples.count) * ratio)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let lower = Int(srcPos)
            let frac = Float(srcPos - Double(lower))
            if lower + 1 < samples.count {
                out[i] = samples[lower] * (1 - frac) + samples[lower + 1] * frac
            } else if lower < samples.count {
                out[i] = samples[lower]
            }
        }
        return out
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
