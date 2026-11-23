import Foundation

/// The bounds of one hidden meeting agent run. A reply is untrusted data:
/// Rafu reads a bounded amount of it, keeps only text and turn ids, and
/// never runs it or uses it as a path.
public enum MeetingAgentLimits {
    /// The longest question, in characters, after trimming.
    public static let maximumQuestionCharacters = 2_000
    /// The largest Codex packet on standard input (checked: 600 KB accepted).
    public static let maximumPacketBytes = 600_000
    /// The most standard-output bytes read from one run.
    public static let maximumOutputBytes = 4 * 1_024 * 1_024
    /// The longest standard-output line.
    public static let maximumLineBytes = 1_024 * 1_024
    /// The largest answer text kept.
    public static let maximumAnswerBytes = 32 * 1_024
    /// The time limit of one run, start to exit.
    public static let timeLimit = Duration.seconds(120)
    /// The time limit of the `--version` probe.
    public static let versionProbeTimeLimit = Duration.seconds(5)
    /// The most standard-output bytes read from the `--version` probe.
    public static let maximumVersionOutputBytes = 4_096
    /// The most turn ids that one range mark (`[t3–t9]`) gives.
    public static let maximumIDsPerRange = 20
    /// The most citations taken from one answer.
    public static let maximumCitations = 200
}

/// The answer text of a reply, cleaned: valid UTF-8, inside the limit, no
/// control character except a new line (a tab becomes a space).
public enum MeetingAgentAnswerText {
    public enum Problem: Error, Hashable, Sendable {
        case empty
        case tooLarge
    }

    public static func clean(_ raw: String) throws(Problem) -> String {
        guard raw.utf8.count <= MeetingAgentLimits.maximumAnswerBytes else { throw .tooLarge }
        let text = filtered(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        return text
    }

    /// `raw` with no control character except a new line (a tab becomes a
    /// space), no direction override and no line or paragraph separator.
    static func filtered(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\n": scalars.append(scalar)
            case "\t": scalars.append(" ")
            case "\r": continue
            default:
                if scalar.properties.generalCategory == .control
                    || scalar.properties.generalCategory == .format && scalar.value >= 0x202A
                        && scalar.value <= 0x202E
                    || scalar == "\u{2028}" || scalar == "\u{2029}"
                {
                    continue
                }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// One piece of streamed answer text, cleaned like the answer
/// (`MeetingAgentAnswerText`) but not trimmed: a space between two pieces
/// stays. The streamed text is only a preview; the final answer replaces it.
public enum MeetingAgentDeltaText {
    public static func clean(_ raw: String) -> String {
        MeetingAgentAnswerText.filtered(raw)
    }
}
