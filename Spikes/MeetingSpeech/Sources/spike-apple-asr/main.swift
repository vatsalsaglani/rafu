// Apple `SpeechAnalyzer` + `SpeechTranscriber` (en-US, with audio time
// ranges) on a file. Timebox 1 hour per the plan's risk table: no
// permission prompt is possible from a bare command-line tool (no
// Info.plist), and assets must already be installed. Throw-away spike
// code; see .rafu/plans/meeting-speech-spike.md.
import AVFoundation
import Foundation
import Speech
import SpikeSupport

struct Args {
    var audio: String
    var out: String
}

struct WordHit: Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct CollectedResults: Sendable {
    var words: [WordHit]
    var firstResultMs: Double?
    var peakFootprintMB: Double
}

func parseArgs() -> Args {
    var audio: String?
    var out: String?
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        switch key {
        case "--audio": audio = args.isEmpty ? nil : args.removeFirst()
        case "--out": out = args.isEmpty ? nil : args.removeFirst()
        default: break
        }
    }
    guard let audio, let out else {
        FileHandle.standardError.write("usage: spike-apple-asr --audio <wav> --out <words.json>\n".data(using: .utf8)!)
        exit(1)
    }
    return Args(audio: audio, out: out)
}

@available(macOS 26, *)
func run(_ args: Args) async throws {
    let clock = SpikeClock()
    let footprintStart = Footprint.currentMB()

    guard SpeechTranscriber.isAvailable else {
        print("{\"note\":\"SpeechTranscriber.isAvailable is false on this run\"}")
        return
    }
    let locale = Locale(identifier: "en-US")
    guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
        print("{\"note\":\"en-US is not a supported SpeechTranscriber locale on this run\"}")
        return
    }

    let transcriber = SpeechTranscriber(
        locale: supportedLocale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )

    let installed = await SpeechTranscriber.installedLocales
    if !installed.contains(where: { $0.identifier(.bcp47) == supportedLocale.identifier(.bcp47) }) {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    let audioURL = URL(fileURLWithPath: args.audio)
    let audioFile = try AVAudioFile(forReading: audioURL)
    let audioSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate

    let analyzer = try await SpeechAnalyzer(
        inputAudioFile: audioFile,
        modules: [transcriber],
        finishAfterFile: true
    )

    let loadMs = clock.elapsedMilliseconds
    let footprintAfterLoad = Footprint.currentMB()

    async let collected: CollectedResults = collectResults(
        from: transcriber, clock: clock, footprintAfterLoad: footprintAfterLoad
    )
    try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
    let results = try await collected

    let processSeconds = clock.elapsedSeconds - (loadMs / 1000.0)
    let footprintEnd = Footprint.currentMB()
    let peakFootprint = max(results.peakFootprintMB, footprintEnd)

    let output: [String: Any] = [
        "words": results.words.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
        try data.write(to: URL(fileURLWithPath: args.out))
    }

    let line = ResultLine(
        engine: "apple", model: "SpeechTranscriber(en-US)", file: args.audio,
        audioSeconds: audioSeconds, loadMs: loadMs, firstResultMs: results.firstResultMs ?? loadMs,
        processSeconds: max(processSeconds, 0.001),
        footprintAfterLoadMB: footprintAfterLoad - footprintStart,
        footprintPeakMB: peakFootprint - footprintStart,
        footprintEndMB: footprintEnd - footprintStart
    )
    line.printLine()
}

@available(macOS 26, *)
func collectResults(
    from transcriber: SpeechTranscriber, clock: SpikeClock, footprintAfterLoad: Double
) async throws -> CollectedResults {
    var words: [WordHit] = []
    var firstResultMs: Double?
    var peak = footprintAfterLoad
    for try await result in transcriber.results {
        if firstResultMs == nil { firstResultMs = clock.elapsedMilliseconds }
        peak = max(peak, Footprint.currentMB())
        let text = result.text
        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard !runText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var start = 0.0
            var end = 0.0
            if let timeRange = run.audioTimeRange {
                start = timeRange.start.seconds
                end = (timeRange.start + timeRange.duration).seconds
            }
            for piece in runText.split(separator: " ") {
                words.append(WordHit(text: String(piece), start: start, end: end))
            }
        }
    }
    return CollectedResults(words: words, firstResultMs: firstResultMs, peakFootprintMB: peak)
}

let parsedArgs = parseArgs()
if #available(macOS 26, *) {
    do {
        try await run(parsedArgs)
    } catch {
        print("{\"note\":\"spike-apple-asr failed: \(error)\"}")
        exit(1)
    }
} else {
    print("{\"note\":\"macOS 26 or later is required\"}")
    exit(1)
}
