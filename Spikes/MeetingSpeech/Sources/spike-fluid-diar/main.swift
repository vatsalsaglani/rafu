// Nemotron 3 speakers, through FluidAudio. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.
//
// Segmentation note (deviation from the plan, partly resolved — see
// --segmentation below): FluidAudio's own `DiarizerTimeline` is a larger,
// stateful subsystem (renaming, snapshots, rollback) built for the live
// path; this spike still does not use it. The default `--segmentation
// simple` thresholds `processComplete`'s raw [frames * 8] probabilities
// directly (frame active when probability >= --threshold) and merges
// contiguous active frames per speaker slot into segments, dropping
// segments shorter than 0.2 s — this is the spike's own, simplified
// reimplementation, kept unchanged so earlier runs stay comparable.
// `--segmentation engine` instead calls FluidAudio's own
// `Nemotron3Diarizer.segments(probabilities:frameCount:numSpeakers:
// threshold:frameSeconds:minDurationSeconds:)` (Sources/FluidAudio/Diarizer/
// Nemotron3/Nemotron3Diarizer.swift in the pinned FluidAudio source,
// commit e0c6103b) with `minDurationSeconds: 0`, exactly as FluidAudio's
// own CLI benchmark passes it (`evaluateMeeting` in
// Sources/FluidAudioCLI/Commands/Nemotron3DiarizeCommand.swift, same
// commit). This is the function the project's own `nemotron3-benchmark`
// CLI command scores against AMI with, not a guessed reimplementation.
import CoreML
import FluidAudio
import Foundation
import SpikeScoring
import SpikeSupport

enum SegmentationMode: String {
    case simple
    case engine
}

struct Args {
    var audio: String
    var modelDir: String?
    var preset: String
    var computeUnits: String
    var streaming: Bool
    var threshold: Float
    var segmentation: SegmentationMode
    var out: String
}

func parseArgs() -> Args {
    var audio: String?
    var modelDir: String?
    var preset = "fast32"
    var computeUnits = "all"
    var streaming = false
    var threshold: Float = 0.5
    var segmentation: SegmentationMode = .simple
    var out: String?

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        switch key {
        case "--audio": audio = args.isEmpty ? nil : args.removeFirst()
        case "--model-dir": modelDir = args.isEmpty ? nil : args.removeFirst()
        case "--preset": preset = args.isEmpty ? preset : args.removeFirst()
        case "--compute-units": computeUnits = args.isEmpty ? computeUnits : args.removeFirst()
        case "--streaming": streaming = true
        case "--threshold": threshold = args.isEmpty ? threshold : Float(args.removeFirst()) ?? threshold
        case "--segmentation":
            segmentation = args.isEmpty ? segmentation : (SegmentationMode(rawValue: args.removeFirst()) ?? segmentation)
        case "--out": out = args.isEmpty ? nil : args.removeFirst()
        default: break
        }
    }
    guard let audio, let out else {
        FileHandle.standardError.write(
            "usage: spike-fluid-diar --audio <wav> [--model-dir <dir>] [--preset fast32] [--compute-units all|ane|cpu] [--streaming] [--segmentation simple|engine] --out <hyp.rttm>\n"
                .data(using: .utf8)!
        )
        exit(1)
    }
    return Args(
        audio: audio, modelDir: modelDir, preset: preset, computeUnits: computeUnits,
        streaming: streaming, threshold: threshold, segmentation: segmentation, out: out
    )
}

func parseComputeUnits(_ s: String) -> MLComputeUnits {
    switch s {
    case "ane": return .cpuAndNeuralEngine
    case "cpu": return .cpuOnly
    default: return .all
    }
}

/// Merges contiguous active frames per speaker slot into segments, at
/// `frameDuration` seconds per frame. Drops segments shorter than
/// `minDuration`.
func segmentsFromProbabilities(
    _ probabilities: [Float], frameCount: Int, numSpeakers: Int, threshold: Float,
    frameDuration: Double = 0.01, minDuration: Double = 0.2
) -> [DiarSegment] {
    var segments: [DiarSegment] = []
    for speaker in 0..<numSpeakers {
        var activeStart: Int?
        for frame in 0...frameCount {
            let isActive = frame < frameCount && probabilities[frame * numSpeakers + speaker] >= threshold
            if isActive, activeStart == nil {
                activeStart = frame
            } else if !isActive, let start = activeStart {
                let startSeconds = Double(start) * frameDuration
                let endSeconds = Double(frame) * frameDuration
                if endSeconds - startSeconds >= minDuration {
                    segments.append(DiarSegment(speaker: "Speaker\(speaker + 1)", start: startSeconds, end: endSeconds))
                }
                activeStart = nil
            }
        }
    }
    return segments.sorted { $0.start < $1.start }
}

let parsedArgs = parseArgs()

do {
    let clock = SpikeClock()
    let footprintStart = Footprint.currentMB()

    guard let config = Nemotron3Config.preset(named: parsedArgs.preset) else {
        FileHandle.standardError.write("unknown preset: \(parsedArgs.preset)\n".data(using: .utf8)!)
        exit(1)
    }
    let computeUnits = parseComputeUnits(parsedArgs.computeUnits)

    let models: Nemotron3Models
    if let modelDir = parsedArgs.modelDir {
        models = try await Nemotron3Models.load(
            config: config, directory: URL(fileURLWithPath: modelDir), computeUnits: computeUnits
        )
    } else {
        models = try await Nemotron3Models.loadFromHuggingFace(config: config, computeUnits: computeUnits)
    }
    let diarizer = Nemotron3Diarizer(config: config, models: models)

    let loadMs = clock.elapsedMilliseconds
    let footprintAfterLoad = Footprint.currentMB()

    let audio = try WAV.readMono16k(path: parsedArgs.audio)
    let audioSeconds = Double(audio.count) / 16000.0

    var firstResultMs: Double?
    let probabilities: [Float]
    let frameCount: Int
    if parsedArgs.streaming {
        diarizer.reset()
        var probs: [Float] = []
        var frames = 0
        var offset = 0
        let pieceSamples = 1600 // 100 ms at 16 kHz, matching FluidAudioCLI's example
        while offset < audio.count {
            let end = min(offset + pieceSamples, audio.count)
            diarizer.appendAudio(Array(audio[offset..<end]))
            for r in try diarizer.processBufferedAudio() {
                if firstResultMs == nil { firstResultMs = clock.elapsedMilliseconds }
                probs.append(contentsOf: r.probabilities)
                frames += r.frameCount
            }
            offset = end
        }
        for r in try diarizer.finishStream() {
            probs.append(contentsOf: r.probabilities)
            frames += r.frameCount
        }
        probabilities = probs
        frameCount = frames
    } else {
        let result = try diarizer.processComplete(audio)
        firstResultMs = clock.elapsedMilliseconds
        probabilities = result.probabilities
        frameCount = result.frameCount
    }

    let processSeconds = clock.elapsedSeconds - (loadMs / 1000.0)
    let footprintEnd = Footprint.currentMB()
    let footprintPeak = max(footprintAfterLoad, footprintEnd)

    let segments: [DiarSegment]
    switch parsedArgs.segmentation {
    case .simple:
        segments = segmentsFromProbabilities(
            probabilities, frameCount: frameCount, numSpeakers: config.numSpeakers, threshold: parsedArgs.threshold
        )
    case .engine:
        // FluidAudio's own segmentation, exactly as its CLI benchmark calls it
        // (minDurationSeconds: 0 — no minimum-duration drop). See the file
        // header comment for the exact source function and commit.
        segments = Nemotron3Diarizer.segments(
            probabilities: probabilities, frameCount: frameCount, numSpeakers: config.numSpeakers,
            threshold: parsedArgs.threshold, minDurationSeconds: 0
        ).map { seg in
            DiarSegment(
                speaker: "Speaker\(seg.speakerIndex + 1)", start: Double(seg.startSeconds), end: Double(seg.endSeconds)
            )
        }
    }
    try RTTM.write(segments, file: URL(fileURLWithPath: parsedArgs.audio).deletingPathExtension().lastPathComponent)
        .write(toFile: parsedArgs.out, atomically: true, encoding: .utf8)

    let line = ResultLine(
        engine: "fluid-diarizer", model: "nemotron3-\(parsedArgs.preset)", file: parsedArgs.audio,
        audioSeconds: audioSeconds, loadMs: loadMs, firstResultMs: firstResultMs ?? loadMs,
        processSeconds: max(processSeconds, 0.001),
        footprintAfterLoadMB: footprintAfterLoad - footprintStart,
        footprintPeakMB: footprintPeak - footprintStart,
        footprintEndMB: footprintEnd - footprintStart
    )
    line.printLine()
} catch {
    print("{\"note\":\"spike-fluid-diar failed: \(error)\"}")
    exit(1)
}
