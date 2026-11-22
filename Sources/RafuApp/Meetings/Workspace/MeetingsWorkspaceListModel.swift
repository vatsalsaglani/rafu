import Observation
import RafuCore

/// The meeting list of one navigator panel or one Welcome card. It holds the
/// summaries as rows (title, date, length, state) and never a transcript text.
/// The view reloads it when `MeetingsSessionModel.libraryRevision` changes.
@MainActor
@Observable
final class MeetingsWorkspaceListModel {
    private(set) var rows: [MeetingsListRow] = []
    /// True after the first read finished, so an empty list is not shown
    /// before the library answered.
    private(set) var isLoaded = false
    private(set) var loadFailed = false

    /// Reads the list from the store. A cancelled task keeps the old rows.
    func reload(from store: (any MeetingStoring)?) async {
        guard let store else {
            rows = []
            isLoaded = true
            return
        }
        do {
            let summaries = try await store.list()
            try Task.checkCancellation()
            rows = MeetingsWorkspacePresentation.rows(from: summaries)
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            loadFailed = true
        }
        isLoaded = true
    }
}
