// WhisperKit `openai_whisper-large-v3-v20240930_626MB`, word times on.
// Throw-away spike code; see .rafu/plans/meeting-speech-spike.md.
import Foundation
import SpikeSupport
import WhisperKit

struct Args {
    var audio: String
    var modelDir: String?
    var model: String
    var out: String
}

func parseArgs() -> Args {
    var audio: String?
    var modelDir: String?
    var model = "openai_whisper-large-v3-v20240930_626MB"
    var out: String?

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        switch key {
        case "--audio": audio = args.isEmpty ? nil : args.removeFirst()
        case "--model-dir": modelDir = args.isEmpty ? nil : args.removeFirst()
        case "--model": model = args.isEmpty ? model : args.removeFirst()
        case "--out": out = args.isEmpty ? nil : args.removeFirst()
        default: break
        }
    }
    guard let audio, let out else {
        FileHandle.standardError.write(
            "usage: spike-argmax-asr --audio <wav> [--model-dir <dir>] [--model <name>] --out <words.json>\n"
                .data(using: .utf8)!
        )
        exit(1)
    }
    return Args(audio: audio, modelDir: modelDir, model: model, out: out)
}

let parsedArgs = parseArgs()

do {
    let clock = SpikeClock()
    let footprintStart = Footprint.currentMB()

    let config = WhisperKitConfig(
        model: parsedArgs.model,
        modelFolder: parsedArgs.modelDir,
        verbose: false,
        load: true,
        download: parsedArgs.modelDir == nil
    )
    let whisperKit = try await WhisperKit(config)

    let loadMs = clock.elapsedMilliseconds
    let footprintAfterLoad = Footprint.currentMB()

    let audio = try WAV.readMono16k(path: parsedArgs.audio)
    let audioSeconds = Double(audio.count) / 16000.0

    let decodeOptions = DecodingOptions(language: "en", wordTimestamps: true)
    let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decodeOptions)
    let firstResultMs = clock.elapsedMilliseconds

    let processSeconds = clock.elapsedSeconds - (loadMs / 1000.0)
    let footprintEnd = Footprint.currentMB()
    let footprintPeak = max(footprintAfterLoad, footprintEnd)

    var words: [[String: Any]] = []
    var fullText = ""
    for result in results {
        fullText += result.text
        for segment in result.segments {
            for word in segment.words ?? [] {
                words.append(["text": word.word, "start": Double(word.start), "end": Double(word.end)])
            }
        }
    }

    let output: [String: Any] = ["words": words, "text": fullText]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
        try data.write(to: URL(fileURLWithPath: parsedArgs.out))
    }

    let line = ResultLine(
        engine: "argmax-asr", model: parsedArgs.model, file: parsedArgs.audio,
        audioSeconds: audioSeconds, loadMs: loadMs, firstResultMs: firstResultMs,
        processSeconds: max(processSeconds, 0.001),
        footprintAfterLoadMB: footprintAfterLoad - footprintStart,
        footprintPeakMB: footprintPeak - footprintStart,
        footprintEndMB: footprintEnd - footprintStart
    )
    line.printLine()
} catch {
    print("{\"note\":\"spike-argmax-asr failed: \(error)\"}")
    exit(1)
}
