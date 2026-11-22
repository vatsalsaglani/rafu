import Foundation

/// The identity of one meeting. A meeting lives in Rafu's app data, never in
/// a workspace, so this id never carries a workspace path or workspace id.
public struct MeetingID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The stable identity of one turn inside a meeting. The text form is
/// `t<number>` (example: `t12`); citations and agent tools use that form.
public struct MeetingTurnID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(_ number: Int) {
        self.number = number
    }

    /// Parses the text form `t<number>`. Returns nil for any other text,
    /// including a negative number, an empty number or extra characters.
    public init?(text: String) {
        guard text.hasPrefix("t") else { return nil }
        let digits = text.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            let value = Int(digits)
        else { return nil }
        self.number = value
    }

    public var text: String { "t\(number)" }
    public var description: String { text }

    public static func < (lhs: MeetingTurnID, rhs: MeetingTurnID) -> Bool {
        lhs.number < rhs.number
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = MeetingTurnID(text: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A turn id has the form t<number>.")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// The two recorded tracks. "Me" is the microphone; "Them" is the sound
/// that this Mac plays (the call audio).
public enum MeetingTrack: String, Codable, Sendable, CaseIterable {
    case me
    case them
}

/// The speaker label on a turn. The "Me" track is always `.me`; the "Them"
/// track is `.them` until a speaker engine splits it into numbered speakers.
public enum MeetingSpeakerLabel: Hashable, Codable, Sendable {
    case me
    case them
    case speaker(Int)

    /// The stable text form stored in files: `me`, `them`, `speaker-<n>`.
    public var storageKey: String {
        switch self {
        case .me: "me"
        case .them: "them"
        case .speaker(let number): "speaker-\(number)"
        }
    }

    public init?(storageKey: String) {
        switch storageKey {
        case "me": self = .me
        case "them": self = .them
        default:
            guard storageKey.hasPrefix("speaker-"),
                let number = Int(storageKey.dropFirst("speaker-".count)), number >= 0
            else { return nil }
            self = .speaker(number)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let label = MeetingSpeakerLabel(storageKey: key) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown speaker label.")
        }
        self = label
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}
