// SpeakerKit (pyannote community-1), through argmax-oss-swift. Throw-away
// spike code; see .rafu/plans/meeting-speech-spike.md.
import Foundation
import SpeakerKit
import SpikeSupport

struct Args {
    var audio: String
    var modelDir: String?
    var numSpeakers: Int?
    var out: String
}

func parseArgs() -> Args {
    var audio: String?
    var modelDir: String?
    var numSpeakers: Int?
    var out: String?

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        switch key {
        case "--audio": audio = args.isEmpty ? nil : args.removeFirst()
        case "--model-dir": modelDir = args.isEmpty ? nil : args.removeFirst()
        case "--num-speakers":
            let value = args.isEmpty ? nil : args.removeFirst()
            if let value, value != "auto" { numSpeakers = Int(value) }
        case "--out": out = args.isEmpty ? nil : args.removeFirst()
        default: break
        }
    }
    guard let audio, let out else {
        FileHandle.standardError.write(
            "usage: spike-argmax-diar --audio <wav> [--model-dir <dir>] [--num-speakers N|auto] --out <hyp.rttm>\n"
                .data(using: .utf8)!
        )
        exit(1)
    }
    return Args(audio: audio, modelDir: modelDir, numSpeakers: numSpeakers, out: out)
}

let parsedArgs = parseArgs()

do {
    let clock = SpikeClock()
    let footprintStart = Footprint.currentMB()

    let config: PyannoteConfig
    if let modelDir = parsedArgs.modelDir {
        config = PyannoteConfig(modelFolder: modelDir, download: false, load: true, verbose: false)
    } else {
        config = PyannoteConfig(download: true, load: true, verbose: false)
    }
    let speakerKit = try await SpeakerKit(config)

    let loadMs = clock.elapsedMilliseconds
    let footprintAfterLoad = Footprint.currentMB()

    let audio = try WAV.readMono16k(path: parsedArgs.audio)
    let audioSeconds = Double(audio.count) / 16000.0

    let options = PyannoteDiarizationOptions(numberOfSpeakers: parsedArgs.numSpeakers)
    let result = try await speakerKit.diarize(audioArray: audio, options: options)
    let firstResultMs = clock.elapsedMilliseconds

    let processSeconds = clock.elapsedSeconds - (loadMs / 1000.0)
    let footprintEnd = Footprint.currentMB()
    let footprintPeak = max(footprintAfterLoad, footprintEnd)

    let fileName = URL(fileURLWithPath: parsedArgs.audio).deletingPathExtension().lastPathComponent
    let rttmLines = SpeakerKit.generateRTTM(from: result, fileName: fileName)
    let rttmText = rttmLines.map(\.description).joined(separator: "\n") + "\n"
    try rttmText.write(toFile: parsedArgs.out, atomically: true, encoding: .utf8)

    let line = ResultLine(
        engine: "argmax-diarizer", model: "speakerkit-pyannote-community-1", file: parsedArgs.audio,
        audioSeconds: audioSeconds, loadMs: loadMs, firstResultMs: firstResultMs,
        processSeconds: max(processSeconds, 0.001),
        footprintAfterLoadMB: footprintAfterLoad - footprintStart,
        footprintPeakMB: footprintPeak - footprintStart,
        footprintEndMB: footprintEnd - footprintStart,
        note: parsedArgs.numSpeakers.map { "numberOfSpeakers=\($0)" } ?? "numberOfSpeakers=auto"
    )
    line.printLine()
} catch {
    print("{\"note\":\"spike-argmax-diar failed: \(error)\"}")
    exit(1)
}
