import Foundation
import RafuCore
import Synchronization

/// The Apple speech text engine: live text for both tracks and the final text
/// from a stored file, with Apple's on-device `SpeechAnalyzer`. It runs in the
/// app (off the main actor); the model is in the system process
/// `localspeechrecognition`. Rafu downloads nothing for it.
@available(macOS 26, *)
nonisolated struct AppleSpeechEngine: MeetingTextEngine {
    let id = MeetingTextEngineID.appleSpeech
    let supportsLiveText = true

    private let analyzer: any AppleSpeechAnalyzing
    private let diagnostics: any MeetingDiagnosticsRecording
    private let now: @Sendable () -> TimeInterval
    private let loads = AppleSpeechLoadCounter()

    /// When the English speech assets are not on this Mac and the system
    /// cannot get them. The interface shows it beside the engine.
    static let unsupportedReason = "Apple speech has no English (US) model on this Mac"
    /// When the system must download its own English speech assets first
    /// (`availability()` is `.needsModel([])`: no Rafu model, a system one).
    static let systemDownloadReason =
        "Apple speech needs its English model from Apple. macOS downloads it when you allow it."

    init(
        analyzer: any AppleSpeechAnalyzing = SystemAppleSpeechAnalyzer(),
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.analyzer = analyzer
        self.diagnostics = diagnostics
        self.now = now
    }

    // MARK: Availability

    /// `.ready` when the English assets are installed; `.needsModel([])` when
    /// the system must download them first (see `systemDownloadReason`; the
    /// download is `installSystemAssets()`, on a user action);
    /// `.unavailable` when this Mac has no English speech.
    func availability() async -> MeetingEngineAvailability {
        switch await analyzer.assetStatus() {
        case .installed: .ready
        case .needsSystemDownload, .downloading: .needsModel([])
        case .unsupported: .unavailable(reason: Self.unsupportedReason)
        }
    }

    /// The reason to show beside `availability()`, or nil when ready.
    func availabilityReason() async -> String? {
        switch await analyzer.assetStatus() {
        case .installed: nil
        case .needsSystemDownload, .downloading: Self.systemDownloadReason
        case .unsupported: Self.unsupportedReason
        }
    }

    /// Asks macOS to download its English speech assets. Call it only from a
    /// user action.
    func installSystemAssets() async throws {
        do {
            try await analyzer.installSystemAssets()
        } catch {
            diagnostics.record(AppleSpeechErrorFacts.event(for: error), meeting: nil)
            throw error
        }
    }

    // MARK: Live text

    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        let started = now()
        let analysis: any AppleSpeechLiveAnalysis
        do {
            analysis = try await analyzer.startLiveAnalysis()
        } catch {
            diagnostics.record(AppleSpeechErrorFacts.event(for: error), meeting: nil)
            throw error
        }
        diagnostics.record(
            .textEngineLoaded(
                engine: .appleSpeech, model: nil, modelRevision: nil,
                loadMilliseconds: AppleSpeechLiveStats.milliseconds(now() - started),
                isCold: loads.markLoaded()),
            meeting: nil)
        return await AppleSpeechLiveSession.start(
            track: track, analysis: analysis, diagnostics: diagnostics, now: now)
    }

    // MARK: Final text

    /// The final text of one track from its stored file. The caller runs the
    /// two tracks one after the other. Times are seconds on the meeting clock:
    /// the stored file of a track starts at meeting time 0.
    func transcribe(
        _ request: MeetingFinalTextRequest,
        progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        progress(.preparingModel)
        let started = now()
        let analysis: AppleSpeechFileAnalysis
        do {
            analysis = try await analyzer.analyzeFile(at: request.audioFile) { fraction in
                progress(.working(fraction: min(1, max(0, fraction))))
            }
        } catch {
            diagnostics.record(AppleSpeechErrorFacts.event(for: error), meeting: request.meeting)
            throw error
        }
        diagnostics.record(
            .textEngineLoaded(
                engine: .appleSpeech, model: nil, modelRevision: nil,
                loadMilliseconds: analysis.loadMilliseconds, isCold: loads.markLoaded()),
            meeting: request.meeting)

        let words = Self.words(from: analysis.results)
        progress(.working(fraction: 1))
        diagnostics.record(
            .finalTextDone(
                engine: .appleSpeech, track: request.track, audioSeconds: analysis.audioSeconds,
                wallSeconds: max(0, now() - started)),
            meeting: request.meeting)
        return MeetingTrackTranscript(track: request.track, words: words, engine: .appleSpeech)
    }

    /// The words of the final results, in time order.
    static func words(from results: [AppleSpeechResult]) -> [MeetingWord] {
        // Split into typed steps: as one chain this expression timed out in
        // the type checker on the CI runner (not on a faster Mac).
        var collected: [MeetingWord] = []
        for result in results where result.isFinal {
            let resultWords: [MeetingWord] = AppleSpeechWords.words(
                from: result.runs, fallback: result.range
            ) { $0 }
            collected.append(contentsOf: resultWords)
        }
        let indexed: [(offset: Int, word: MeetingWord)] = collected.enumerated().map {
            (offset: $0.offset, word: $0.element)
        }
        let ordered = indexed.sorted { (lhs, rhs) -> Bool in
            if lhs.word.start == rhs.word.start { return lhs.offset < rhs.offset }
            return lhs.word.start < rhs.word.start
        }
        return ordered.map(\.word)
    }
}

/// Counts analyzer loads in this engine: the first is "cold".
nonisolated final class AppleSpeechLoadCounter: Sendable {
    private let loaded = Mutex(false)

    /// Returns true for the first load (cold), false after it.
    func markLoaded() -> Bool {
        loaded.withLock { loaded in
            defer { loaded = true }
            return !loaded
        }
    }
}
