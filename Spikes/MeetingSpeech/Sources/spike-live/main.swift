// Live-load run: Me + Them Nemotron text streams plus the Nemotron 3
// speaker model on the Them track, in one process, paced at real time.
// Throw-away spike code; see .rafu/plans/meeting-speech-spike.md, Answer 3
// "Live load" row (step 4 of 5 of the spike).
//
// Pacing note (same simplification as spike-fluid-asr's --paced mode):
// each chunk's work (both ASR streams plus the diarizer's 100 ms
// sub-feeds) runs, then the process sleeps for the chunk's own audio
// duration regardless of how long that work took. This does not "catch
// up" if a chunk runs over budget; the chunk-processing-time stats below
// are exactly the number the plan's pass/fail rule needs to tell whether
// that would happen in practice (p95 at most 50% of the chunk length).
import AVFoundation
import CoreML
import FluidAudio
import Foundation
import SpikeScoring
import SpikeSupport

struct Args {
    var them: String
    var me: String?
    var asrModelDir: String
    var tier: Int
    var diarModelDir: String
    var preset: String
    var streams: Int
    var out: String
}

func parseArgs() -> Args {
    var them: String?
    var me: String?
    var asrModelDir: String?
    var tier = 1120
    var diarModelDir: String?
    var preset = "fast32"
    var streams = 1
    var out: String?

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        switch key {
        case "--them": them = args.isEmpty ? nil : args.removeFirst()
        case "--me": me = args.isEmpty ? nil : args.removeFirst()
        case "--asr-model-dir": asrModelDir = args.isEmpty ? nil : args.removeFirst()
        case "--tier": tier = args.isEmpty ? tier : Int(args.removeFirst()) ?? tier
        case "--diar-model-dir": diarModelDir = args.isEmpty ? nil : args.removeFirst()
        case "--preset": preset = args.isEmpty ? preset : args.removeFirst()
        case "--streams": streams = args.isEmpty ? streams : Int(args.removeFirst()) ?? streams
        case "--out": out = args.isEmpty ? nil : args.removeFirst()
        default: break
        }
    }
    guard let them, let asrModelDir, let diarModelDir, let out else {
        FileHandle.standardError.write(
            "usage: spike-live --them <wav> [--me <wav>] --asr-model-dir <dir> [--tier 1120] --diar-model-dir <dir> [--preset fast32] [--streams 1|2] --out <result.json>\n"
                .data(using: .utf8)!
        )
        exit(1)
    }
    return Args(
        them: them, me: me, asrModelDir: asrModelDir, tier: tier, diarModelDir: diarModelDir,
        preset: preset, streams: streams, out: out
    )
}

func chunkSize(forTier tier: Int) -> NemotronChunkSize {
    switch tier {
    case 560: return .ms560
    case 2240: return .ms2240
    default: return .ms1120
    }
}

let parsedArgs = parseArgs()

do {
    let clock = SpikeClock()
    let footprintStart = Footprint.currentMB()

    let asrConfig = MLModelConfigurationUtils.defaultConfiguration(computeUnits: .all)

    var asrManagers: [StreamingNemotronAsrManager] = []
    for _ in 0..<max(1, parsedArgs.streams) {
        let manager = StreamingNemotronAsrManager(
            configuration: asrConfig, requestedChunkSize: chunkSize(forTier: parsedArgs.tier)
        )
        try await manager.loadModels(from: URL(fileURLWithPath: parsedArgs.asrModelDir))
        asrManagers.append(manager)
    }

    guard let diarConfig = Nemotron3Config.preset(named: parsedArgs.preset) else {
        FileHandle.standardError.write("unknown preset: \(parsedArgs.preset)\n".data(using: .utf8)!)
        exit(1)
    }
    let diarModels = try await Nemotron3Models.load(
        config: diarConfig, directory: URL(fileURLWithPath: parsedArgs.diarModelDir), computeUnits: .all
    )
    let diarizer = Nemotron3Diarizer(config: diarConfig, models: diarModels)
    diarizer.reset()

    let loadMs = clock.elapsedMilliseconds
    let footprintAfterLoad = Footprint.currentMB()

    let themAudio = try WAV.readMono16k(path: parsedArgs.them)
    var usedSecondCopyForMe = false
    let meAudio: [Float]
    if let mePath = parsedArgs.me {
        meAudio = try WAV.readMono16k(path: mePath)
    } else {
        meAudio = themAudio
        usedSecondCopyForMe = true
    }
    let audioSeconds = Double(themAudio.count) / 16000.0

    let chunkSamples = Int(Double(parsedArgs.tier) / 1000.0 * 16000.0)
    let diarPieceSamples = 1600 // 100 ms, matching spike-fluid-diar's streaming cadence

    var firstResultMs: Double?
    var peakFootprint = footprintAfterLoad
    var chunkTimingsMs: [Double] = []

    var offset = 0
    while offset < themAudio.count {
        let end = min(offset + chunkSamples, themAudio.count)
        let themPiece = Array(themAudio[offset..<end])
        let chunkStart = clock.elapsedMilliseconds

        // Them stream: always the first ASR manager.
        if let buffer = PCMBuffer.make(from: themPiece) {
            _ = try await asrManagers[0].process(audioBuffer: buffer)
        }
        // Me stream: the second ASR manager, only when --streams 2.
        if asrManagers.count > 1 {
            let meEnd = min(end, meAudio.count)
            if offset < meAudio.count, let meBuffer = PCMBuffer.make(from: Array(meAudio[offset..<meEnd])) {
                _ = try await asrManagers[1].process(audioBuffer: meBuffer)
            }
        }
        // Speaker model on the Them track, fed in 100 ms sub-pieces (the
        // cadence spike-fluid-diar's own --streaming mode uses).
        var subOffset = 0
        while subOffset < themPiece.count {
            let subEnd = min(subOffset + diarPieceSamples, themPiece.count)
            diarizer.appendAudio(Array(themPiece[subOffset..<subEnd]))
            _ = try diarizer.processBufferedAudio()
            subOffset = subEnd
        }

        let chunkElapsed = clock.elapsedMilliseconds - chunkStart
        chunkTimingsMs.append(chunkElapsed)
        if firstResultMs == nil { firstResultMs = clock.elapsedMilliseconds }
        peakFootprint = max(peakFootprint, Footprint.currentMB())

        offset = end
        let chunkAudioSeconds = Double(themPiece.count) / 16000.0
        try? await Task.sleep(nanoseconds: UInt64(max(0, chunkAudioSeconds) * 1_000_000_000))
    }

    _ = try diarizer.finishStream()
    for manager in asrManagers {
        _ = try await manager.finishWithTokenTimings()
    }

    let processSeconds = clock.elapsedSeconds - (loadMs / 1000.0)
    let footprintEnd = Footprint.currentMB()
    peakFootprint = max(peakFootprint, footprintEnd)

    var chunkStats: ChunkStats?
    if !chunkTimingsMs.isEmpty {
        let sorted = chunkTimingsMs.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        chunkStats = ChunkStats(medianMs: median, p95Ms: sorted[p95Index], maxMs: sorted.last ?? 0)
    }

    var note = "\(parsedArgs.streams) text stream(s) + nemotron3-\(parsedArgs.preset) on the Them track"
    if usedSecondCopyForMe, parsedArgs.streams > 1 {
        note += "; no separate Me recording for this file, so the Me stream is a second copy of the Them audio"
    }

    let line = ResultLine(
        engine: "live", model: "nemotron-streaming-\(parsedArgs.tier)ms+nemotron3-\(parsedArgs.preset)",
        file: parsedArgs.them, audioSeconds: audioSeconds, loadMs: loadMs,
        firstResultMs: firstResultMs ?? loadMs, processSeconds: max(processSeconds, 0.001),
        footprintAfterLoadMB: footprintAfterLoad - footprintStart,
        footprintPeakMB: peakFootprint - footprintStart,
        footprintEndMB: footprintEnd - footprintStart,
        chunkStats: chunkStats,
        note: note
    )
    line.printLine()
} catch {
    print("{\"note\":\"spike-live failed: \(error)\"}")
    exit(1)
}
