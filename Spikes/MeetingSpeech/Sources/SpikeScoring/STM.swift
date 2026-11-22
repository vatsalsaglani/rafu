// STM: `<file> <channel> <speaker> <start> <end> <text>`, one line per
// reference (or hypothesis) utterance. Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.
import Foundation

public struct STMEntry: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum STM {
    public static func parse(_ text: String) -> [STMEntry] {
        var entries: [STMEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 6, let start = Double(parts[3]), let end = Double(parts[4]) else { continue }
            entries.append(STMEntry(speaker: parts[2], start: start, end: end, text: parts[5]))
        }
        return entries
    }

    public static func write(_ entries: [STMEntry], file: String = "meeting") -> String {
        entries.map { entry in
            "\(file) 1 \(entry.speaker) \(format(entry.start)) \(format(entry.end)) \(entry.text)"
        }.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
