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
/// speaker segments of the "Them" track. Echo is marked per word while the
/// turns are built, so echo words and real words land in separate turns.
public enum MeetingTranscriptAssembly {
    /// - Parameter outputWasSpeakers: from `recording.json`; false marks no
    ///   echo.
    public static func assemble(
        me: MeetingTrackTranscript?, them: MeetingTrackTranscript?,
        segments: [MeetingSpeakerSegment], outputWasSpeakers: Bool
    ) -> MeetingEchoMarking {
        let turns = MeetingTurnBuilder.build(
            meWords: me?.words ?? [], themWords: them?.words ?? [], segments: segments,
            outputWasSpeakers: outputWasSpeakers)
        return MeetingEchoMarking(turns: turns, echoCount: turns.filter(\.isEcho).count)
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

/// Which cut-off meetings hold nothing and are deleted at launch. A failed
/// Start or a crash before the first audio left a meeting row with no
/// audio; each one showed as a "Failed" row that the user could not use.
/// All four conditions must hold, so a meeting with any audio or text is
/// never deleted.
public enum MeetingEmptyRecordingRule {
    /// True only when the meeting is recording, paused or failed with the
    /// code `interrupted`, has no final audio file larger than the CAF
    /// header, journal recovery gave 0 s, and it has no turns.
    public static func shouldDelete(
        state: MeetingState, hasFinalAudio: Bool, recoveredSeconds: TimeInterval, turnCount: Int
    ) -> Bool {
        switch state {
        case .recording, .paused: break
        case .failed(let code) where code == MeetingProcessingFailure.interrupted: break
        case .processing, .ready, .failed: return false
        }
        return !hasFinalAudio && recoveredSeconds == 0 && turnCount == 0
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
