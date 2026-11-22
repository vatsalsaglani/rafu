// RTTM (Rich Transcription Time Marked): the NIST format for diarization
// references and hypotheses. One `SPEAKER` line per segment:
// `SPEAKER <file> <chnl> <tbeg> <tdur> <NA> <NA> <speaker> <NA> <NA>`.
// Throw-away spike code; see .rafu/plans/meeting-speech-spike.md.
import Foundation

public enum RTTM {
    public static func parse(_ text: String) -> [DiarSegment] {
        var segments: [DiarSegment] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 8, fields[0] == "SPEAKER" else { continue }
            guard let start = Double(fields[3]), let duration = Double(fields[4]) else { continue }
            segments.append(DiarSegment(speaker: fields[7], start: start, end: start + duration))
        }
        return segments
    }

    public static func write(_ segments: [DiarSegment], file: String = "meeting") -> String {
        segments.map { segment in
            let duration = segment.end - segment.start
            return "SPEAKER \(file) 1 \(format(segment.start)) \(format(duration)) <NA> <NA> \(segment.speaker) <NA> <NA>"
        }.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
