import Foundation

/// The `UserDefaults` keys of Settings ▸ Meetings.
public enum MeetingPreferenceKeys {
    public static let textEngine = "meetings.textEngine"
    public static let speakerEngine = "meetings.speakerEngine"
    public static let microphone = "meetings.microphone"
    public static let audioRetention = "meetings.audioRetention"
    public static let agentAccess = "meetings.agentAccess"
    /// True after the first-use download sheet was shown one time.
    public static let firstUseSheetShown = "meetings.firstUseSheetShown"
}

/// The selected engines. The interface always names the engine in use,
/// which can differ when the selected one is not ready (see the
/// `resolved…Engine` functions).
public struct MeetingSpeechPreferences: Hashable, Codable, Sendable {
    public var textEngine: MeetingTextEngineID
    public var speakerEngine: MeetingSpeakerEngineID

    /// WhisperKit: the recommended model of the first-use sheet. Until it is
    /// installed, the final text uses Apple speech.
    public static let defaultTextEngine: MeetingTextEngineID = .whisperKit
    public static let defaultSpeakerEngine: MeetingSpeakerEngineID = .nemotron3

    public init(
        textEngine: MeetingTextEngineID = Self.defaultTextEngine,
        speakerEngine: MeetingSpeakerEngineID = Self.defaultSpeakerEngine
    ) {
        self.textEngine = textEngine
        self.speakerEngine = speakerEngine
    }
}

/// Which microphone a recording uses.
public enum MeetingMicrophoneChoice: Hashable, Codable, Sendable {
    /// Rafu picks (the built-in microphone over a call-mode headset).
    case automatic
    case systemDefault
    /// A Core Audio device UID.
    case device(uid: String)

    /// The stored text form: `automatic`, `systemDefault`, `device:<uid>`.
    public var storageValue: String {
        switch self {
        case .automatic: "automatic"
        case .systemDefault: "systemDefault"
        case .device(let uid): "device:\(uid)"
        }
    }

    /// An unknown or empty value gives `.automatic`.
    public static func resolve(stored: String?) -> MeetingMicrophoneChoice {
        guard let stored else { return .automatic }
        switch stored {
        case "automatic": return .automatic
        case "systemDefault": return .systemDefault
        default:
            let prefix = "device:"
            guard stored.hasPrefix(prefix), stored.count > prefix.count else { return .automatic }
            return .device(uid: String(stored.dropFirst(prefix.count)))
        }
    }
}

/// How long Rafu keeps a meeting's audio after processing.
public enum MeetingAudioRetention: String, Codable, Sendable, CaseIterable {
    case untilDeleted
    case days30
    case days7

    public static let defaultValue: MeetingAudioRetention = .untilDeleted

    /// The number of days, or nil for "until the meeting is deleted".
    public var days: Int? {
        switch self {
        case .untilDeleted: nil
        case .days30: 30
        case .days7: 7
        }
    }
}

/// Settings ▸ Meetings ▸ "Allow agents to read your meetings". Off by default.
public enum MeetingAgentAccess: String, Codable, Sendable, CaseIterable {
    case off
    case on

    public static let defaultValue: MeetingAgentAccess = .off
}

/// Reads the Meetings settings. Tests inject values; the app reads
/// `UserDefaults`.
public protocol MeetingPreferencesReading: Sendable {
    func speechPreferences() -> MeetingSpeechPreferences
    func microphoneChoice() -> MeetingMicrophoneChoice
    func audioRetention() -> MeetingAudioRetention
    func agentAccess() -> MeetingAgentAccess
}

/// Reads the Meetings settings from a `UserDefaults` suite. An unknown or
/// missing value gives the default.
public struct UserDefaultsMeetingPreferences: MeetingPreferencesReading {
    private let suiteName: String?

    /// `suiteName` nil reads `UserDefaults.standard`.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func speechPreferences() -> MeetingSpeechPreferences {
        MeetingSpeechPreferences(
            textEngine: defaults.string(forKey: MeetingPreferenceKeys.textEngine)
                .flatMap(MeetingTextEngineID.init(rawValue:))
                ?? MeetingSpeechPreferences.defaultTextEngine,
            speakerEngine: defaults.string(forKey: MeetingPreferenceKeys.speakerEngine)
                .flatMap(MeetingSpeakerEngineID.init(rawValue:))
                ?? MeetingSpeechPreferences.defaultSpeakerEngine
        )
    }

    public func microphoneChoice() -> MeetingMicrophoneChoice {
        MeetingMicrophoneChoice.resolve(
            stored: defaults.string(forKey: MeetingPreferenceKeys.microphone))
    }

    public func audioRetention() -> MeetingAudioRetention {
        defaults.string(forKey: MeetingPreferenceKeys.audioRetention)
            .flatMap(MeetingAudioRetention.init(rawValue:)) ?? .defaultValue
    }

    public func agentAccess() -> MeetingAgentAccess {
        defaults.string(forKey: MeetingPreferenceKeys.agentAccess)
            .flatMap(MeetingAgentAccess.init(rawValue:)) ?? .defaultValue
    }
}
