import Foundation

/// Finds the turn ids that an answer cites. Accepted forms (seen in the
/// checked runs): `[t7]`, `[t11][t12]`, `[t7] [t11]`, `[t11–t12]` (en
/// dash) and `[t11-t12]`. A range gives each id inside it, at most
/// `MeetingAgentLimits.maximumIDsPerRange`. Any other bracket text (a web
/// address, `[t9 12:27]`, `[t11, t12]`) is not a citation. The library
/// still checks that each id exists in the meeting.
public enum MeetingCitationParser {
    /// The cited ids in the order of their first mark, with no repeat.
    public static func citations(in text: String) -> [MeetingTurnID] {
        var result: [MeetingTurnID] = []
        var seen = Set<MeetingTurnID>()
        var index = text.startIndex
        while index < text.endIndex, result.count < MeetingAgentLimits.maximumCitations {
            guard let open = text[index...].firstIndex(of: "[") else { break }
            let contentStart = text.index(after: open)
            guard let close = text[contentStart...].firstIndex(where: { $0 == "]" || $0 == "[" })
            else { break }
            if text[close] == "[" {
                index = close
                continue
            }
            for id in ids(inMark: text[contentStart..<close]) where seen.insert(id).inserted {
                result.append(id)
                if result.count == MeetingAgentLimits.maximumCitations { break }
            }
            index = text.index(after: close)
        }
        return result
    }

    /// The ids of one mark's content, or none when it is not a citation.
    static func ids(inMark content: Substring) -> [MeetingTurnID] {
        guard content.count <= 24 else { return [] }
        if let single = number(content) { return [MeetingTurnID(single)] }
        guard let dash = content.firstIndex(where: { $0 == "-" || $0 == "\u{2013}" }) else {
            return []
        }
        guard let first = number(content[..<dash]),
            let last = number(content[content.index(after: dash)...]), first <= last
        else { return [] }
        let end = min(last, first + MeetingAgentLimits.maximumIDsPerRange - 1)
        return (first...end).map(MeetingTurnID.init)
    }

    /// The number of `t<digits>` with no other character, at most 9 digits.
    private static func number(_ text: Substring) -> Int? {
        guard text.first == "t" else { return nil }
        let digits = text.dropFirst()
        guard !digits.isEmpty, digits.count <= 9,
            digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(digits)
    }
}
