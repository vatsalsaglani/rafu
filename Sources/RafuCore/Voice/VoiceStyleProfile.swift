import Foundation

public nonisolated enum VoiceStyleProfileError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int)
    case unknownKey(String)
    case unsupportedVersion(Int)
    case invalid
}

/// The personalization profile, schema v1 (VPLAN section 8). Derived
/// preferences only: never audio, transcripts, note text, terminal output or
/// tool results. Phase 1 stores, shows and resets it; learning is Phase 2.
public nonisolated struct VoiceStyleProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumBytes = 4_096
    public static let maximumCommandShapes = 10
    public static let maximumEnsembles = 10

    public var version: Int
    /// "brief", "warm", …
    public var tone: String?
    /// "short" or "detailed".
    public var verbosity: String?
    /// Spoken name → what it means, for example "Lead" → a node title.
    public var names: [String: String]?
    /// Words the user says to confirm, for example "go ahead".
    public var confirmWords: [String]?
    /// At most ten frequent command shapes, for example "add a note called X".
    public var commandShapes: [String]?
    public var checkInSeconds: Int?
    /// At most ten most-used Ensemble titles.
    public var ensembles: [String]?

    public init(version: Int = VoiceStyleProfile.currentVersion) {
        self.version = version
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, tone, verbosity, names, ensembles
        case confirmWords = "confirm_words"
        case commandShapes = "command_shapes"
        case checkInSeconds = "check_in_seconds"
    }

    /// Any key that is not in the schema.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let raw = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = raw.allKeys.map(\.stringValue).sorted().first(where: {
            !known.contains($0)
        }) {
            throw VoiceStyleProfileError.unknownKey(String(unknown.prefix(64)))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tone = try container.decodeIfPresent(String.self, forKey: .tone)
        verbosity = try container.decodeIfPresent(String.self, forKey: .verbosity)
        names = try container.decodeIfPresent([String: String].self, forKey: .names)
        confirmWords = try container.decodeIfPresent([String].self, forKey: .confirmWords)
        commandShapes = try container.decodeIfPresent([String].self, forKey: .commandShapes)
        checkInSeconds = try container.decodeIfPresent(Int.self, forKey: .checkInSeconds)
        ensembles = try container.decodeIfPresent([String].self, forKey: .ensembles)
    }

    /// Sorted keys, pretty printed for the View popup.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Rejects a profile that is too large or breaks a list bound.
    public func validate() throws(VoiceStyleProfileError) {
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        if (commandShapes?.count ?? 0) > Self.maximumCommandShapes { throw .invalid }
        if (ensembles?.count ?? 0) > Self.maximumEnsembles { throw .invalid }
        if let seconds = checkInSeconds, !(15...600).contains(seconds) { throw .invalid }
        guard let size = try? encoded().count else { throw .invalid }
        guard size <= Self.maximumBytes else { throw .tooLarge(bytes: size) }
    }

    /// Decodes and validates stored bytes. Unknown keys and anything over
    /// 4 KiB are refused.
    public static func decode(_ data: Data) throws -> VoiceStyleProfile {
        guard data.count <= maximumBytes else {
            throw VoiceStyleProfileError.tooLarge(bytes: data.count)
        }
        let profile = try JSONDecoder().decode(VoiceStyleProfile.self, from: data)
        try profile.validate()
        return profile
    }
}
