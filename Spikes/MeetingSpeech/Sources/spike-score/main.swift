// `wer`, `der`, `pipeline` subcommands. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md, Answer 3 "Metrics and tools".
import Foundation
import SpikeScoring

struct WordsFile: Codable {
    struct Word: Codable {
        var text: String
        var start: Double
        var end: Double
    }
    var words: [Word]
}

func readArgs() -> [String: String] {
    var result: [String: String] = [:]
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        guard key.hasPrefix("--") else { continue }
        let value = args.isEmpty ? "" : args.removeFirst()
        result[String(key.dropFirst(2))] = value
    }
    return result
}

func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
          let text = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(text)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("spike-score: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func runWER(_ args: [String: String]) {
    guard let refPath = args["ref"], let hypPath = args["hyp"] else {
        fail("wer needs --ref and --hyp")
    }
    guard let refText = try? String(contentsOfFile: refPath, encoding: .utf8),
          let hypText = try? String(contentsOfFile: hypPath, encoding: .utf8) else {
        fail("could not read --ref or --hyp")
    }
    let result = WordErrorRate.score(reference: refText, hypothesis: hypText)
    printJSON([
        "errorRate": result.errorRate,
        "substitutions": result.substitutions,
        "deletions": result.deletions,
        "insertions": result.insertions,
        "referenceWordCount": result.referenceWordCount,
    ])
}

func runDER(_ args: [String: String]) {
    guard let refPath = args["ref"], let hypPath = args["hyp"] else {
        fail("der needs --ref and --hyp")
    }
    guard let refText = try? String(contentsOfFile: refPath, encoding: .utf8),
          let hypText = try? String(contentsOfFile: hypPath, encoding: .utf8) else {
        fail("could not read --ref or --hyp")
    }
    let reference = RTTM.parse(refText)
    let hypothesis = RTTM.parse(hypText)
    let collar0 = DiarizationScorer.score(reference: reference, hypothesis: hypothesis, collar: 0.0)
    let collar25 = DiarizationScorer.score(reference: reference, hypothesis: hypothesis, collar: 0.25)
    let refSpeakerCount = Set(reference.map(\.speaker)).count
    let hypSpeakerCount = Set(hypothesis.map(\.speaker)).count
    printJSON([
        "collar0": [
            "der": collar0.der, "miss": collar0.missRate, "falseAlarm": collar0.falseAlarmRate,
            "confusion": collar0.confusionRate,
        ],
        "collar25": [
            "der": collar25.der, "miss": collar25.missRate, "falseAlarm": collar25.falseAlarmRate,
            "confusion": collar25.confusionRate,
        ],
        "referenceSpeakerCount": refSpeakerCount,
        "hypothesisSpeakerCount": hypSpeakerCount,
        "speakerCountCorrect": refSpeakerCount == hypSpeakerCount,
        "speakerMapping": collar0.speakerMapping,
    ])
}

func runPipeline(_ args: [String: String]) {
    guard let wordsPath = args["words"], let segmentsPath = args["segments"], let refStmPath = args["ref-stm"] else {
        fail("pipeline needs --words, --segments and --ref-stm")
    }
    let pauseSeconds = Double(args["pause"] ?? "0.8") ?? 0.8
    let boundaryToleranceSeconds = 0.5
    let wordMatchToleranceSeconds = 0.3

    guard let wordsData = try? Data(contentsOf: URL(fileURLWithPath: wordsPath)),
          let wordsFile = try? JSONDecoder().decode(WordsFile.self, from: wordsData) else {
        fail("could not read --words")
    }
    guard let segmentsText = try? String(contentsOfFile: segmentsPath, encoding: .utf8) else {
        fail("could not read --segments")
    }
    guard let refStmText = try? String(contentsOfFile: refStmPath, encoding: .utf8) else {
        fail("could not read --ref-stm")
    }

    let words = wordsFile.words.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
    let hypSegments = RTTM.parse(segmentsText)
    let refEntries = STM.parse(refStmText)
    let refSegments = refEntries.map { DiarSegment(speaker: $0.speaker, start: $0.start, end: $0.end) }

    let assignedWords = WordSpeakerAssigner.assign(words: words, segments: hypSegments)
    let turns = TurnBuilder.build(words: assignedWords, options: TurnBuilderOptions(pauseSeconds: pauseSeconds))

    let mapping = DiarizationScorer.score(reference: refSegments, hypothesis: hypSegments).speakerMapping
    // mapping: hypothesis label -> reference label. We need the reverse,
    // possibly one-to-many if the mapping is not invertible (it is
    // one-to-one by construction, but guard anyway).
    var reverseMapping: [String: String] = [:] // ref label -> hyp label
    for (hypLabel, refLabel) in mapping {
        reverseMapping[refLabel] = hypLabel
    }

    var totalSub = 0
    var totalDel = 0
    var totalIns = 0
    var totalRefWords = 0

    for entry in refEntries {
        let hypLabel = reverseMapping[entry.speaker]
        let matchingWords = assignedWords.filter { word in
            guard let speaker = word.speaker, speaker == hypLabel else { return false }
            return word.start >= entry.start - wordMatchToleranceSeconds
                && word.start <= entry.end + wordMatchToleranceSeconds
        }
        let hypothesisText = matchingWords.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        let result = WordErrorRate.score(reference: entry.text, hypothesis: hypothesisText)
        totalSub += result.substitutions
        totalDel += result.deletions
        totalIns += result.insertions
        totalRefWords += result.referenceWordCount
    }

    let withinTolerance = refEntries.filter { entry in
        turns.contains { abs($0.start - entry.start) <= boundaryToleranceSeconds }
    }.count
    let boundaryAccuracy = refEntries.isEmpty ? 0.0 : Double(withinTolerance) / Double(refEntries.count)
    let speakerAttributedWER = totalRefWords > 0 ? Double(totalSub + totalDel + totalIns) / Double(totalRefWords) : 0.0

    printJSON([
        "pauseSeconds": pauseSeconds,
        "speakerAttributedWordErrorRate": speakerAttributedWER,
        "substitutions": totalSub,
        "deletions": totalDel,
        "insertions": totalIns,
        "referenceWordCount": totalRefWords,
        "boundaryAccuracy": boundaryAccuracy,
        "referenceUtteranceCount": refEntries.count,
        "turnCount": turns.count,
    ])
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    fail("usage: spike-score <wer|der|pipeline> [options]")
}
let subcommand = arguments[1]
let parsed = readArgs()
switch subcommand {
case "wer": runWER(parsed)
case "der": runDER(parsed)
case "pipeline": runPipeline(parsed)
default: fail("unknown subcommand \(subcommand)")
}
