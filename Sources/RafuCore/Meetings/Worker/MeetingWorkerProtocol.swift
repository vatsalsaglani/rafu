import Foundation

// The wire between the app and the `RafuMeetingsWorker` helper (protocol 1).
// These types are pure: the helper and the app share them, and
// `RafuCoreTests` tests them without a process.
//
// - Arguments: `--mode <live-text|final-text|speakers> --protocol 1`, and
//   nothing else (no path, no text).
// - Standard input: one JSON request line (at most 16 KB). In `live-text`
//   mode, binary audio frames follow (see `MeetingWorkerFrame`); the end of
//   input means "finish". In the file modes, the end of input means "cancel".
// - Standard output: JSON lines, each at most 64 KB (`MeetingWorkerEvent`).
// - Standard error: discarded by the app.

/// Limits and constants of the worker protocol.
public enum MeetingWorkerProtocol {
    /// The protocol version in the arguments and in the request.
    public static let version = 1
    /// The largest request line, newline not counted.
    public static let maximumRequestBytes = 16 * 1_024
    /// The largest output line, newline not counted.
    public static let maximumLineBytes = 64 * 1_024
    /// The most samples in one live audio frame (1 s at 16 kHz).
    public static let maximumFrameSamples = 16_000
    /// The bytes before the samples of one frame: track (1), meeting-clock
    /// time (8, a little-endian `Double`), sample count (4, little-endian).
    public static let frameHeaderBytes = 13
    /// Words in one `final` line, so a line stays below the line limit.
    public static let wordsPerLine = 400
    /// Segments in one `segments` line, so a line stays below the limit.
    public static let segmentsPerLine = 800
    /// The helper sends a `stats` line this often in live mode, in seconds.
    public static let liveStatsIntervalSeconds: Double = 10
}

/// The work one helper process does.
public enum MeetingWorkerMode: String, Codable, Sendable, CaseIterable {
    case liveText = "live-text"
    case finalText = "final-text"
    case speakers

    /// The same mode, as the diagnostics contract names it.
    public var diagnosticMode: MeetingHelperMode {
        switch self {
        case .liveText: .liveText
        case .finalText: .finalText
        case .speakers: .speakers
        }
    }

    /// True for the modes that read a stored audio file.
    public var readsAudioFile: Bool { self != .liveText }
}

/// The engine a helper runs. Each is one of the four helper engines.
public enum MeetingWorkerEngineID: String, Codable, Sendable, CaseIterable {
    case nemotronEnglish = "nemotron-en"
    case whisperKit = "whisperkit"
    case nemotron3 = "nemotron-3"
    case speakerKit = "speakerkit"

    /// The modes this engine can run.
    public var supportedModes: Set<MeetingWorkerMode> {
        switch self {
        case .nemotronEnglish: [.liveText, .finalText]
        case .whisperKit: [.finalText]
        case .nemotron3, .speakerKit: [.speakers]
        }
    }

    /// The model this engine loads.
    public var model: MeetingModelID {
        switch self {
        case .nemotronEnglish: .nemotronEnglish1120
        case .whisperKit: .whisperLargeV3
        case .nemotron3: .nemotron3Fast32
        case .speakerKit: .speakerKit
        }
    }

    /// The engine id of the contracts, for diagnostics.
    public var anyEngineID: MeetingAnyEngineID {
        switch self {
        case .nemotronEnglish: .text(.nemotronEnglish)
        case .whisperKit: .text(.whisperKit)
        case .nemotron3: .speaker(.nemotron3)
        case .speakerKit: .speaker(.speakerKit)
        }
    }

    public init(_ text: MeetingTextEngineID) throws(MeetingWorkerRequestError) {
        switch text {
        case .nemotronEnglish: self = .nemotronEnglish
        case .whisperKit: self = .whisperKit
        case .appleSpeech: throw .engineNotInHelper
        }
    }

    public init(_ speaker: MeetingSpeakerEngineID) {
        switch speaker {
        case .nemotron3: self = .nemotron3
        case .speakerKit: self = .speakerKit
        }
    }
}

/// The exit codes of the helper (from sysexits(3)).
public enum MeetingWorkerExitCode: Int32, Sendable, CaseIterable {
    case done = 0
    case usage = 64
    case badRequest = 65
    case modelMissing = 66
    case engineError = 70
    case cancelled = 75
}

/// A wrong argument list.
public enum MeetingWorkerUsageError: Error, Equatable, Sendable {
    case wrongArguments
    case unsupportedProtocol
}

/// The argument list of the helper.
public enum MeetingWorkerArguments {
    /// The only argument list the app passes.
    public static func make(mode: MeetingWorkerMode) -> [String] {
        ["--mode", mode.rawValue, "--protocol", String(MeetingWorkerProtocol.version)]
    }

    /// Parses the arguments after the executable name. Each other shape is
    /// refused: an extra argument, a missing value, another order.
    public static func parse(_ arguments: [String]) throws(MeetingWorkerUsageError)
        -> MeetingWorkerMode
    {
        guard arguments.count == 4, arguments[0] == "--mode", arguments[2] == "--protocol",
            let mode = MeetingWorkerMode(rawValue: arguments[1])
        else { throw .wrongArguments }
        guard arguments[3] == String(MeetingWorkerProtocol.version) else {
            throw .unsupportedProtocol
        }
        return mode
    }
}
