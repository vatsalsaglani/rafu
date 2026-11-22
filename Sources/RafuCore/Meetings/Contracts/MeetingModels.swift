import Foundation

/// The life of one meeting, as the library stores it.
public enum MeetingState: Hashable, Codable, Sendable {
    case recording
    case paused
    case processing
    case ready
    /// The meeting could not finish. `reasonCode` is a short, stable code
    /// (example: `helper-crashed`), never user text.
    case failed(reasonCode: String)
}

/// The engines and model revisions that made a meeting's text and speakers.
/// "Make the text again with the other engine" adds a new entry; the old
/// result stays until the new one is ready.
public struct MeetingEngineUse: Hashable, Codable, Sendable {
    public var textEngine: MeetingTextEngineID?
    public var textModel: MeetingModelID?
    public var textModelRevision: String?
    public var speakerEngine: MeetingSpeakerEngineID?
    public var speakerModel: MeetingModelID?
    public var speakerModelRevision: String?

    public init(
        textEngine: MeetingTextEngineID? = nil,
        textModel: MeetingModelID? = nil,
        textModelRevision: String? = nil,
        speakerEngine: MeetingSpeakerEngineID? = nil,
        speakerModel: MeetingModelID? = nil,
        speakerModelRevision: String? = nil
    ) {
        self.textEngine = textEngine
        self.textModel = textModel
        self.textModelRevision = textModelRevision
        self.speakerEngine = speakerEngine
        self.speakerModel = speakerModel
        self.speakerModelRevision = speakerModelRevision
    }
}

/// The sizes of one meeting on disk, in bytes.
public struct MeetingSizes: Hashable, Codable, Sendable {
    public var audioBytes: Int64
    public var transcriptBytes: Int64

    public init(audioBytes: Int64 = 0, transcriptBytes: Int64 = 0) {
        self.audioBytes = audioBytes
        self.transcriptBytes = transcriptBytes
    }

    public var totalBytes: Int64 { audioBytes + transcriptBytes }
}

/// One row of the meeting list. It has no workspace path and no workspace
/// id: meetings live in Rafu's app data only.
public struct MeetingSummaryRecord: Hashable, Codable, Sendable, Identifiable {
    public var id: MeetingID
    public var title: String
    public var startDate: Date
    /// Recorded length in seconds (pauses not counted).
    public var duration: TimeInterval
    public var state: MeetingState
    public var sizes: MeetingSizes
    public var engines: MeetingEngineUse
    /// The library's write version. Each write takes the expected version.
    public var version: Int

    public init(
        id: MeetingID,
        title: String,
        startDate: Date,
        duration: TimeInterval,
        state: MeetingState,
        sizes: MeetingSizes = MeetingSizes(),
        engines: MeetingEngineUse = MeetingEngineUse(),
        version: Int = 0
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.duration = duration
        self.state = state
        self.sizes = sizes
        self.engines = engines
        self.version = version
    }
}

/// One recognised word. Times are seconds on the meeting clock (0 is the
/// start of the recording; pauses are not counted).
public struct MeetingWord: Hashable, Codable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One turn of the transcript: consecutive words of one speaker on one track.
public struct MeetingTurn: Hashable, Codable, Sendable, Identifiable {
    public var id: MeetingTurnID
    public var track: MeetingTrack
    public var speaker: MeetingSpeakerLabel
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// True when this "Me" turn is the far side heard again through the
    /// microphone (an echo). Echo turns are hidden by default.
    public var isEcho: Bool

    public init(
        id: MeetingTurnID,
        track: MeetingTrack,
        speaker: MeetingSpeakerLabel,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isEcho: Bool = false
    ) {
        self.id = id
        self.track = track
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.isEcho = isEcho
    }
}

/// One span of the "Them" track that a speaker engine gave to one speaker.
public struct MeetingSpeakerSegment: Hashable, Codable, Sendable {
    /// The engine's speaker number, from 1. It becomes `.speaker(number)`.
    public var speaker: Int
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: Int, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// The final text of one track, from `MeetingTextEngine.transcribe`.
public struct MeetingTrackTranscript: Hashable, Codable, Sendable {
    public var track: MeetingTrack
    public var words: [MeetingWord]
    public var engine: MeetingTextEngineID
    public var model: MeetingModelID?
    public var modelRevision: String?

    public init(
        track: MeetingTrack,
        words: [MeetingWord],
        engine: MeetingTextEngineID,
        model: MeetingModelID? = nil,
        modelRevision: String? = nil
    ) {
        self.track = track
        self.words = words
        self.engine = engine
        self.model = model
        self.modelRevision = modelRevision
    }
}
