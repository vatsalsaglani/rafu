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

/// The state of the detail view of one meeting. Owned by the view as private
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

    var showsEcho = false
    /// The question in the ask box. It stays until a run succeeds.
    var draft = ""
    var agent: MeetingAgentCLI {
        didSet { defaults.set(agent.rawValue, forKey: Self.lastAgentKey) }
    }
    private(set) var agentAvailability: [MeetingAgentCLI: MeetingAgentAvailability] = [:]
    private(set) var askState: MeetingAskState = .idle
    /// The action that waits for consent (shown as a confirmation dialog).
    var pendingConsent: MeetingPendingAgentAction?
    private(set) var agreedThisSession: Set<MeetingAgentCLI> = []

    private(set) var suggestions: [MeetingSpeakerNameSuggestion] = []
    private(set) var suggestState: MeetingAskState = .idle
    /// "The meeting changed. Try again." after a rename failed twice.
    private(set) var renameError: String?
    /// The turn that a citation opened, marked for a moment.
    var highlightedTurn: MeetingTurnID?
    /// Goes up each time a citation asks the transcript to scroll.
    private(set) var revealRequest = 0
    private(set) var textEngineAvailability: [MeetingTextEngineID: MeetingEngineAvailability] =
        [:]

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
    /// The ask box shows only for a `ready` meeting with a runner.
    var canAsk: Bool { hasRunner && isReady }

    var namesToCheck: [MeetingSpeakerLabel] {
        guard let overview else { return [] }
        return overview.speakerLabels.filter { $0 != .me && names.name(for: $0) == nil }
    }

    var shownTurns: [MeetingTurn] {
        showsEcho ? turns : turns.filter { !$0.isEcho }
    }

    var speakerOrder: [MeetingSpeakerLabel] { overview?.speakerLabels ?? [] }

    func displayName(for label: MeetingSpeakerLabel) -> String {
        names.displayName(for: label)
    }

    // MARK: Loading

    /// Reads the summary, the names, the conversation, the first pages and
    /// the overview. Keeps as many turns as were loaded before.
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
        var pages = 0
        while !turns.contains(where: { $0.id == turn }) {
            guard pages < MeetingDetailPresentation.maximumRevealPages, await loadMoreTurns()
            else { return false }
            pages += 1
        }
        if turns.first(where: { $0.id == turn })?.isEcho == true { showsEcho = true }
        highlightedTurn = turn
        revealRequest += 1
        return true
    }

    func refreshAvailability() async {
        if let checker = runner as? any MeetingAgentAvailabilityChecking {
            var result: [MeetingAgentCLI: MeetingAgentAvailability] = [:]
            for cli in MeetingAgentCLI.allCases {
                result[cli] = await checker.availability(of: cli)
            }
            agentAvailability = result
        }
        var engines: [MeetingTextEngineID: MeetingEngineAvailability] = [:]
        for (id, engine) in textEngines {
            engines[id] = await engine.availability()
        }
        textEngineAvailability = engines
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

    /// "Send" in the consent dialog.
    func confirmConsent() {
        guard let action = pendingConsent else { return }
        pendingConsent = nil
        agreedThisSession.insert(action.cli)
        run(action)
    }

    /// "Not now" in the consent dialog. Nothing runs.
    func declineConsent() {
        pendingConsent = nil
    }

    private func run(_ action: MeetingPendingAgentAction) {
        switch action {
        case .ask(let question, let cli): runAsk(question, cli: cli)
        case .suggestNames(let cli): runSuggestions(cli: cli)
        }
    }

    private func runAsk(_ question: String, cli: MeetingAgentCLI) {
        guard let runner, !askState.isRunning else { return }
        runToken += 1
        let token = runToken
        let meeting = meeting
        askState = .running(cli)
        runTask = Task { [weak self] in
            do {
                _ = try await runner.ask(question, about: meeting, using: cli)
                guard let self, token == self.runToken else { return }
                self.askState = .idle
                if MeetingDetailPresentation.cleanedQuestion(self.draft) == question {
                    self.draft = ""
                }
                if let reloaded = try? await self.store.conversation(of: meeting) {
                    self.conversation = reloaded
                }
            } catch {
                guard let self, token == self.runToken else { return }
                self.askState = Self.state(after: error)
            }
        }
    }

    /// Cancels the running question. Shows no error.
    func cancelAsk() {
        runToken += 1
        runTask?.cancel()
        runTask = nil
        askState = .idle
    }

    private func runSuggestions(cli: MeetingAgentCLI) {
        guard let runner, !suggestState.isRunning else { return }
        let meeting = meeting
        suggestState = .running(cli)
        suggestTask = Task { [weak self] in
            do {
                let suggested = try await runner.suggestSpeakerNames(for: meeting, using: cli)
                guard let self else { return }
                self.suggestions = MeetingDetailPresentation.usableSuggestions(
                    suggested, speakers: self.speakerOrder, names: self.names)
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
            return agentError == .cancelled ? .idle : .failed(agentError.message)
        }
        return .failed(MeetingAgentError.failed.message)
    }

    // MARK: Names

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

    func accept(_ suggestion: MeetingSpeakerNameSuggestion) async {
        await rename(suggestion.label, to: suggestion.name)
    }

    func dismiss(_ suggestion: MeetingSpeakerNameSuggestion) {
        suggestions.removeAll { $0 == suggestion }
    }
}
