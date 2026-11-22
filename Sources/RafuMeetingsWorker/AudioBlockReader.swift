// Reads a stored track in bounded blocks as 16 kHz mono Float samples, so a
// 2-hour file is never in memory at once (except where an engine needs the
// whole array, which its job says).
import AVFoundation
import Foundation

enum AudioBlockReaderError: Error {
    case cannotOpen
    case cannotConvert
}

/// Not `Sendable`: make, use and drop it in one function.
final class AudioBlockReader {
    static let sampleRate: Double = 16_000

    private let file: AVAudioFile
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inputBuffer: AVAudioPCMBuffer
    private var inputFinished = false
    /// Samples given so far.
    private(set) var samplesRead = 0

    /// The length of the file in seconds.
    let durationSeconds: Double

    init(path: String, inputBlockFrames: AVAudioFrameCount = 32_768) throws {
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        } catch {
            throw AudioBlockReaderError.cannotOpen
        }
        let source = file.processingFormat
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
                interleaved: false),
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputBlockFrames)
        else { throw AudioBlockReaderError.cannotConvert }
        targetFormat = target
        inputBuffer = input
        if source.sampleRate == Self.sampleRate, source.channelCount == 1,
            source.commonFormat == .pcmFormatFloat32
        {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: source, to: target) else {
                throw AudioBlockReaderError.cannotConvert
            }
            converter = made
        }
        durationSeconds = source.sampleRate > 0 ? Double(file.length) / source.sampleRate : 0
    }

    /// Up to `maximumSamples` samples, or nil at the end of the file.
    func next(maximumSamples: Int) throws -> [Float]? {
        guard let converter else { return try readDirect(maximumSamples: maximumSamples) }
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(maximumSamples))
        else { throw AudioBlockReaderError.cannotConvert }
        var failure: (any Error)?
        let status = converter.convert(to: output, error: nil) { [self] _, statusPointer in
            if inputFinished {
                statusPointer.pointee = .endOfStream
                return nil
            }
            // `AVAudioFile.read(into:)` throws at the end of the file
            // instead of giving 0 frames, so check the position first.
            if file.framePosition >= file.length {
                inputFinished = true
                statusPointer.pointee = .endOfStream
                return nil
            }
            do {
                inputBuffer.frameLength = 0
                try file.read(into: inputBuffer)
            } catch {
                failure = error
                inputFinished = true
                statusPointer.pointee = .endOfStream
                return nil
            }
            if inputBuffer.frameLength == 0 {
                inputFinished = true
                statusPointer.pointee = .endOfStream
                return nil
            }
            statusPointer.pointee = .haveData
            return inputBuffer
        }
        if failure != nil || status == .error { throw AudioBlockReaderError.cannotConvert }
        let count = Int(output.frameLength)
        guard count > 0, let channel = output.floatChannelData?[0] else { return nil }
        samplesRead += count
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private func readDirect(maximumSamples: Int) throws -> [Float]? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(maximumSamples))
        else { throw AudioBlockReaderError.cannotConvert }
        guard file.framePosition < file.length else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            throw AudioBlockReaderError.cannotConvert
        }
        let count = Int(buffer.frameLength)
        guard count > 0, let channel = buffer.floatChannelData?[0] else { return nil }
        samplesRead += count
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    /// Fraction of the file read so far.
    var fractionRead: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, Double(samplesRead) / Self.sampleRate / durationSeconds)
    }
}

/// A 16 kHz mono Float buffer for FluidAudio's streaming manager.
func makePCMBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
    guard
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioBlockReader.sampleRate, channels: 1,
            interleaved: false),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let channel = buffer.floatChannelData?[0] {
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
    }
    return buffer
}

/// Int16 little-endian samples as Float in [-1, 1].
func floatSamples(fromInt16 data: Data) -> [Float] {
    let count = data.count / 2
    var samples = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
        for index in 0..<count {
            let low = UInt16(raw[index * 2])
            let high = UInt16(raw[index * 2 + 1])
            samples[index] = Float(Int16(bitPattern: low | (high << 8))) / 32_768
        }
    }
    return samples
}
