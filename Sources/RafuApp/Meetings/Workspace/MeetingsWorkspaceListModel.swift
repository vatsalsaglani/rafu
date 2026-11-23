import Observation
import RafuCore

/// The meeting list of one navigator panel or one Welcome card. It holds the
/// summaries as rows (title, date, length, state) and never a transcript text.
/// The view reloads it when `MeetingsSessionModel.libraryRevision` changes.
@MainActor
@Observable
final class MeetingsWorkspaceListModel {
    private(set) var rows: [MeetingsWorkspaceRow] = []
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

extension MeetingsSessionModel {
    /// Replaces the title cache with a full list. It writes only on a
    /// change, so the tab labels do not redraw after each read.
    func noteMeetingTitles(_ titles: [(MeetingID, String)]) {
        let fresh = Dictionary(titles, uniquingKeysWith: { first, _ in first })
        if fresh != meetingTitles { meetingTitles = fresh }
    }

    /// Sets the title of one meeting, for a tab that read one summary.
    func noteMeetingTitle(_ meeting: MeetingID, _ title: String) {
        if meetingTitles[meeting] != title { meetingTitles[meeting] = title }
    }
}
