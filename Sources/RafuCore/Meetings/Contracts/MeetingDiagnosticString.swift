import Foundation

/// The only string type a meeting diagnostic event may hold. It is for a
/// short list of facts: a device name, a device UID, a bundle id, an error
/// domain and version strings. Never transcript text, a title, a speaker
/// name, a question, an answer or a path.
///
/// The value is cut to at most 128 UTF-8 bytes (on a character boundary)
/// and has its control characters removed.
public struct MeetingDiagnosticString: Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public static let maximumBytes = 128

    public let value: String

    public init(_ raw: String) {
        self.value = Self.clean(raw)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    /// Removes control characters (C0, DEL, C1, and the Unicode `Cc`, line
    /// and paragraph separators), then cuts to `maximumBytes` UTF-8 bytes
    /// without splitting a character.
    public static func clean(_ raw: String) -> String {
        var result = ""
        var bytes = 0
        for character in raw {
            if character.unicodeScalars.contains(where: isControl) { continue }
            let size = character.utf8.count
            if bytes + size > maximumBytes { break }
            result.append(character)
            bytes += size
        }
        return result
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator, .format:
            return true
        default:
            return false
        }
    }
}
