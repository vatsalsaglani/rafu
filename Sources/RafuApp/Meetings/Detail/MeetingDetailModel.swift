import Foundation
import Observation
import RafuCore

/// An agent action that waits for the user's consent.
nonisolated enum MeetingPendingAgentAction: Hashable, Sendable, Identifiable {
    case ask(question: String, cli: MeetingAgentCLI)
    case suggestNames(cli: MeetingAgentCLI)

    var id: Self { self }

    var cli: MeetingAgentCLI {
        switch self {
        case .ask(_, let cli), .suggestNames(let cli): cli
        }
    }
}

/// The state of the view of one meeting. Owned by the view as private
/// `@State`, made for one meeting id and dropped with the view. It holds the
/// loaded transcript pages only (200 turns for each page), never the whole
/// meeting; the overview is computed from one short-lived document read.
@MainActor
@Observable
final class MeetingDetailModel {
    let meeting: MeetingID

    private(set) var summary: MeetingSummaryRecord?
    private(set) var names = MeetingSpeakerNames()
    private(set) var overview: MeetingOverview?
    private(set) var conversation: [MeetingConversationEntry] = []
    /// The loaded pages of turns, in order.
    private(set) var turns: [MeetingTurn] = []
    private(set) var hasMoreTurns = false
    private(set) var loadFailed = false

    /// Repeated lines (the call sound heard again through the microphone)
    /// show in the transcript.
    var showsRepeated = false
    /// The question in the ask box. It clears when the question is sent.
    var draft = ""
    var agent: MeetingAgentCLI {
        didSet { defaults.set(agent.rawValue, forKey: Self.lastAgentKey) }
    }
    /// The probe result of each agent. Empty until the first check ends.
    private(set) var probeResults: [MeetingAgentCLI: MeetingAgentProbeResult] = [:]
    private(set) var askState: MeetingAskState = .idle
    /// The question that was sent and is not stored yet.
    private(set) var pendingQuestion: MeetingPendingQuestion?
    /// The answer text so far. It changes at most ten times a second.
    private(set) var streamingText = ""
    /// The action that waits for consent (shown as a Rafu popup).
    var pendingConsent: MeetingPendingAgentAction?
    private(set) var agreedThisSession: Set<MeetingAgentCLI> = []

    private(set) var suggestions: [MeetingSpeakerNameSuggestion] = []
    private(set) var suggestState: MeetingAskState = .idle
    private(set) var suggestOutcome: MeetingNameSuggestionOutcome?
    /// "The meeting changed. Try again." after a rename failed twice.
    private(set) var renameError: String?
    /// The turn that a citation opened, marked for a moment.
    var highlightedTurn: MeetingTurnID?
    /// The turn that the transcript scrolls to next. The view clears it.
    var revealTarget: MeetingTurnID?
    /// Goes up each time the transcript must scroll to `revealTarget`.
    private(set) var revealRequest = 0
    private(set) var textEngineAvailability: [MeetingTextEngineID: MeetingEngineAvailability] =
        [:]

    /// The summary notes of the meeting, when the store has them.
    private(set) var summaryNotes: MeetingSummaryNotes?
    /// The text revision of the meeting. Nil when the store cannot tell.
    private(set) var textRevision: Int?

    /// The transcript search.
    var searchQuery = ""
    private(set) var searchMatches: [MeetingTurnID] = []
    private(set) var searchIndex: Int?
    /// True when the search stopped at 20 pages (4,000 lines).
    private(set) var searchHitLimit = false

    /// The private `UserDefaults` key of the last used agent.
    static let lastAgentKey = "meetings.detail.lastAgent"

    @ObservationIgnored private let store: any MeetingLibraryServicing
    @ObservationIgnored private let runner: (any MeetingAgentRunning)?
    @ObservationIgnored private let textEngines: [MeetingTextEngineID: any MeetingTextEngine]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onLibraryChanged: @MainActor () -> Void
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?
    @ObservationIgnored private(set) var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var runToken = 0
    @ObservationIgnored private var streamBuffer = ""
    @ObservationIgnored private var throttle = MeetingStreamThrottle()
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(
        meeting: MeetingID,
        store: any MeetingLibraryServicing,
        runner: (any MeetingAgentRunning)?,
        textEngines: [MeetingTextEngineID: any MeetingTextEngine] = [:],
        defaults: UserDefaults = .standard,
        onLibraryChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.meeting = meeting
        self.store = store
        self.runner = runner
        self.textEngines = textEngines
        self.defaults = defaults
        self.onLibraryChanged = onLibraryChanged
        self.agent =
            defaults.string(forKey: Self.lastAgentKey).flatMap(MeetingAgentCLI.init(rawValue:))
            ?? .claudeCode
    }

    // MARK: Derived values

    var isReady: Bool { summary?.state == .ready }
    var hasRunner: Bool { runner != nil }
    /// True after the probe found no agent that can answer.
    var hasNoReadyAgent: Bool {
        !probeResults.isEmpty && !probeResults.values.contains(where: \.isReady)
    }
    /// The ask box sends only for a `ready` meeting with a runner and an
    /// agent that passed the probe (or before the probe ended).
    var canAsk: Bool { hasRunner && isReady && !hasNoReadyAgent }

    /// The shown speakers with no name yet, other than "Me".
    var namesToCheck: [MeetingSpeakerLabel] {
        guard let overview else { return [] }
        return overview.shownSpeakers.map(\.speaker)
            .filter { $0 != .me && names.name(for: $0) == nil }
    }

    var shownTurns: [MeetingTurn] {
        showsRepeated ? turns : turns.filter { !$0.isEcho }
    }

    var groups: [MeetingTurnGroup] { MeetingDetailPresentation.groups(shownTurns) }

    var speakerOrder: [MeetingSpeakerLabel] { overview?.speakerLabels ?? [] }

    var turnRefs: [MeetingTurnID: MeetingTurnRef] { overview?.turnRefs ?? [:] }

    var currentSearchMatch: MeetingTurnID? {
        guard let searchIndex, searchMatches.indices.contains(searchIndex) else { return nil }
        return searchMatches[searchIndex]
    }

    func displayName(for label: MeetingSpeakerLabel) -> String {
        names.displayName(for: label)
    }

    /// The group that holds `turn` in the shown transcript.
    func groupID(containing turn: MeetingTurnID) -> MeetingTurnID? {
        groups.first { group in group.turns.contains { $0.id == turn } }?.id
    }

    // MARK: Loading

    /// Reads the summary, the names, the conversation, the first pages, the
    /// overview and the summary notes. Keeps as many turns as were loaded.
    func reload() async {
        do {
            guard let summary = try await store.summary(of: meeting) else {
                self.summary = nil
                loadFailed = true
                return
            }
            self.summary = summary
            names = MeetingSpeakerNames(names: try await store.speakerNames(of: meeting))
            conversation = try await store.conversation(of: meeting)
            loadFailed = false
            guard summary.state == .ready else { return }
            let count = max(MeetingDetailPresentation.pageSize, turns.count)
            let page = try await store.turns(of: meeting, after: nil, limit: count)
            turns = page.turns
            hasMoreTurns = page.nextAfter != nil
            overview = try await Self.loadOverview(store: store, meeting: meeting)
            await loadSummaryNotes()
        } catch {
            loadFailed = true
        }
    }

    /// Reads the whole meeting once, away from the main actor, and keeps
    /// only the numbers of the overview. The document is dropped here.
    @concurrent
    nonisolated private static func loadOverview(
        store: any MeetingLibraryServicing, meeting: MeetingID
    ) async throws -> MeetingOverview {
        let document = try await store.document(of: meeting)
        return MeetingDetailPresentation.overview(document: document)
    }

    /// Reads the summary notes and the text revision, when the store keeps
    /// them.
    func loadSummaryNotes() async {
        guard let notesStore = store as? any MeetingNotesStoring else { return }
        summaryNotes = try? await notesStore.summaryNotes(of: meeting)
        textRevision = try? await notesStore.textRevision(of: meeting)
    }

    /// Loads the next page of turns.
    @discardableResult
    func loadMoreTurns() async -> Bool {
        guard hasMoreTurns, let last = turns.last else { return false }
        do {
            let page = try await store.turns(
                of: meeting, after: last.id, limit: MeetingDetailPresentation.pageSize)
            turns.append(contentsOf: page.turns)
            hasMoreTurns = page.nextAfter != nil
            return !page.turns.isEmpty
        } catch {
            hasMoreTurns = false
            return false
        }
    }

    /// Loads pages until `turn` is there (at most 20 pages), marks it and
    /// asks the transcript to scroll to it. Returns false when it is not
    /// found.
    @discardableResult
    func reveal(_ turn: MeetingTurnID) async -> Bool {
        guard await load(turn) else { return false }
        highlightedTurn = turn
        requestScroll(to: turn)
        return true
    }

    private func load(_ turn: MeetingTurnID) async -> Bool {
        var pages = 0
        while !turns.contains(where: { $0.id == turn }) {
            guard pages < MeetingDetailPresentation.maximumRevealPages, await loadMoreTurns()
            else { return false }
            pages += 1
        }
        if turns.first(where: { $0.id == turn })?.isEcho == true { showsRepeated = true }
        return true
    }

    private func requestScroll(to turn: MeetingTurnID) {
        revealTarget = turn
        revealRequest += 1
    }

    func refreshEngines() async {
        var engines: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in textEngines {
            engines[id] = await engine.availability()
        }
        textEngineAvailability = engines
    }

    /// Reads the probe result of each agent. When the chosen agent did not
    /// pass and another did, the other becomes the choice.
    func refreshAgents() async {
        guard let runner else { return }
        var results: [MeetingAgentCLI: MeetingAgentProbeResult] = [:]
        if let prober = runner as? any MeetingAgentProbing {
            results = await withTaskGroup(
                of: (MeetingAgentCLI, MeetingAgentProbeResult).self
            ) { group in
                for cli in MeetingAgentCLI.allCases {
                    group.addTask { (cli, await prober.probe(cli, refresh: false)) }
                }
                var collected: [MeetingAgentCLI: MeetingAgentProbeResult] = [:]
                for await (cli, result) in group { collected[cli] = result }
                return collected
            }
        } else if let checker = runner as? any MeetingAgentAvailabilityChecking {
            for cli in MeetingAgentCLI.allCases {
                results[cli] = MeetingDetailPresentation.probeResult(
                    await checker.availability(of: cli))
            }
        } else {
            return
        }
        probeResults = results
        if results[agent]?.isReady != true,
            let ready = MeetingAgentCLI.allCases.first(where: { results[$0]?.isReady == true })
        {
            agent = ready
        }
    }

    // MARK: Search

    /// Finds the query in the loaded turns. It loads more pages first, up
    /// to 20 pages; past that it tells the user.
    func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchMatches = []
            searchIndex = nil
            searchHitLimit = false
            return
        }
        var pages =
            (turns.count + MeetingDetailPresentation.pageSize - 1)
            / MeetingDetailPresentation.pageSize
        while hasMoreTurns, pages < MeetingDetailPresentation.maximumRevealPages {
            guard await loadMoreTurns() else { break }
            pages += 1
        }
        guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        searchHitLimit = hasMoreTurns
        searchMatches = MeetingDetailPresentation.searchMatches(query, in: shownTurns)
        searchIndex = searchMatches.isEmpty ? nil : 0
        if let current = currentSearchMatch { requestScroll(to: current) }
    }

    func nextMatch() { moveMatch(by: 1) }
    func previousMatch() { moveMatch(by: -1) }

    private func moveMatch(by step: Int) {
        guard !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        searchIndex = ((searchIndex ?? -step) + step + count) % count
        if let current = currentSearchMatch { requestScroll(to: current) }
    }

    // MARK: Asking

    /// Asks `question` with the chosen agent. Before the first run for this
    /// meeting and agent, the consent waits in `pendingConsent`.
    func requestAsk(_ question: String) {
        let text = MeetingDetailPresentation.cleanedQuestion(question)
        guard canAsk, !text.isEmpty, !askState.isRunning else { return }
        request(.ask(question: text, cli: agent))
    }

    func requestNameSuggestions() {
        guard canAsk, !suggestState.isRunning else { return }
        request(.suggestNames(cli: agent))
    }

    private func request(_ action: MeetingPendingAgentAction) {
        if MeetingDetailPresentation.needsConsent(
            cli: action.cli, conversation: conversation, askedThisSession: agreedThisSession)
        {
            pendingConsent = action
        } else {
            run(action)
        }
    }

    /// "Send" in the consent popup.
    func confirmConsent() {
        guard let action = pendingConsent else { return }
        pendingConsent = nil
        agreedThisSession.insert(action.cli)
        run(action)
    }

    /// "Cancel" in the consent popup. Nothing runs.
    func declineConsent() {
        pendingConsent = nil
    }

    private func run(_ action: MeetingPendingAgentAction) {
        switch action {
        case .ask(let question, let cli): runAsk(question, cli: cli)
        case .suggestNames(let cli): runSuggestions(cli: cli)
        }
    }

    /// Shows the question at once, clears the field, and streams the
    /// answer.
    private func runAsk(_ question: String, cli: MeetingAgentCLI) {
        guard let runner, !askState.isRunning else { return }
        runToken += 1
        let token = runToken
        let meeting = meeting
        askState = .running(cli)
        pendingQuestion = MeetingPendingQuestion(text: question, cli: cli, date: Date())
        if MeetingDetailPresentation.cleanedQuestion(draft) == question { draft = "" }
        resetStream()
        runTask = Task { [weak self] in
            do {
                if let streaming = runner as? any MeetingAgentStreaming {
                    let stream = streaming.askStream(question, about: meeting, using: cli)
                    for try await event in stream {
                        guard let self, token == self.runToken else { return }
                        switch event {
                        case .started: break
                        case .textDelta(let delta): self.appendStream(delta)
                        case .textReset: self.resetStream()
                        case .finished: break
                        }
                    }
                } else {
                    _ = try await runner.ask(question, about: meeting, using: cli)
                }
                guard let self, token == self.runToken else { return }
                await self.finishAsk(token: token)
            } catch {
                guard let self, token == self.runToken else { return }
                self.failAsk(error)
            }
        }
    }

    private func finishAsk(token: Int) async {
        if let reloaded = try? await store.conversation(of: meeting) {
            guard token == runToken else { return }
            conversation = reloaded
        }
        guard token == runToken else { return }
        askState = .idle
        pendingQuestion = nil
        resetStream()
    }

    private func failAsk(_ error: any Error) {
        resetStream()
        switch Self.state(after: error) {
        case .idle:
            restoreDraft()
            askState = .idle
        case .busy:
            restoreDraft()
            askState = .busy
        case let state:
            askState = state
        }
    }

    /// "Try Again" under a failed question: it goes back into the field.
    func retryFailedQuestion() {
        restoreDraft()
        askState = .idle
    }

    /// Puts the pending question back into an empty field.
    private func restoreDraft() {
        if let pending = pendingQuestion, draft.isEmpty { draft = pending.text }
        pendingQuestion = nil
    }

    /// Stops the running question (Stop, Escape). Shows no error; the
    /// question goes back into an empty field.
    func cancelAsk() {
        runToken += 1
        runTask?.cancel()
        runTask = nil
        resetStream()
        restoreDraft()
        askState = .idle
    }

    /// Stops a question run of this meeting that another view started.
    func stopOtherRun() async {
        guard let streaming = runner as? any MeetingAgentStreaming else { return }
        await streaming.cancelRun(.question, for: meeting)
    }

    // MARK: Streaming

    private func appendStream(_ delta: String) {
        streamBuffer += delta
        let now = ContinuousClock.now
        if throttle.shouldPublish(at: now) {
            streamingText = streamBuffer
        } else if flushTask == nil {
            let wait = throttle.delay(at: now)
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.flushTask = nil
                self.throttle.reset()
                _ = self.throttle.shouldPublish(at: ContinuousClock.now)
                self.streamingText = self.streamBuffer
            }
        }
    }

    private func resetStream() {
        flushTask?.cancel()
        flushTask = nil
        streamBuffer = ""
        streamingText = ""
        throttle.reset()
    }

    // MARK: Names

    private func runSuggestions(cli: MeetingAgentCLI) {
        guard let runner, !suggestState.isRunning else { return }
        let meeting = meeting
        suggestState = .running(cli)
        suggestOutcome = nil
        suggestTask = Task { [weak self] in
            do {
                let suggested: [MeetingSpeakerLabel: String]
                if let streaming = runner as? any MeetingAgentStreaming {
                    switch try await streaming.suggestSpeakerNameResult(for: meeting, using: cli) {
                    case .names(let names): suggested = names
                    case .noNamesFound, .nothingToName: suggested = [:]
                    }
                } else {
                    suggested = try await runner.suggestSpeakerNames(for: meeting, using: cli)
                }
                guard let self else { return }
                self.suggestions = MeetingDetailPresentation.usableSuggestions(
                    suggested, speakers: self.speakerOrder, names: self.names)
                self.suggestOutcome = self.suggestions.isEmpty ? .noNamesFound(cli) : nil
                self.suggestState = .idle
            } catch {
                self?.suggestState = Self.state(after: error)
            }
        }
    }

    func cancelSuggestions() {
        suggestTask?.cancel()
        suggestTask = nil
        suggestState = .idle
    }

    /// Ends each agent run of this view when the view goes away (another
    /// meeting is selected, the tab or the window closes): a hidden run
    /// never goes on with no visible sign. The consent that waits is dropped.
    func cancelRunsOnDisappear() {
        pendingConsent = nil
        if runTask != nil || askState.isRunning { cancelAsk() }
        if suggestTask != nil || suggestState.isRunning { cancelSuggestions() }
    }

    private nonisolated static func state(after error: any Error) -> MeetingAskState {
        if error is CancellationError { return .idle }
        if let agentError = error as? MeetingAgentError {
            switch agentError {
            case .cancelled: return .idle
            case .busy: return .busy
            default: return .failed(agentError.message)
            }
        }
        return .failed(MeetingAgentError.failed.message)
    }

    /// Saves a name through the store. A version conflict is tried one more
    /// time with the version read again. An empty name clears the name.
    @discardableResult
    func rename(_ label: MeetingSpeakerLabel, to name: String) async -> Bool {
        renameError = nil
        for attempt in 0..<2 {
            do {
                guard let current = try await store.summary(of: meeting) else { break }
                try await store.renameSpeaker(
                    label, to: name, in: meeting, expectedVersion: current.version)
                names = MeetingSpeakerNames(names: try await store.speakerNames(of: meeting))
                summary = try await store.summary(of: meeting) ?? summary
                suggestions.removeAll { $0.label == label }
                onLibraryChanged()
                return true
            } catch is MeetingVersionConflict where attempt == 0 {
                continue
            } catch {
                break
            }
        }
        renameError = "The meeting changed. Try again."
        return false
    }

    /// Renames the meeting. A version conflict is tried one more time.
    @discardableResult
    func renameMeeting(to title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for attempt in 0..<2 {
            do {
                guard let current = try await store.summary(of: meeting) else { return false }
                try await store.rename(meeting, title: trimmed, expectedVersion: current.version)
                summary = try await store.summary(of: meeting) ?? summary
                onLibraryChanged()
                return true
            } catch is MeetingVersionConflict where attempt == 0 {
                continue
            } catch {
                return false
            }
        }
        return false
    }

    func accept(_ suggestion: MeetingSpeakerNameSuggestion) async {
        await rename(suggestion.label, to: suggestion.name)
    }

    func dismiss(_ suggestion: MeetingSpeakerNameSuggestion) {
        suggestions.removeAll { $0 == suggestion }
    }

    func dismissSuggestOutcome() {
        suggestOutcome = nil
    }
}
