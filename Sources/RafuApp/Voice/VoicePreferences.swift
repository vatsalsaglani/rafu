import Foundation
import RafuCore

/// Settings ▸ Voice values. Plain `UserDefaults`, never a secret.
nonisolated struct VoicePreferences: Sendable {
    static let backendKey = "voice.backend"
    static let voiceKey = "voice.voice"
    static let shareTerminalTailKey = "voice.shareTerminalTail"
    static let personalizationKey = "voice.personalization"
    static let monthlyCapKey = "voice.monthlyCapUSD"
    static let debugTranscriptKey = "voice.debugTranscript"
    static let agentUpdatesKey = "voice.agentUpdates"
    static let keepsCompanionKey = "voice.companion.keepOnCanvas"

    static let capRange = 1...50

    /// `nil` means `.standard`. `UserDefaults` is not `Sendable`, so the
    /// suite name is stored and the defaults opened per read.
    let suiteName: String?

    init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    var backend: VoiceBackendModel {
        defaults.string(forKey: Self.backendKey).flatMap(VoiceBackendModel.init(rawValue:))
            ?? .default
    }

    var voice: VoiceVoice {
        defaults.string(forKey: Self.voiceKey).flatMap(VoiceVoice.init(rawValue:)) ?? .default
    }

    /// Default on: the tail is shared only in Allow mode anyway.
    var sharesTerminalTail: Bool {
        defaults.object(forKey: Self.shareTerminalTailKey) as? Bool ?? true
    }

    /// Default off (opt-in).
    var personalization: Bool { defaults.bool(forKey: Self.personalizationKey) }

    /// Default off (opt-in). Read when a session opens.
    var keepsDebugTranscript: Bool { defaults.bool(forKey: Self.debugTranscriptKey) }

    /// Default on: Rafu speaks when an agent finishes or needs you, while a
    /// voice session is open. Read each time an update is due.
    var speaksAgentUpdates: Bool {
        defaults.object(forKey: Self.agentUpdatesKey) as? Bool ?? true
    }

    /// Default off: the companion shows only while a session is open.
    var keepsCompanion: Bool { defaults.bool(forKey: Self.keepsCompanionKey) }

    var monthlyCapDollars: Double {
        let stored = defaults.object(forKey: Self.monthlyCapKey) as? Int
        let value = stored ?? Int(VoiceCostMeter.defaultCapDollars)
        return Double(min(Self.capRange.upperBound, max(Self.capRange.lowerBound, value)))
    }
}
