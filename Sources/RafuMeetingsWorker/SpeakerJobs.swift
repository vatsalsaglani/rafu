// Speakers of the "Them" track after Stop: Nemotron 3 (`fast32`, the
// engine's own segmentation) or SpeakerKit (automatic speaker count). No
// speaker embedding and no audio is written anywhere.
import FluidAudio
import Foundation
import RafuCore
import SpeakerKit
import Synchronization

/// Nemotron 3 speakers. `Nemotron3Models` and `Nemotron3Diarizer` are not
/// `Sendable`: they are made, used and dropped in this one function. The
/// file is read in 10 s blocks through the diarizer's streaming path
/// (frame-exact with `processComplete`), and the frame probabilities are
/// turned into segments as they come, so they are never all kept.
nonisolated func runNemotron3Speakers(
    _ request: MeetingWorkerRequest, audioFile: String, output: WorkerOutput
) async -> MeetingWorkerExitCode {
    output.send(.preparing)
    let loadStart = ContinuousClock.now
    let config = Nemotron3Config.fast32
    let models: Nemotron3Models
    do {
        models = try await Nemotron3Models.load(
            config: config, directory: URL(fileURLWithPath: request.modelFolder, isDirectory: true),
            computeUnits: .all)
    } catch {
        output.fail(.model, code: 1, exit: .engineError)
    }
    let diarizer = Nemotron3Diarizer(config: config, models: models)
    let loadMs = Int(milliseconds(ContinuousClock.now - loadStart).rounded())
    output.send(
        .ready(loadMilliseconds: loadMs, cold: loadMs >= MeetingWorkerEvent.coldLoadMilliseconds))

    let reader: AudioBlockReader
    do {
        reader = try AudioBlockReader(path: audioFile)
    } catch {
        output.fail(.audio, code: 1, exit: .badRequest)
    }
    var segmenter = MeetingStreamingSpeakerSegmenter(
        speakerSlots: config.numSpeakers, threshold: 0.5,
        frameSeconds: Double(config.outputFrameSeconds), minimumDurationSeconds: 0)
    var lastProgress = 0.0
    do {
        diarizer.reset()
        while let samples = try reader.next(maximumSamples: 160_000) {
            diarizer.appendAudio(samples)
            for result in try diarizer.processBufferedAudio() {
                segmenter.append(probabilities: result.probabilities, frameCount: result.frameCount)
            }
            let fraction = reader.fractionRead
            if fraction - lastProgress >= 0.01 {
                output.send(.progress(fraction: fraction))
                lastProgress = fraction
            }
        }
        for result in try diarizer.finishStream() {
            segmenter.append(probabilities: result.probabilities, frameCount: result.frameCount)
        }
    } catch is AudioBlockReaderError {
        output.fail(.audio, code: 2, exit: .engineError)
    } catch {
        output.fail(.engine, code: 2, exit: .engineError)
    }
    let offset = request.clockOffsetSeconds
    let segments = segmenter.finish().map {
        MeetingSpeakerSegment(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset)
    }
    output.send(.segments(segments))
    output.send(.progress(fraction: 1))
    output.send(
        .stats(
            peakFootprintBytes: memoryFootprint().peak, chunkP50Milliseconds: nil,
            chunkP95Milliseconds: nil))
    output.send(.done(audioSeconds: Double(reader.samplesRead) / AudioBlockReader.sampleRate))
    return .done
}

/// SpeakerKit speakers with the automatic speaker count. SpeakerKit has no
/// streaming form: it takes the whole track as one array (about 230 MB of
/// samples for one hour), so its memory grows with the meeting length.
nonisolated func runSpeakerKitSpeakers(
    _ request: MeetingWorkerRequest, audioFile: String, output: WorkerOutput
) async -> MeetingWorkerExitCode {
    output.send(.preparing)
    let loadStart = ContinuousClock.now
    let speakerKit: SpeakerKit
    do {
        // `download: false`: the model folder is the only source.
        let config = PyannoteConfig(
            modelFolder: request.modelFolder, download: false, load: true, verbose: false)
        speakerKit = try await SpeakerKit(config)
    } catch {
        output.fail(.model, code: 1, exit: .engineError)
    }
    let loadMs = Int(milliseconds(ContinuousClock.now - loadStart).rounded())
    output.send(
        .ready(loadMilliseconds: loadMs, cold: loadMs >= MeetingWorkerEvent.coldLoadMilliseconds))

    var audio: [Float] = []
    do {
        let reader = try AudioBlockReader(path: audioFile)
        audio.reserveCapacity(Int(reader.durationSeconds * AudioBlockReader.sampleRate) + 16_000)
        while let samples = try reader.next(maximumSamples: 160_000) {
            audio.append(contentsOf: samples)
        }
    } catch {
        output.fail(.audio, code: 1, exit: .badRequest)
    }
    let audioSeconds = Double(audio.count) / AudioBlockReader.sampleRate
    let offset = request.clockOffsetSeconds
    let segments: [MeetingSpeakerSegment]
    // One progress line for each 1 % step at most.
    let lastProgress = Mutex(0.0)
    do {
        let result = try await speakerKit.diarize(
            audioArray: audio, options: PyannoteDiarizationOptions(numberOfSpeakers: nil),
            progressCallback: { progress in
                let fraction = progress.fractionCompleted
                let step = lastProgress.withLock { last -> Bool in
                    guard fraction - last >= 0.01 else { return false }
                    last = fraction
                    return true
                }
                if step { output.send(.progress(fraction: fraction)) }
            })
        segments = result.segments.compactMap { segment -> MeetingSpeakerSegment? in
            guard let id = segment.speaker.speakerId ?? segment.speaker.speakerIds.first else {
                return nil
            }
            return MeetingSpeakerSegment(
                speaker: id + 1, start: Double(segment.startTime) + offset,
                end: Double(segment.endTime) + offset)
        }.sorted { $0.start < $1.start }
    } catch {
        output.fail(.engine, code: 2, exit: .engineError)
    }
    output.send(.segments(segments))
    output.send(.progress(fraction: 1))
    output.send(
        .stats(
            peakFootprintBytes: memoryFootprint().peak, chunkP50Milliseconds: nil,
            chunkP95Milliseconds: nil))
    output.send(.done(audioSeconds: audioSeconds))
    return .done
}
