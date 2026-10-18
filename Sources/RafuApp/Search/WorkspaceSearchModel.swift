import Foundation
import Observation

@Observable
@MainActor
final class WorkspaceSearchModel {
    var query = ""
    var replacement = ""
    /// Comma-separated include/exclude globs ("*.swift, Sources/**").
    var includePattern = ""
    var excludePattern = ""
    var options: TextSearchOptions = []
    var result: WorkspaceSearchResult?
    var replacementPreview: WorkspaceReplacementPreview?
    var isReplacePresented = false
    private(set) var isSearching = false
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    private(set) var recentQueries: [String] = []

    @ObservationIgnored
    private let service = WorkspaceSearchService()

    @ObservationIgnored
    private let historyStore: WorkspaceSearchHistoryStore

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?

    init(historyStore: WorkspaceSearchHistoryStore = WorkspaceSearchHistoryStore()) {
        self.historyStore = historyStore
    }

    deinit {
        searchTask?.cancel()
    }

    func loadHistory(for rootURL: URL) {
        recentQueries = historyStore.queries(forRootPath: rootURL.standardizedFileURL.path)
    }

    func search(in rootURL: URL) {
        search(in: [WorkspaceSearchRoot(url: rootURL, label: nil)])
    }

    /// Searches every root in order (multi-folder workspaces). Search
    /// history stays keyed by the first (primary) root. Roots are searched
    /// one after another; once the match limit is reached the rest are
    /// skipped and the result is marked truncated.
    func search(in roots: [WorkspaceSearchRoot]) {
        searchTask?.cancel()
        replacementPreview = nil
        errorMessage = nil
        guard !query.isEmpty, let rootURL = roots.first?.url else {
            result = nil
            isSearching = false
            return
        }
        let rootPath = rootURL.standardizedFileURL.path
        historyStore.record(query: query, forRootPath: rootPath)
        recentQueries = historyStore.queries(forRootPath: rootPath)
        let requests = roots.map { (request: makeRequest(rootURL: $0.url), label: $0.label) }
        isSearching = true
        searchTask = Task(name: "Search workspace") { [weak self, service] in
            do {
                var parts: [WorkspaceSearchResult] = []
                var total = 0
                for entry in requests {
                    guard total < entry.request.limits.maximumTotalMatches else { break }
                    let part = try await service.search(entry.request)
                    total += part.totalMatchCount
                    parts.append(WorkspaceSearchMerge.labelled(part, label: entry.label))
                }
                let result = WorkspaceSearchMerge.merge(
                    parts, skippedRoots: parts.count < requests.count)
                try Task.checkCancellation()
                self?.result = result
                self?.isSearching = false
                MemoryTimeline.shared.note(
                    .searchCompleted, detail: "\(result.totalMatchCount) matches",
                    source: rootURL.lastPathComponent)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.isSearching = false
            }
        }
    }

    func previewReplacements(in rootURL: URL) {
        previewReplacements(in: [WorkspaceSearchRoot(url: rootURL, label: nil)])
    }

    /// Replacement preview across every root, labelled like `search(in:)`.
    func previewReplacements(in roots: [WorkspaceSearchRoot]) {
        searchTask?.cancel()
        errorMessage = nil
        guard !query.isEmpty, !roots.isEmpty else { return }
        let requests = roots.map { (request: makeRequest(rootURL: $0.url), label: $0.label) }
        let replacement = replacement
        isSearching = true
        searchTask = Task(name: "Preview workspace replacements") { [weak self, service] in
            do {
                var results: [WorkspaceSearchResult] = []
                var previews: [WorkspaceReplacementPreview] = []
                var total = 0
                for entry in requests {
                    guard total < entry.request.limits.maximumTotalMatches else { break }
                    async let searchResult = service.search(entry.request)
                    async let preview = service.previewReplacement(
                        entry.request, replacement: replacement)
                    let (part, partPreview) = try await (searchResult, preview)
                    total += part.totalMatchCount
                    results.append(WorkspaceSearchMerge.labelled(part, label: entry.label))
                    previews.append(WorkspaceSearchMerge.labelled(partPreview, label: entry.label))
                }
                let skipped = results.count < requests.count
                let result = WorkspaceSearchMerge.merge(results, skippedRoots: skipped)
                let replacementPreview = WorkspaceSearchMerge.merge(previews, skippedRoots: skipped)
                try Task.checkCancellation()
                self?.result = result
                self?.replacementPreview = replacementPreview
                self?.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.isSearching = false
            }
        }
    }

    func applyPreview() async throws -> WorkspaceReplacementReport {
        guard let replacementPreview else {
            return WorkspaceReplacementReport(changedFiles: [], replacementCount: 0)
        }
        isApplying = true
        defer { isApplying = false }
        do {
            let report = try await service.apply(replacementPreview)
            self.replacementPreview = nil
            return report
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func clearError() {
        errorMessage = nil
    }

    func report(_ message: String) {
        errorMessage = message
    }

    func reset() {
        cancel()
        query = ""
        replacement = ""
        includePattern = ""
        excludePattern = ""
        result = nil
        replacementPreview = nil
        errorMessage = nil
        recentQueries = []
    }

    private func makeRequest(rootURL: URL) -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootURL: rootURL,
            query: query,
            options: options,
            includeGlobs: Self.globList(from: includePattern),
            excludeGlobs: Self.globList(from: excludePattern)
        )
    }

    private static func globList(from pattern: String) -> [String] {
        pattern
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
