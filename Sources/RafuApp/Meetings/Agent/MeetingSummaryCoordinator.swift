import Foundation
import RafuCore

/// Writes the title and summary of a meeting after each processing job,
/// unless Settings ▸ Meetings turns it off (`meetings.autoSummary`, on by
/// default), and when the user asks. The run sends the transcript and the
/// speaker names to the provider of the chosen agent; it never sends audio.
///
/// The agent is the one the user chose last in the ask box, else Claude
/// Code, else Codex: the first whose probe is ready. With none ready the
/// state is `unavailable` and no run starts. One summary run for each
/// meeting at a time: a new start cancels the older run first. Notes for a
/// text that was made again while the agent ran are not saved (the state is
/// `stale`; the next processing job writes new notes). Installed by the
/// agent registration, which keeps it alive through the session handlers.
@MainActor
final class MeetingSummaryCoordinator {
    typealias StoreProvider = @MainActor () -> (any MeetingStoring)?

    private weak var session: MeetingsSessionModel?
    private let agent: any MeetingAgentSummarizing
    private let store: StoreProvider
    private let defaults: UserDefaults

    private var tasks: [MeetingID: Task<Void, Never>] = [:]
    private var tokens: [MeetingID: Int] = [:]

    init(
        session: MeetingsSessionModel, agent: any MeetingAgentSummarizing,
        store: @escaping StoreProvider, defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.agent = agent
        self.store = store
        self.defaults = defaults
    }

    /// Installs the summary handlers of the session. The handlers keep the
    /// coordinator; the coordinator keeps the session weakly.
    func install() {
        session?.summaryHandlers = MeetingsSummaryHandlers(
            afterProcessing: { meeting in self.afterProcessing(meeting) },
            make: { meeting in self.start(meeting) },
            cancel: { meeting in self.cancel(meeting) },
            refresh: { meeting in self.refresh(meeting) })
    }

    // MARK: - Handlers

    func afterProcessing(_ meeting: MeetingID) {
        guard MeetingAutoSummaryPreference.isOn(defaults) else { return }
        start(meeting)
    }

    func start(_ meeting: MeetingID) {
        guard let session else { return }
        let previous = tasks[meeting]
        previous?.cancel()
        let token = (tokens[meeting] ?? 0) + 1
        tokens[meeting] = token
        session.summaryStates[meeting] = .generating
        session.summaryStepActive.insert(meeting)
        let agent = agent
        tasks[meeting] = Task { [weak self] in
            if let previous {
                await agent.cancelRun(.summary, for: meeting)
                await previous.value
            }
            await self?.run(meeting, token: token)
        }
    }

    func cancel(_ meeting: MeetingID) {
        guard let task = tasks[meeting] else { return }
        task.cancel()
        let agent = agent
        Task { await agent.cancelRun(.summary, for: meeting) }
    }

    /// Reads one notes file and the text revision (no library scan).
    func refresh(_ meeting: MeetingID) {
        Task { await self.refreshNow(meeting) }
    }

    /// `refresh`, awaited. A meeting whose summary is being written keeps
    /// that state.
    func refreshNow(_ meeting: MeetingID) async {
        guard tasks[meeting] == nil else { return }
        let token = tokens[meeting] ?? 0
        guard let state = await storedState(of: meeting) else { return }
        guard tasks[meeting] == nil, (tokens[meeting] ?? 0) == token else { return }
        session?.summaryStates[meeting] = state
    }

    /// Waits for the summary run of a meeting to end (tests).
    func waitForRun(of meeting: MeetingID) async {
        await tasks[meeting]?.value
    }

    // MARK: - One run

    private func run(_ meeting: MeetingID, token: Int) async {
        let state = await makeSummary(meeting)
        guard tokens[meeting] == token else { return }
        tasks[meeting] = nil
        if let session {
            if let state {
                session.summaryStates[meeting] = state
            } else {
                // Cancelled: show what is on disk.
                session.summaryStates[meeting] =
                    await storedState(of: meeting) ?? MeetingSummaryState.none
            }
            session.summaryStepActive.remove(meeting)
        }
    }

    /// The state after one run; nil when it was cancelled.
    private func makeSummary(_ meeting: MeetingID) async -> MeetingSummaryState? {
        guard let cli = await chooseAgent() else {
            return Task.isCancelled ? nil : .unavailable
        }
        if Task.isCancelled { return nil }
        do {
            let notes = try await agent.summarize(meeting, using: cli)
            guard let notesStore = store() as? any MeetingNotesStoring else {
                return .failed(.failed)
            }
            guard try await notesStore.saveSummaryNotes(notes, for: meeting) else {
                return .stale
            }
            _ = try? await notesStore.applyGeneratedTitle(notes.title, to: meeting)
            session?.noteLibraryChanged()
            return .ready
        } catch MeetingAgentError.cancelled {
            return nil
        } catch let error as MeetingAgentError {
            return .failed(error)
        } catch {
            return Task.isCancelled ? nil : .failed(.failed)
        }
    }

    /// The last agent of the ask box, then Claude Code, then Codex: the
    /// first whose probe is ready.
    private func chooseAgent() async -> MeetingAgentCLI? {
        var order: [MeetingAgentCLI] = []
        if let last = defaults.string(forKey: MeetingDetailModel.lastAgentKey)
            .flatMap(MeetingAgentCLI.init(rawValue:))
        {
            order.append(last)
        }
        for cli in [MeetingAgentCLI.claudeCode, .codex] where !order.contains(cli) {
            order.append(cli)
        }
        for cli in order {
            if Task.isCancelled { return nil }
            if await agent.probe(cli, refresh: false) == .ready { return cli }
        }
        return nil
    }

    private func storedState(of meeting: MeetingID) async -> MeetingSummaryState? {
        guard let notesStore = store() as? any MeetingNotesStoring,
            let revision = try? await notesStore.textRevision(of: meeting)
        else { return nil }
        guard let notes = try? await notesStore.summaryNotes(of: meeting) else {
            return MeetingSummaryState.none
        }
        return notes.textRevision == revision ? .ready : .stale
    }
}
