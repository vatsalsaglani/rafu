import Foundation
import RafuCore

@testable import RafuApp

/// A temporary library with one synthetic meeting.
struct MeetingDetailFixture {
    let base: URL
    let store: MeetingStore
    let meeting: MeetingID

    /// Turns: Me, Speaker 1, an echo, Speaker 2, … `count` turns in all.
    static func make(
        turnCount: Int = 6, state: MeetingState = .ready,
        engines: MeetingEngineUse = MeetingEngineUse(textEngine: .appleSpeech)
    ) async throws -> MeetingDetailFixture {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "rafu-detail-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = MeetingStore(
            rootDirectory: base.appending(path: "Library", directoryHint: .isDirectory),
            snapshotRoot: base.appending(path: "Snapshots", directoryHint: .isDirectory))
        let created = try await store.create(title: "Weekly sync", startDate: Date())
        var version = created.version
        version = try await store.appendTurns(
            syntheticTurns(count: turnCount), to: created.id, expectedVersion: version)
        version = try await store.setEngines(engines, of: created.id, expectedVersion: version)
        version = try await store.setDuration(600, of: created.id, expectedVersion: version)
        try await store.setState(state, of: created.id, expectedVersion: version)
        return MeetingDetailFixture(base: base, store: store, meeting: created.id)
    }

    static func syntheticTurns(count: Int) -> [MeetingTurn] {
        (1...max(1, count)).map { number in
            let kind = (number - 1) % 4
            let speaker: MeetingSpeakerLabel =
                switch kind {
                case 0, 2: .me
                case 1: .speaker(1)
                default: .speaker(2)
                }
            return MeetingTurn(
                id: MeetingTurnID(number), track: speaker == .me ? .me : .them,
                speaker: speaker, start: Double(number * 10), end: Double(number * 10 + 5),
                text: "Line \(number)", isEcho: kind == 2)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    @MainActor
    func makeModel(
        runner: (any MeetingAgentRunning)?, store override: (any MeetingLibraryServicing)? = nil,
        textEngines: [MeetingTextEngineID: any MeetingTextEngine] = [:]
    ) -> MeetingDetailModel {
        let suite = TestDefaultsSuite.name("MeetingDetail")
        return MeetingDetailModel(
            meeting: meeting, store: override ?? store, runner: runner,
            textEngines: textEngines, defaults: UserDefaults(suiteName: suite) ?? .standard)
    }
}

/// A fake hidden agent. It never starts a process.
actor FakeMeetingAgentRunner: MeetingAgentRunning, MeetingAgentAvailabilityChecking {
    enum Behaviour: Sendable {
        /// Appends the question and an answer to the store (as the real
        /// runner does) and returns.
        case answer(String, citations: [MeetingCitation])
        case fail(MeetingAgentError)
        /// Waits until the task is cancelled.
        case waitForCancel
    }

    private let store: MeetingStore
    private var behaviour: Behaviour
    private var names: [MeetingSpeakerLabel: String]
    private(set) var askCount = 0
    private(set) var suggestCount = 0

    init(
        store: MeetingStore, behaviour: Behaviour,
        names: [MeetingSpeakerLabel: String] = [:]
    ) {
        self.store = store
        self.behaviour = behaviour
        self.names = names
    }

    func ask(_ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> MeetingAgentReply
    {
        askCount += 1
        switch behaviour {
        case .answer(let text, let citations):
            try await store.appendConversation(
                MeetingConversationEntry(date: Date(), role: .question, text: question),
                to: meeting)
            try await store.appendConversation(
                MeetingConversationEntry(
                    date: Date(), role: .answer, text: text, cli: cli, citations: citations),
                to: meeting)
            return MeetingAgentReply(cli: cli, text: text, citations: citations)
        case .fail(let error):
            throw error
        case .waitForCancel:
            let stream = AsyncStream<Void> { _ in }
            for await _ in stream {}
            throw MeetingAgentError.cancelled
        }
    }

    func suggestSpeakerNames(for meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> [MeetingSpeakerLabel: String]
    {
        suggestCount += 1
        return names
    }

    func availability(of cli: MeetingAgentCLI) async -> MeetingAgentAvailability {
        cli == .claudeCode ? .ready : .notInstalled
    }
}

/// A store that forwards to a real store, but whose first summary read
/// gives an old version, so the first rename meets a version conflict.
actor StaleOnceStore: MeetingLibraryServicing {
    let base: MeetingStore
    private var staleReads = 1
    private(set) var renameCalls = 0

    init(base: MeetingStore) { self.base = base }

    func summary(of meeting: MeetingID) async throws -> MeetingSummaryRecord? {
        guard var summary = try await base.summary(of: meeting) else { return nil }
        if staleReads > 0 {
            staleReads -= 1
            summary.version -= 1
        }
        return summary
    }

    func renameSpeaker(
        _ label: MeetingSpeakerLabel, to name: String, in meeting: MeetingID,
        expectedVersion: Int
    ) async throws -> Int {
        renameCalls += 1
        return try await base.renameSpeaker(
            label, to: name, in: meeting, expectedVersion: expectedVersion)
    }

    // Plain forwards.
    func create(title: String, startDate: Date) async throws -> MeetingSummaryRecord {
        try await base.create(title: title, startDate: startDate)
    }
    func list() async throws -> [MeetingSummaryRecord] { try await base.list() }
    func appendTurns(_ turns: [MeetingTurn], to meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { try await base.appendTurns(turns, to: meeting, expectedVersion: expectedVersion) }
    func turns(of meeting: MeetingID, after: MeetingTurnID?, limit: Int) async throws
        -> MeetingTurnPage
    { try await base.turns(of: meeting, after: after, limit: limit) }
    func setState(_ state: MeetingState, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { try await base.setState(state, of: meeting, expectedVersion: expectedVersion) }
    func rename(_ meeting: MeetingID, title: String, expectedVersion: Int) async throws -> Int {
        try await base.rename(meeting, title: title, expectedVersion: expectedVersion)
    }
    func delete(_ meeting: MeetingID) async throws { try await base.delete(meeting) }
    func search(_ query: String, limit: Int) async throws -> [MeetingSearchHit] {
        try await base.search(query, limit: limit)
    }
    func agentPacketText(of meeting: MeetingID) async throws -> String {
        try await base.agentPacketText(of: meeting)
    }
    func exportMarkdown(of meeting: MeetingID) async throws -> String {
        try await base.exportMarkdown(of: meeting)
    }
    func sizeOnDisk(of meeting: MeetingID) async throws -> MeetingSizes {
        try await base.sizeOnDisk(of: meeting)
    }
    func applyAudioRetention(_ retention: MeetingAudioRetention, now: Date) async throws {
        try await base.applyAudioRetention(retention, now: now)
    }
    func audioFolder(for meeting: MeetingID) async throws -> URL {
        try await base.audioFolder(for: meeting)
    }
    func setDuration(_ seconds: TimeInterval, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { try await base.setDuration(seconds, of: meeting, expectedVersion: expectedVersion) }
    func setEngines(_ engines: MeetingEngineUse, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { try await base.setEngines(engines, of: meeting, expectedVersion: expectedVersion) }
    func replaceTurns(_ turns: [MeetingTurn], in meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { try await base.replaceTurns(turns, in: meeting, expectedVersion: expectedVersion) }
    func editTurnText(
        _ turn: MeetingTurnID, to text: String, in meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int {
        try await base.editTurnText(turn, to: text, in: meeting, expectedVersion: expectedVersion)
    }
    func speakerNames(of meeting: MeetingID) async throws -> [MeetingSpeakerLabel: String] {
        try await base.speakerNames(of: meeting)
    }
    func appendConversation(_ entry: MeetingConversationEntry, to meeting: MeetingID)
        async throws -> Int
    { try await base.appendConversation(entry, to: meeting) }
    func conversation(of meeting: MeetingID) async throws -> [MeetingConversationEntry] {
        try await base.conversation(of: meeting)
    }
    func verifyCitations(_ citations: [MeetingCitation], in meeting: MeetingID) async throws
        -> MeetingCitationCheck
    { try await base.verifyCitations(citations, in: meeting) }
    func makeAgentSnapshot(of meeting: MeetingID) async throws -> MeetingAgentSnapshot {
        try await base.makeAgentSnapshot(of: meeting)
    }
    func document(of meeting: MeetingID) async throws -> MeetingDocument {
        try await base.document(of: meeting)
    }
    func exportMarkdown(of meeting: MeetingID, options: MeetingExportOptions) async throws
        -> String
    { try await base.exportMarkdown(of: meeting, options: options) }
    func readReport(of meeting: MeetingID) async throws -> MeetingReadReport {
        try await base.readReport(of: meeting)
    }
    func rebuildSearchIndex() async throws { try await base.rebuildSearchIndex() }
}

/// A text engine with a fixed availability. It never transcribes.
struct FakeDetailTextEngine: MeetingTextEngine {
    let id: MeetingTextEngineID
    let state: MeetingEngineAvailability
    var supportsLiveText: Bool { false }

    func availability() async -> MeetingEngineAvailability { state }
    func makeLiveSession(for track: MeetingTrack) async throws -> any MeetingLiveTextSession {
        throw MeetingAgentError.failed
    }
    func transcribe(
        _ request: MeetingFinalTextRequest, progress: @Sendable (MeetingEngineProgress) -> Void
    ) async throws -> MeetingTrackTranscript {
        throw MeetingAgentError.failed
    }
}
