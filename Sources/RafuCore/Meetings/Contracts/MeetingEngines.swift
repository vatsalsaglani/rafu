import Foundation

/// The text engines a user can select (Settings ▸ Meetings ▸ Text engine).
public enum MeetingTextEngineID: String, Codable, Sendable, CaseIterable {
    case nemotronEnglish = "nemotron-en"
    case appleSpeech = "apple-speech"
    case whisperKit = "whisperkit"
}

/// The speaker engines a user can select (Settings ▸ Meetings ▸ Speaker engine).
public enum MeetingSpeakerEngineID: String, Codable, Sendable, CaseIterable {
    case nemotron3 = "nemotron-3"
    case speakerKit = "speakerkit"
}

/// The downloadable models. Apple speech needs no Rafu download.
public enum MeetingModelID: String, Codable, Sendable, CaseIterable {
    case nemotronEnglish1120 = "nemotron-en-1120ms"
    case whisperLargeV3 = "whisperkit-large-v3-626mb"
    case nemotron3Fast32 = "nemotron-3-fast32"
    case speakerKit = "speakerkit-pyannote"
}

/// Whether an engine can run now.
public enum MeetingEngineAvailability: Sendable, Equatable {
    case ready
    case needsModel([MeetingModelID])
    /// A short user-facing reason, for example "Meetings needs macOS 26".
    case unavailable(reason: String)

    public var isReady: Bool { self == .ready }
}

/// Progress of a final pass or a speaker pass, for the interface.
public enum MeetingEngineProgress: Sendable, Equatable {
    /// The model loads (a cold WhisperKit load is about 58 s).
    case preparingModel
    /// `fraction` is 0...1 of the stored audio.
    case working(fraction: Double)
}

/// One event of a live text session. Live text is a preview only; the
/// stored text always comes from `MeetingTextEngine.transcribe` after Stop.
public enum MeetingLiveTextEvent: Sendable, Equatable {
    /// Text that can still change, covering `range` on the meeting clock.
    case volatile(text: String, range: ClosedRange<TimeInterval>)
    /// Words that will not change in this session.
    case final(words: [MeetingWord])
    /// The session stopped giving text; `reason` is user-facing.
    case unavailable(reason: String)
}

/// The request for the final text of one track, after Stop.
public struct MeetingFinalTextRequest: Sendable, Equatable {
    public var meeting: MeetingID
    public var track: MeetingTrack
    /// The stored audio of that track (from `MeetingStoring.audioFolder(for:)`).
    public var audioFile: URL

    public init(meeting: MeetingID, track: MeetingTrack, audioFile: URL) {
        self.meeting = meeting
        self.track = track
        self.audioFile = audioFile
    }
}

/// The request to split the "Them" track into speakers, after Stop. The
/// "Me" track never goes to a speaker engine.
public struct MeetingSpeakerRequest: Sendable, Equatable {
    public var meeting: MeetingID
    public var audioFile: URL

    public init(meeting: MeetingID, audioFile: URL) {
        self.meeting = meeting
        self.audioFile = audioFile
    }
}

/// A text engine: Apple speech in the app, Nemotron and WhisperKit in the
/// helper.
public protocol MeetingTextEngine: Sendable {
    var id: MeetingTextEngineID { get }
    /// False for WhisperKit.
    var supportsLiveText: Bool { get }
    func availability() async -> MeetingEngineAvailability
    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession
    /// The final text from the stored audio, after Stop.
    func transcribe(
        _ request: MeetingFinalTextRequest,
        progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript
}

/// One live text stream for one track.
public protocol MeetingLiveTextSession: Sendable {
    var events: AsyncStream<MeetingLiveTextEvent> { get }
    func append(_ chunk: MeetingAudioChunk) async
    func finish() async
}

/// A speaker engine. Runs on the "Them" track only, after Stop.
public protocol MeetingSpeakerEngine: Sendable {
    var id: MeetingSpeakerEngineID { get }
    func availability() async -> MeetingEngineAvailability
    func diarize(_ request: MeetingSpeakerRequest) async throws -> [MeetingSpeakerSegment]
}

/// Finds the installed folder of a model. The helper gets that folder path
/// only; it never downloads.
public protocol MeetingModelLocating: Sendable {
    func installedFolder(for model: MeetingModelID) async -> URL?
}

// MARK: - Engine choice

/// The text engine for the final pass: the preferred engine when it is
/// ready, else Apple speech.
public func resolvedFinalTextEngine(
    preference: MeetingTextEngineID,
    availability: [MeetingTextEngineID: MeetingEngineAvailability]
) -> MeetingTextEngineID {
    if availability[preference]?.isReady == true { return preference }
    return .appleSpeech
}

/// The text engine for live text: the preferred engine when it is ready and
/// has live text, else Nemotron when ready, else Apple speech.
/// `liveCapable` lists the engines that give live text (WhisperKit does not).
public func resolvedLiveTextEngine(
    preference: MeetingTextEngineID,
    availability: [MeetingTextEngineID: MeetingEngineAvailability],
    liveCapable: Set<MeetingTextEngineID> = [.nemotronEnglish, .appleSpeech]
) -> MeetingTextEngineID {
    if availability[preference]?.isReady == true, liveCapable.contains(preference) {
        return preference
    }
    if availability[.nemotronEnglish]?.isReady == true, liveCapable.contains(.nemotronEnglish) {
        return .nemotronEnglish
    }
    return .appleSpeech
}

/// The speaker engine: the preferred engine when ready, else the other one
/// when ready, else none (the "Them" track keeps the label "Them").
public func resolvedSpeakerEngine(
    preference: MeetingSpeakerEngineID,
    availability: [MeetingSpeakerEngineID: MeetingEngineAvailability]
) -> MeetingSpeakerEngineID? {
    if availability[preference]?.isReady == true { return preference }
    let others = MeetingSpeakerEngineID.allCases.filter { $0 != preference }
    return others.first { availability[$0]?.isReady == true }
}
