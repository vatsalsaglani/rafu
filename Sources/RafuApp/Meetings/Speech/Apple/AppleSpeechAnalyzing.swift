import Foundation
import RafuCore

// The seam between `AppleSpeechEngine` and Apple's `SpeechAnalyzer`. The real
// adapter is `SystemAppleSpeechAnalyzer`; tests use a scripted fake, so they
// never need the system speech model.

/// Whether the system has the English (US) speech assets.
nonisolated enum AppleSpeechAssetStatus: Sendable, Equatable {
    case installed
    /// The system can download its own assets (`AssetInventory`), on a user
    /// action only.
    case needsSystemDownload
    /// The system downloads its assets now.
    case downloading
    /// No English speech on this Mac (or `SpeechTranscriber` is not available).
    case unsupported
}

/// One run of a result's text with its audio time, in seconds on the
/// analyzer's clock (0 is the first sample given to the analyzer).
nonisolated struct AppleSpeechRun: Sendable, Equatable {
    var text: String
    var range: ClosedRange<TimeInterval>?
}

/// One result of the analyzer, copied out of the Speech types.
nonisolated struct AppleSpeechResult: Sendable, Equatable {
    var isFinal: Bool
    /// The audio that the result covers, on the analyzer's clock.
    var range: ClosedRange<TimeInterval>
    var runs: [AppleSpeechRun]

    init(isFinal: Bool, range: ClosedRange<TimeInterval>, runs: [AppleSpeechRun]) {
        self.isFinal = isFinal
        self.range = range
        self.runs = runs
    }

    var text: String { runs.map(\.text).joined() }
}

/// The result of a final pass over one stored file.
nonisolated struct AppleSpeechFileAnalysis: Sendable, Equatable {
    var audioSeconds: Double
    /// From the call until the analyzer was ready.
    var loadMilliseconds: Int
    /// Final results only, in order.
    var results: [AppleSpeechResult]
}

/// The Apple speech analyzer, as the engine uses it.
nonisolated protocol AppleSpeechAnalyzing: Sendable {
    func assetStatus() async -> AppleSpeechAssetStatus
    /// Asks the system to download its English speech assets. A user action
    /// only; nothing else calls it.
    func installSystemAssets() async throws
    /// Starts one live analysis (one track). Throws when the assets are not
    /// installed; it never downloads.
    func startLiveAnalysis() async throws -> any AppleSpeechLiveAnalysis
    /// Runs one analyzer over a stored audio file and returns the final
    /// results. `onProgress` gets 0...1 of the audio.
    func analyzeFile(
        at url: URL, onProgress: @Sendable (Double) -> Void
    ) async throws -> AppleSpeechFileAnalysis
}

/// One live analysis.
nonisolated protocol AppleSpeechLiveAnalysis: Sendable {
    /// Appends 16 kHz mono Int16 samples (`MeetingAudioFormat`). Returns
    /// false when the audio was dropped (the bounded input queue was full or
    /// the buffer could not be made).
    func append(samples: Data, frameCount: Int) -> Bool
    /// Calls `handler` for each result until the analysis ends; throws the
    /// analysis error.
    func consumeResults(_ handler: @Sendable (AppleSpeechResult) async -> Void) async throws
    /// Ends the input, finalizes the remaining audio, and ends the results.
    func finish() async throws
    /// Stops at once and ends the results.
    func cancel() async
}

/// Errors of the real adapter.
nonisolated enum AppleSpeechError: Error, Equatable, Sendable {
    case transcriberUnavailable
    case unsupportedLocale
    case assetsNotInstalled
    case unreadableAudio
}
