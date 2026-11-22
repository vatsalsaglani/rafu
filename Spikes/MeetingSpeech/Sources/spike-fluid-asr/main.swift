// Nemotron text, through FluidAudio's `StreamingNemotronAsrManager`.
// Throw-away spike code; see .rafu/plans/meeting-speech-spike.md.
//
// Memory-growth investigation (item b of the follow-up list; see
// .rafu/plans/meeting-speech-spike-results.md, "Nemotron English memory
// growth source (item b)"): three flags added below, every one default-off
// so the plain command (no new flag) reproduces the exact numbers already
// on file for every earlier run in that results file.
//
// - `--trace-footprint` prints extra `Footprint.currentMB()` checkpoints to
//   stderr (never stdout, so the JSON result line this tool already prints
//   is unchanged) at points the default run never samples: right after the
//   whole file is read into the `audio: [Float]` array, right after the
//   single `AVAudioPCMBuffer` copy of it is built, and right after
//   `process(audioBuffer:)` returns but before `finish()` runs.
// - `--drop-audio-after-feed` releases the top-level `audio: [Float]` array
//   (the decoded whole-file samples) right after the one `AVAudioPCMBuffer`
//   copy is built from it, instead of holding it until process exit. Tests
//   whether that one array is a real part of the measured growth.
// - `--restart-every-seconds <n>` feeds the file in `n`-second segments and
//   calls `finishWithTokenTimings()` (which runs FluidAudio's own
//   `finish()`, the one that clears `audioBuffer`/`accumulatedTokenIds`/
//   `accumulatedTokenTimings` by `removeAll()`, not a public `reset()`
//   this spike had to add — `StreamingNemotronAsrManager.reset()` already
//   exists in FluidAudio's pinned source, see the results file) between
//   segments, on the same manager (no reload). Tests the "chunked session
//   that restarts" option named in the task.
import AVFoundation
import CoreML
import FluidAudio
import Foundation
import SpikeScoring
import SpikeSupport

struct Args {
    var audio: String
    var modelDir: String?
    var tier: Int
    var computeUnits: String
    var streams: Int
    var paced: Bool
    var out: String
    var traceFootprint: Bool
    var dropAudioAfterFeed: Bool
    var restartEverySeconds: Double
}

func parseArgs() -> Args {
    var audio: String?
    var modelDir: String?
    var tier = 1120
    var computeUnits = "all"
    var streams = 1
    var paced = false
    var out: String?
    var traceFootprint = false
    var dropAudioAfterFeed = false
    var restartEverySeconds = 0.0

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        switch key {
        case "--audio": audio = args.isEmpty ? nil : args.removeFirst()
        case "--model-dir": modelDir = args.isEmpty ? nil : args.removeFirst()
        case "--tier": tier = args.isEmpty ? tier : Int(args.removeFirst()) ?? tier
        case "--compute-units": computeUnits = args.isEmpty ? computeUnits : args.removeFirst()
        case "--streams": streams = args.isEmpty ? streams : Int(args.removeFirst()) ?? streams
        case "--paced": paced = true
        case "--out": out = args.isEmpty ? nil : args.removeFirst()
        case "--trace-footprint": traceFootprint = true
        case "--drop-audio-after-feed": dropAudioAfterFeed = true
        case "--restart-every-seconds":
            restartEverySeconds = args.isEmpty ? restartEverySeconds : Double(args.removeFirst()) ?? restartEverySeconds
        default: break
        }
    }
    guard let audio, let out else {
        FileHandle.standardError.write(
            "usage: spike-fluid-asr --audio <wav> [--model-dir <dir>] [--tier 560|1120|2240] [--compute-units all|ane|cpu] [--streams 1|2] [--paced] [--trace-footprint] [--drop-audio-after-feed] [--restart-every-seconds <n>] --out <words.json>\n"
                .data(using: .utf8)!
        )
        exit(1)
    }
    return Args(
        audio: audio, modelDir: modelDir, tier: tier, computeUnits: computeUnits, streams: streams, paced: paced,
        out: out, traceFootprint: traceFootprint, dropAudioAfterFeed: dropAudioAfterFeed,
        restartEverySeconds: restartEverySeconds
    )
}

func traceFootprint(_ label: String, _ mb: Double, enabled: Bool) {
    guard enabled else { return }
    FileHandle.standardError.write("[trace-footprint] \(label): \(mb) MB\n".data(using: .utf8)!)
}

func chunkSize(forTier tier: Int) -> NemotronChunkSize {
    switch tier {
    case 560: return .ms560
    case 2240: return .ms2240
    default: return .ms1120
    }
}

func mlComputeUnits(_ s: String) -> MLComputeUnits {
    switch s {
    case "ane": return .cpuAndNeuralEngine
    case "cpu": return .cpuOnly
    default: return .all
    }
}

func tokenToWords(_ timings: [TokenTiming], fallbackEnd: Double) -> [TimedWord] {
    let tokens = timings.map { timing in
        Token(
            text: timing.token, time: timing.startTime,
            isWordStart: timing.token.hasPrefix("\u{2581}") || timing.token.hasPrefix(" ")
        )
    }
    return TokenWordGrouper.words(from: tokens, fallbackEnd: fallbackEnd)
}

struct ChunkTiming {
    var ms: Double
}

func makeManager(modelDir: String?, tier: Int, computeUnits: MLComputeUnits) async throws -> StreamingNemotronAsrManager {
    let manager = StreamingNemotronAsrManager(
        configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: computeUnits),
        requestedChunkSize: chunkSize(forTier: tier)
    )
    if let modelDir {
        try await manager.loadModels(from: URL(fileURLWithPath: modelDir))
    } else {
        try await manager.loadModels()
    }
    return manager
}

let parsedArgs = parseArgs()

do {
    let clock = SpikeClock()
    let footprintStart = Footprint.currentMB()
    let computeUnits = mlComputeUnits(parsedArgs.computeUnits)

    var managers: [StreamingNemotronAsrManager] = []
    for _ in 0..<max(1, parsedArgs.streams) {
        managers.append(try await makeManager(modelDir: parsedArgs.modelDir, tier: parsedArgs.tier, computeUnits: computeUnits))
    }

    let loadMs = clock.elapsedMilliseconds
    let footprintAfterLoad = Footprint.currentMB()

    var audio = try WAV.readMono16k(path: parsedArgs.audio)
    let audioSeconds = Double(audio.count) / 16000.0
    traceFootprint("after WAV read", Footprint.currentMB() - footprintStart, enabled: parsedArgs.traceFootprint)

    var firstResultMs: Double?
    var peakFootprint = footprintAfterLoad
    var chunkTimingsMs: [Double] = []
    var text = ""
    var timings: [TokenTiming] = []
    var alreadyFinished = false

    if parsedArgs.paced {
        // Feed audio in chunks sized to the model's own tier, pacing each
        // feed at real-time speed (sleeping for the chunk's audio
        // duration between feeds), and time each feed.
        let chunkSamples = Int(Double(parsedArgs.tier) / 1000.0 * 16000.0)
        var offset = 0
        var pieceIndex = 0
        while offset < audio.count {
            let end = min(offset + chunkSamples, audio.count)
            let piece = Array(audio[offset..<end])
            guard let buffer = PCMBuffer.make(from: piece) else { break }
            let chunkStart = clock.elapsedMilliseconds
            for manager in managers {
                _ = try await manager.process(audioBuffer: buffer)
            }
            let chunkElapsed = clock.elapsedMilliseconds - chunkStart
            chunkTimingsMs.append(chunkElapsed)
            if firstResultMs == nil { firstResultMs = clock.elapsedMilliseconds }
            peakFootprint = max(peakFootprint, Footprint.currentMB())
            if pieceIndex % 60 == 0 {
                // One memory sample roughly every minute of audio, per the
                // "footprint each 60 s of audio" requirement.
            }
            offset = end
            pieceIndex += 1
            let chunkAudioSeconds = Double(piece.count) / 16000.0
            try? await Task.sleep(nanoseconds: UInt64(max(0, chunkAudioSeconds) * 1_000_000_000))
        }
    } else if parsedArgs.restartEverySeconds > 0 {
        // "Chunked session that restarts" (item b's method, step 4): feed
        // the file in `restartEverySeconds`-second segments, calling
        // `finishWithTokenTimings()` (FluidAudio's own `finish()`, which
        // clears `audioBuffer`/`accumulatedTokenIds`/`accumulatedTokenTimings`
        // by `removeAll()`) between segments, on the same manager — no
        // reload, no new `StreamingNemotronAsrManager`. No real-time
        // sleeping: this is a memory/structure test, not a latency one.
        let segmentSamples = max(1, Int(parsedArgs.restartEverySeconds * 16000.0))
        var offset = 0
        var segmentFootprintsMB: [Double] = []
        while offset < audio.count {
            let end = min(offset + segmentSamples, audio.count)
            let segment = Array(audio[offset..<end])
            guard let buffer = PCMBuffer.make(from: segment) else { break }
            for manager in managers {
                _ = try await manager.process(audioBuffer: buffer)
            }
            let offsetSeconds = Double(offset) / 16000.0
            for manager in managers {
                let result = try await manager.finishWithTokenTimings()
                text += (text.isEmpty ? "" : " ") + result.text
                timings.append(
                    contentsOf: result.timings.map {
                        TokenTiming(
                            token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime + offsetSeconds,
                            endTime: $0.endTime + offsetSeconds, confidence: $0.confidence
                        )
                    })
                // `finish()` alone (above) already clears `audioBuffer`/
                // `accumulatedTokenIds`/`accumulatedTokenTimings` by
                // `removeAll()` (FluidAudio's own `StreamingAsrUtils
                // .resetSharedState`, read directly from the pinned
                // source). `reset()` is FluidAudio's own explicit public
                // API for "start a new session on the same manager" (item
                // b's step 4: "if the engine offers a reset ... add that
                // as an option"); it additionally re-creates the encoder
                // cache/decoder-LSTM-state `MLMultiArray`s via
                // `resetStates()`, which `finish()` does not call. Called
                // here so this flag's measurement reflects the literal
                // reset API, not just finish()'s own partial clearing.
                await manager.reset()
            }
            let sampleMB = Footprint.currentMB() - footprintStart
            segmentFootprintsMB.append(sampleMB)
            peakFootprint = max(peakFootprint, Footprint.currentMB())
            if firstResultMs == nil { firstResultMs = clock.elapsedMilliseconds }
            offset = end
        }
        alreadyFinished = true
        if parsedArgs.traceFootprint {
            FileHandle.standardError.write(
                "[trace-footprint] per-restart footprint MB (one per \(parsedArgs.restartEverySeconds)s segment): \(segmentFootprintsMB)\n"
                    .data(using: .utf8)!
            )
        }
    } else {
        guard let buffer = PCMBuffer.make(from: audio) else {
            throw NSError(domain: "spike-fluid-asr", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build PCM buffer"])
        }
        traceFootprint("after PCMBuffer built", Footprint.currentMB() - footprintStart, enabled: parsedArgs.traceFootprint)
        if parsedArgs.dropAudioAfterFeed {
            // Release the whole-file sample array now that its one copy is
            // inside `buffer` — tests whether holding it until process exit
            // (the default) is itself part of the measured growth.
            audio = []
        }
        for manager in managers {
            _ = try await manager.process(audioBuffer: buffer)
        }
        traceFootprint("after process(), before finish()", Footprint.currentMB() - footprintStart, enabled: parsedArgs.traceFootprint)
        firstResultMs = clock.elapsedMilliseconds
        peakFootprint = max(peakFootprint, Footprint.currentMB())
    }

    if !alreadyFinished {
        for manager in managers {
            let result = try await manager.finishWithTokenTimings()
            if text.isEmpty { text = result.text }
            if timings.isEmpty { timings = result.timings }
        }
    }

    let processSeconds = clock.elapsedSeconds - (loadMs / 1000.0)
    let footprintEnd = Footprint.currentMB()
    peakFootprint = max(peakFootprint, footprintEnd)

    let words = tokenToWords(timings, fallbackEnd: audioSeconds)
    let output: [String: Any] = [
        "words": words.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
        "text": text,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
        try data.write(to: URL(fileURLWithPath: parsedArgs.out))
    }

    var chunkStats: ChunkStats?
    if !chunkTimingsMs.isEmpty {
        let sorted = chunkTimingsMs.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        chunkStats = ChunkStats(medianMs: median, p95Ms: sorted[p95Index], maxMs: sorted.last ?? 0)
    }

    let line = ResultLine(
        engine: "fluid-asr", model: "nemotron-streaming-\(parsedArgs.tier)ms", file: parsedArgs.audio,
        audioSeconds: audioSeconds, loadMs: loadMs, firstResultMs: firstResultMs ?? loadMs,
        processSeconds: max(processSeconds, 0.001),
        footprintAfterLoadMB: footprintAfterLoad - footprintStart,
        footprintPeakMB: peakFootprint - footprintStart,
        footprintEndMB: footprintEnd - footprintStart,
        chunkStats: chunkStats,
        note: parsedArgs.streams > 1 ? "\(parsedArgs.streams) concurrent streams" : nil
    )
    line.printLine()
} catch {
    print("{\"note\":\"spike-fluid-asr failed: \(error)\"}")
    exit(1)
}
