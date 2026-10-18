import Foundation
import Observation
import RafuCore

/// Identifies one Agent Session editor tab. Equality and hashing use the
/// session key only; the title is display data captured when the tab opened.
nonisolated struct AgentSessionTabReference: Hashable, Sendable {
    let key: AgentHistorySessionKey
    let title: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

extension AgentHistoryProvider {
    /// The agent identity used for icons (`AgentIconView`).
    nonisolated var cli: ConductorCLIID {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }
}

/// One window's Agent History state: the navigator's filter, the optional
/// message-text search, and the transcripts of open Agent Session tabs.
/// A transcript lives only while its tab is open (`retainTranscripts`).
@MainActor
@Observable
final class AgentHistoryWindowState {
    var query = ""
    var providerFilter: AgentHistoryProviderFilter = .all
    /// "All Projects" rows the user expanded, by project id. While a query
    /// is active every row shows expanded.
    var expandedProjects: Set<String> = []
    /// Bumped to move keyboard focus to the navigator's search field.
    var searchFocusRequest = 0
    /// The last request a navigator acted on, so re-showing the panel from
    /// the rail does not move focus again.
    var handledSearchFocusRequest = 0

    private(set) var messageMatches: Set<AgentHistorySessionKey> = []
    /// The query the current `messageMatches` belong to.
    private(set) var messageMatchesQuery: String?
    private(set) var isSearchingMessages = false

    /// The Agent Session tab on screen, if one is.
    var visibleSession: AgentSessionTabReference?
    private(set) var transcripts: [AgentHistorySessionKey: AgentTranscriptModel] = [:]

    @ObservationIgnored private var messageSearchTask: Task<Void, Never>?
    @ObservationIgnored private var sectionsCache: (key: SectionsKey, value: AgentHistorySections)?

    init() {}

    /// The model for a tab, created (and its load started) on first open.
    func openTranscript(for session: AgentHistorySessionSummary) -> AgentTranscriptModel {
        if let existing = transcripts[session.key] { return existing }
        let model = AgentTranscriptModel(summary: session)
        transcripts[session.key] = model
        model.load()
        return model
    }

    /// Releases every transcript whose tab is gone. Called whenever the
    /// window's auxiliary tab list changes.
    func retainTranscripts(for tabs: [WorkspaceAuxiliaryTab]) {
        var kept: Set<AgentHistorySessionKey> = []
        for tab in tabs {
            if case .agentSession(let reference) = tab { kept.insert(reference.key) }
        }
        for (key, model) in transcripts where !kept.contains(key) {
            model.cancel()
            transcripts[key] = nil
        }
        if let visibleSession, !kept.contains(visibleSession.key) {
            self.visibleSession = nil
        }
    }

    /// Searches prompt and reply text of `sessions` for the current query.
    /// Runs off the main actor; a new search or a query change cancels it.
    func searchMessages(in sessions: [AgentHistorySessionSummary]) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        messageSearchTask?.cancel()
        guard !needle.isEmpty else {
            clearMessageSearch()
            return
        }
        isSearchingMessages = true
        messageSearchTask = Task { [weak self] in
            let matches = try? await AgentHistoryMessageSearch.sessions(
                matching: needle, in: sessions)
            guard let self, !Task.isCancelled else { return }
            self.messageMatches = matches ?? []
            self.messageMatchesQuery = needle
            self.isSearchingMessages = false
        }
    }

    /// The match set applies only to the query it was computed for.
    func messageMatchesForCurrentQuery() -> Set<AgentHistorySessionKey> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return messageMatchesQuery == needle ? messageMatches : []
    }

    /// The filtered, partitioned lists for the navigator. Memoized, so a
    /// render that changes nothing does not filter or sort again.
    func sections(
        for index: AgentHistoryIndex, generation: Date?, workspaceRoots: [String]
    ) -> AgentHistorySections {
        let matches = messageMatchesForCurrentQuery()
        let key = SectionsKey(
            generation: generation, sessionCount: index.sessions.count, query: query,
            provider: providerFilter, matches: matches, roots: workspaceRoots)
        if let sectionsCache, sectionsCache.key == key { return sectionsCache.value }
        let filtered = index.filtered(
            provider: providerFilter, query: query, messageMatches: matches)
        let parts = filtered.partition(workspaceRoots: workspaceRoots)
        let value = AgentHistorySections(
            workspace: parts.workspace, others: parts.others,
            sessionCount: filtered.sessions.count)
        sectionsCache = (key, value)
        return value
    }

    func clearMessageSearch() {
        messageSearchTask?.cancel()
        messageSearchTask = nil
        messageMatches = []
        messageMatchesQuery = nil
        isSearchingMessages = false
    }
}

/// What the History navigator lists.
nonisolated struct AgentHistorySections: Equatable, Sendable {
    let workspace: [AgentHistoryProject]
    let others: [AgentHistoryProject]
    let sessionCount: Int
}

nonisolated private struct SectionsKey: Equatable {
    let generation: Date?
    let sessionCount: Int
    let query: String
    let provider: AgentHistoryProviderFilter
    let matches: Set<AgentHistorySessionKey>
    let roots: [String]
}
