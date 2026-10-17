import Foundation

nonisolated struct DocumentFindSearchKey: Equatable, Sendable {
    let revision: Int
    let pattern: TextSearchPattern
}

nonisolated struct DocumentFindSearchRequest: Sendable {
    let id: Int
    let key: DocumentFindSearchKey
    let text: String
}

nonisolated enum DocumentFindSearchResult: Sendable {
    case matches([TextSearchMatch])
    case failure(String)
    case cancelled
}

nonisolated enum DocumentFindSearch {
    /// Explicitly leaves the caller's actor under Swift 6.2 caller isolation.
    /// Foundation cancellation is cooperative: there is no regex deadline.
    @concurrent
    static func execute(_ request: DocumentFindSearchRequest) async -> DocumentFindSearchResult {
        do {
            let matches = try request.key.pattern.matches(
                in: request.text, isCancelled: { Task.isCancelled })
            return .matches(matches)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
