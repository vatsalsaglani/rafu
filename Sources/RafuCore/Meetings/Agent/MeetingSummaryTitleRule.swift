import Foundation

/// When the agent may set the title of a meeting. A title that the user
/// typed or a rename is never replaced; the default title that Rafu gives at
/// the start (`MeetingDefaultTitle`, for example "Meeting 23 Nov 2026,
/// 10:30") is.
public enum MeetingSummaryTitleRule {
    private static let months: Set<String> = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// True for the form of `MeetingDefaultTitle.text(for:)` in any time
    /// zone: "Meeting <day> <month> <year>, <hh>:<mm>".
    public static func isDefaultForm(_ title: String) -> Bool {
        let parts = title.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "Meeting" else { return false }
        guard isNumber(parts[1], digits: 1...2), months.contains(String(parts[2])) else {
            return false
        }
        let year = parts[3]
        guard year.hasSuffix(","), isNumber(year.dropLast(), digits: 4...4) else { return false }
        let clock = parts[4].split(separator: ":", omittingEmptySubsequences: false)
        return clock.count == 2 && isNumber(clock[0], digits: 2...2)
            && isNumber(clock[1], digits: 2...2)
    }

    private static func isNumber(_ text: Substring, digits: ClosedRange<Int>) -> Bool {
        digits.contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
