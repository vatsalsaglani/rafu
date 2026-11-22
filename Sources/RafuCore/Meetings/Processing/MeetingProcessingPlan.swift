import Foundation

/// Which engines the processing of one stopped meeting uses. Pure logic:
/// the app reads the availability of each registered engine and asks the
/// plan.
public struct MeetingProcessingPlan: Hashable, Sendable {
    /// The engine for the final text of both tracks.
    public var textEngine: MeetingTextEngineID
    /// The engine to use one time when `textEngine` throws at run time.
    /// Nil when `textEngine` is Apple speech already.
    public var fallbackTextEngine: MeetingTextEngineID?
    /// The speaker engine for the "Them" track, or nil (each far turn keeps
    /// the label "Them").
    public var speakerEngine: MeetingSpeakerEngineID?

    public init(
        textEngine: MeetingTextEngineID, fallbackTextEngine: MeetingTextEngineID?,
        speakerEngine: MeetingSpeakerEngineID?
    ) {
        self.textEngine = textEngine
        self.fallbackTextEngine = fallbackTextEngine
        self.speakerEngine = speakerEngine
    }

    /// - Parameters:
    ///   - preferences: the engines that the user selected.
    ///   - override: the engine of "Make the text again with another
    ///     engine". It replaces the preferred text engine; when it is not
    ///     ready, Apple speech makes the text.
    ///   - textAvailability: the availability of each registered text
    ///     engine. An engine that is not in the map is not registered.
    ///   - speakerAvailability: the same for the speaker engines.
    public static func make(
        preferences: MeetingSpeechPreferences,
        override: MeetingTextEngineID? = nil,
        textAvailability: [MeetingTextEngineID: MeetingEngineAvailability],
        speakerAvailability: [MeetingSpeakerEngineID: MeetingEngineAvailability]
    ) -> MeetingProcessingPlan {
        let text = resolvedFinalTextEngine(
            preference: override ?? preferences.textEngine, availability: textAvailability)
        return MeetingProcessingPlan(
            textEngine: text,
            fallbackTextEngine: text == .appleSpeech ? nil : .appleSpeech,
            speakerEngine: resolvedSpeakerEngine(
                preference: preferences.speakerEngine, availability: speakerAvailability))
    }

    /// The engines to store in the meeting.
    /// - Parameters:
    ///   - me: the final text of "Me", when that track had audio.
    ///   - them: the final text of "Them", when that track had audio.
    ///   - textEngine: the engine that made the text (used when no track had
    ///     audio).
    ///   - speakerEngine: the speaker engine that gave segments, or nil.
    public static func engineUse(
        me: MeetingTrackTranscript?, them: MeetingTrackTranscript?,
        textEngine: MeetingTextEngineID, speakerEngine: MeetingSpeakerEngineID?
    ) -> MeetingEngineUse {
        let transcript = them ?? me
        return MeetingEngineUse(
            textEngine: transcript?.engine ?? textEngine,
            textModel: transcript?.model,
            textModelRevision: transcript?.modelRevision,
            speakerEngine: speakerEngine,
            speakerModel: speakerEngine.map(speakerModel(for:)),
            speakerModelRevision: nil)
    }

    /// The model that a speaker engine runs.
    public static func speakerModel(for engine: MeetingSpeakerEngineID) -> MeetingModelID {
        switch engine {
        case .nemotron3: .nemotron3Fast32
        case .speakerKit: .speakerKit
        }
    }
}

/// Builds the stored turns from the final text of the two tracks and the
/// speaker segments of the "Them" track, then marks echo.
public enum MeetingTranscriptAssembly {
    /// - Parameter outputWasSpeakers: from `recording.json`; false marks no
    ///   echo.
    public static func assemble(
        me: MeetingTrackTranscript?, them: MeetingTrackTranscript?,
        segments: [MeetingSpeakerSegment], outputWasSpeakers: Bool
    ) -> MeetingEchoMarking {
        let turns = MeetingTurnBuilder.build(
            meWords: me?.words ?? [], themWords: them?.words ?? [], segments: segments)
        return MeetingEchoMarker.mark(turns, outputWasSpeakers: outputWasSpeakers)
    }
}

/// Which meetings stopped without finishing: the app quit or crashed while
/// a meeting was recording or processing.
public enum MeetingInterruptedRule {
    /// The meetings in state recording, paused or processing that are not
    /// the live meeting and have no processing job.
    public static func interrupted(
        _ meetings: [MeetingSummaryRecord], liveMeeting: MeetingID?,
        activeJobs: Set<MeetingID> = []
    ) -> [MeetingSummaryRecord] {
        meetings.filter { meeting in
            guard meeting.id != liveMeeting, !activeJobs.contains(meeting.id) else {
                return false
            }
            switch meeting.state {
            case .recording, .paused, .processing: return true
            case .ready, .failed: return false
            }
        }
    }
}

/// The short stable codes of a failed processing job, stored in
/// `MeetingState.failed(reasonCode:)`.
public enum MeetingProcessingFailure {
    public static let textFailed = "text-failed"
    public static let noAudio = "no-audio"
    public static let libraryWrite = "library-write"
    public static let cancelled = "cancelled"
    public static let interrupted = "interrupted"
}
