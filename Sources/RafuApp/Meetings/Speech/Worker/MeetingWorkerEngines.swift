import Foundation
import RafuCore
import Synchronization

/// What the four helper engines share: the process client, the model
/// locator and diagnostics.
nonisolated struct MeetingWorkerEngineContext: Sendable {
    let process: MeetingWorkerProcess
    let locator: any MeetingModelLocating
    let diagnostics: any MeetingDiagnosticsRecording
    let platform: MeetingsAvailability

    func availability(of model: MeetingModelID) async -> MeetingEngineAvailability {
        if let reason = platform.unavailableReason { return .unavailable(reason: reason) }
        guard process.helperURL != nil else {
            return .unavailable(reason: MeetingWorkerError.helperMissing.userMessage)
        }
        guard await locator.installedFolder(for: model) != nil else { return .needsModel([model]) }
        return .ready
    }

    /// The installed model folder, or `modelMissing`.
    func folder(for model: MeetingModelID) async throws(MeetingWorkerError) -> URL {
        guard process.helperURL != nil else { throw .helperMissing }
        guard let folder = await locator.installedFolder(for: model) else {
            throw .modelMissing(model)
        }
        return folder
    }

    /// The model revision of an installed folder: the catalog installs to
    /// `…/Models/<model id>/<revision>/`.
    static func revision(of folder: URL) -> String {
        folder.standardizedFileURL.lastPathComponent
    }

    func fileRequest(engine: MeetingWorkerEngineID, audioFile: URL) async throws(MeetingWorkerError)
        -> (MeetingWorkerRequest, URL)
    {
        let folder = try await folder(for: engine.model)
        guard audioFile.isFileURL else { throw .badRequest }
        return (
            MeetingWorkerRequest(
                engine: engine, modelFolder: folder.standardizedFileURL.path,
                audioFile: audioFile.standardizedFileURL.path),
            folder
        )
    }

    func transcribe(
        engine: MeetingWorkerEngineID, textEngine: MeetingTextEngineID,
        request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        let (workerRequest, folder) = try await fileRequest(
            engine: engine, audioFile: request.audioFile)
        let result = try await process.runFileJob(
            mode: .finalText, request: workerRequest, meeting: request.meeting, progress: progress)
        diagnostics.record(
            .finalTextDone(
                engine: textEngine, track: request.track, audioSeconds: result.audioSeconds ?? 0,
                wallSeconds: result.wallSeconds),
            meeting: request.meeting)
        return MeetingTrackTranscript(
            track: request.track, words: result.words, engine: textEngine, model: engine.model,
            modelRevision: Self.revision(of: folder))
    }

    func diarize(engine: MeetingWorkerEngineID, request: MeetingSpeakerRequest) async throws
        -> [MeetingSpeakerSegment]
    {
        let (workerRequest, _) = try await fileRequest(engine: engine, audioFile: request.audioFile)
        let result = try await process.runFileJob(
            mode: .speakers, request: workerRequest, meeting: request.meeting, progress: { _ in })
        return result.segments
    }
}

/// Nemotron English text (FluidAudio, 1120 ms chunks) in the helper: live
/// text for both tracks through one helper, and the final text after Stop.
nonisolated final class NemotronTextEngine: MeetingTextEngine {
    let id: MeetingTextEngineID = .nemotronEnglish
    let supportsLiveText = true
    private let context: MeetingWorkerEngineContext
    private let footprintLimitBytes: Int64
    /// The hub of the current recording; both tracks share it.
    private let currentHub = Mutex<MeetingWorkerLiveHub?>(nil)

    init(
        context: MeetingWorkerEngineContext,
        footprintLimitBytes: Int64 = MeetingWorkerLiveHub.defaultFootprintLimitBytes
    ) {
        self.context = context
        self.footprintLimitBytes = footprintLimitBytes
    }

    func availability() async -> MeetingEngineAvailability {
        await context.availability(of: .nemotronEnglish1120)
    }

    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        _ = try await context.folder(for: .nemotronEnglish1120)
        let hub = liveHub()
        let events = await hub.openSession(for: track)
        return MeetingWorkerLiveTextSession(hub: hub, track: track, events: events)
    }

    /// The current hub, or a new one when there is none or it has ended.
    /// Chosen under one lock, so two tracks that start at once share a hub.
    private func liveHub() -> MeetingWorkerLiveHub {
        let context = context
        let limit = footprintLimitBytes
        return currentHub.withLock { current in
            if let existing = current, !existing.isEndedFlag { return existing }
            let hub = MeetingWorkerLiveHub(
                process: context.process, footprintLimitBytes: limit,
                diagnostics: context.diagnostics,
                makeRequest: { () async throws(MeetingWorkerError) -> MeetingWorkerRequest in
                    // Read the folder again at each start: a restart after a
                    // model update uses the installed folder.
                    let folder = try await context.folder(for: .nemotronEnglish1120)
                    return MeetingWorkerRequest(
                        engine: .nemotronEnglish, modelFolder: folder.standardizedFileURL.path)
                })
            current = hub
            return hub
        }
    }

    func transcribe(
        _ request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        try await context.transcribe(
            engine: .nemotronEnglish, textEngine: id, request: request, progress: progress)
    }
}

/// WhisperKit large-v3 text in the helper, after Stop only. A cold load is
/// about 58 s: `progress` gets `.preparingModel` until the model is ready.
nonisolated final class WhisperKitTextEngine: MeetingTextEngine {
    let id: MeetingTextEngineID = .whisperKit
    let supportsLiveText = false
    private let context: MeetingWorkerEngineContext

    init(context: MeetingWorkerEngineContext) {
        self.context = context
    }

    func availability() async -> MeetingEngineAvailability {
        await context.availability(of: .whisperLargeV3)
    }

    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        throw MeetingWorkerError.liveTextNotSupported
    }

    func transcribe(
        _ request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        try await context.transcribe(
            engine: .whisperKit, textEngine: id, request: request, progress: progress)
    }
}

/// Nemotron 3 speakers (`fast32`) in the helper, on the "Them" track after
/// Stop.
nonisolated final class Nemotron3SpeakerEngine: MeetingSpeakerEngine {
    let id: MeetingSpeakerEngineID = .nemotron3
    private let context: MeetingWorkerEngineContext

    init(context: MeetingWorkerEngineContext) {
        self.context = context
    }

    func availability() async -> MeetingEngineAvailability {
        await context.availability(of: .nemotron3Fast32)
    }

    func diarize(_ request: MeetingSpeakerRequest) async throws -> [MeetingSpeakerSegment] {
        try await context.diarize(engine: .nemotron3, request: request)
    }
}

/// SpeakerKit speakers (automatic count) in the helper, on the "Them"
/// track after Stop.
nonisolated final class SpeakerKitSpeakerEngine: MeetingSpeakerEngine {
    let id: MeetingSpeakerEngineID = .speakerKit
    private let context: MeetingWorkerEngineContext

    init(context: MeetingWorkerEngineContext) {
        self.context = context
    }

    func availability() async -> MeetingEngineAvailability {
        await context.availability(of: .speakerKit)
    }

    func diarize(_ request: MeetingSpeakerRequest) async throws -> [MeetingSpeakerSegment] {
        try await context.diarize(engine: .speakerKit, request: request)
    }
}
