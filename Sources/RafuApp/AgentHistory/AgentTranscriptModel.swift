import Foundation
import Observation
import RafuCore

/// One open Agent Session tab: the bounded transcript, what is shown, and
/// the tab's Find state. The parsed transcript is the only full text held,
/// and only while the tab is open.
@MainActor
@Observable
final class AgentTranscriptModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let summary: AgentHistorySessionSummary
    private(set) var phase: Phase = .loading
    private(set) var transcript: AgentTranscript?
    /// The rows on screen: all items, without thinking unless it is shown.
    private(set) var visibleItems: [AgentTranscriptItem] = []
    var showsThinking = false {
        didSet {
            guard oldValue != showsThinking else { return }
            rebuildVisibleItems()
            updateFind()
        }
    }
    /// Tool rows the user expanded.
    var expandedItems: Set<Int> = []

    var isFindPresented = false
    var findQuery = "" {
        didSet {
            guard oldValue != findQuery else { return }
            updateFind()
        }
    }
    private(set) var findMatches: [Int] = []
    private(set) var currentMatchPosition: Int?
    /// Bumped to focus the Find field.
    var findFocusRequest = 0
    /// The item the list should scroll to next.
    var scrollTarget: Int?

    /// Readable so tests can await a load instead of sleeping.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private var findTask: Task<Void, Never>?

    init(summary: AgentHistorySessionSummary) {
        self.summary = summary
    }

    var currentMatchID: Int? {
        guard let currentMatchPosition, findMatches.indices.contains(currentMatchPosition) else {
            return nil
        }
        return findMatches[currentMatchPosition]
    }

    func load() {
        loadTask?.cancel()
        phase = .loading
        let session = summary
        loadTask = Task { [weak self] in
            do {
                let transcript = try await AgentTranscriptLoader.load(session)
                guard let self, !Task.isCancelled else { return }
                self.transcript = transcript
                self.phase = .loaded
                self.rebuildVisibleItems()
                self.updateFind()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.phase = .failed(Self.failureMessage(for: error))
            }
        }
    }

    /// Stops any work. Called when the tab closes.
    func cancel() {
        loadTask?.cancel()
        findTask?.cancel()
        loadTask = nil
        findTask = nil
    }

    func toggleExpanded(_ id: Int) {
        if expandedItems.contains(id) {
            expandedItems.remove(id)
        } else {
            expandedItems.insert(id)
        }
    }

    func presentFind() {
        isFindPresented = true
        findFocusRequest &+= 1
    }

    func dismissFind() {
        isFindPresented = false
        findQuery = ""
    }

    func nextMatch() { stepMatch(by: 1) }
    func previousMatch() { stepMatch(by: -1) }

    private func stepMatch(by offset: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        let start = currentMatchPosition ?? (offset > 0 ? -1 : 0)
        let next = ((start + offset) % count + count) % count
        currentMatchPosition = next
        scrollTarget = findMatches[next]
    }

    private func rebuildVisibleItems() {
        let items = transcript?.items ?? []
        visibleItems = showsThinking ? items : items.filter { $0.kind != .thinking }
    }

    /// Matching runs off the main actor; a newer query cancels the older one.
    private func updateFind() {
        findTask?.cancel()
        let query = findQuery
        guard let transcript, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            findMatches = []
            currentMatchPosition = nil
            return
        }
        let includeThinking = showsThinking
        findTask = Task { [weak self] in
            let matches = await Self.matches(
                in: transcript, query: query, includeThinking: includeThinking)
            guard let self, !Task.isCancelled else { return }
            self.findMatches = matches
            self.currentMatchPosition = matches.isEmpty ? nil : 0
            self.scrollTarget = matches.first
        }
    }

    @concurrent
    private nonisolated static func matches(
        in transcript: AgentTranscript, query: String, includeThinking: Bool
    ) async -> [Int] {
        transcript.matchingItemIDs(query, includeThinking: includeThinking)
    }

    /// Never includes the path or file content.
    private nonisolated static func failureMessage(for error: any Error) -> String {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile {
            return "The transcript file is no longer there."
        }
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoPermission {
            return "Rafu does not have permission to read this transcript."
        }
        return "The transcript could not be read."
    }
}
