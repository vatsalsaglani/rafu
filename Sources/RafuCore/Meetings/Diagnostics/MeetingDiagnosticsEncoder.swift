import Foundation

/// Encodes one diagnostic event as one JSON line: `t` (ISO 8601 with
/// milliseconds, UTC), `clock` (seconds on the meeting clock, only when a
/// meeting runs), `event`, the event fields and, when events were lost,
/// `dropped`. Keys are sorted, so a line is stable and easy to compare.
///
/// Pure: no clock, no file, no global state. Values are numbers, booleans,
/// fixed labels and `MeetingDiagnosticString` values. A text value that
/// looks like a path or a URL is replaced when the event is described (see
/// `MeetingDiagnosticDescription.scrubbed`), so that a careless caller
/// cannot write a file location into a log.
public enum MeetingDiagnosticsEncoder {
    /// The text that replaces a text value that looks like a path.
    public static let removedPathText = MeetingDiagnosticDescription.removedPathText

    /// One line, without the trailing newline.
    public static func line(
        for event: MeetingDiagnosticEvent, time: Date, clock: Double?, dropped: Int = 0
    ) -> String {
        let description = event.diagnosticDescription
        var pairs: [(key: String, json: String)] = [
            ("t", string(timestamp(time))),
            ("event", string(description.name)),
        ]
        if let clock { pairs.append(("clock", number(clock))) }
        if dropped > 0 { pairs.append(("dropped", String(dropped))) }
        for field in description.fields
        where !MeetingDiagnosticDescription.reservedKeys.contains(field.key) {
            pairs.append((field.key, json(field.value)))
        }
        pairs.sort { $0.key < $1.key }
        return "{" + pairs.map { string($0.key) + ":" + $0.json }.joined(separator: ",") + "}"
    }

    /// ISO 8601 with milliseconds, in UTC.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: JSON pieces

    private static func json(_ value: MeetingDiagnosticValue) -> String {
        switch value {
        case .integer(let value): String(value)
        case .number(let value): number(value)
        case .flag(let value): value ? "true" : "false"
        case .label(let value): string(value)
        case .text(let value): string(value)
        case .texts(let values): "[" + values.map(string).joined(separator: ",") + "]"
        }
    }

    /// Three decimals at most; a value that is not finite is `null`.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        let rounded = (value * 1000).rounded() / 1000
        // `-0.0` would print as a negative zero.
        return (rounded == 0 ? 0 : rounded).description
    }

    private static func string(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
