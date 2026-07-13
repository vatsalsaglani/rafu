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
        searchTask?.cancel()
        replacementPreview = nil
        errorMessage = nil
        guard !query.isEmpty else {
            result = nil
            isSearching = false
            return
        }
        let rootPath = rootURL.standardizedFileURL.path
        historyStore.record(query: query, forRootPath: rootPath)
        recentQueries = historyStore.queries(forRootPath: rootPath)
        let request = makeRequest(rootURL: rootURL)
        isSearching = true
        searchTask = Task(name: "Search workspace") { [weak self, service] in
            do {
                let result = try await service.search(request)
                try Task.checkCancellation()
                self?.result = result
                self?.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.isSearching = false
            }
        }
    }

    func previewReplacements(in rootURL: URL) {
        searchTask?.cancel()
        errorMessage = nil
        guard !query.isEmpty else { return }
        let request = makeRequest(rootURL: rootURL)
        let replacement = replacement
        isSearching = true
        searchTask = Task(name: "Preview workspace replacements") { [weak self, service] in
            do {
                async let searchResult = service.search(request)
                async let preview = service.previewReplacement(request, replacement: replacement)
                let (result, replacementPreview) = try await (searchResult, preview)
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
