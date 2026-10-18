import AppKit
import Foundation
import Observation
import RafuCore

/// App-wide list behind the Workspaces window, the welcome screen, and the
/// titlebar workspace menu: saved `.rafuworkspace` files plus recent
/// folders.
///
/// Saved workspaces live in one JSON file in Application Support (never
/// `UserDefaults`), bounded to `SavedWorkspaceList.capacity` entries and
/// written atomically by `SavedWorkspaceListStore` off the main actor.
/// Recent folders stay in the existing `RecentWorkspacesStore`.
@MainActor
@Observable
final class SavedWorkspacesModel {
    static let shared = SavedWorkspacesModel()

    private(set) var savedWorkspaces: [SavedWorkspaceEntry] = []
    private(set) var recentFolders: [RecentWorkspaceEntry] = []
    private(set) var hasLoaded = false

    @ObservationIgnored private let store: SavedWorkspaceListStore
    @ObservationIgnored private let recentsStore = RecentWorkspacesStore()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(store: SavedWorkspaceListStore = SavedWorkspacesModel.defaultStore()) {
        self.store = store
    }

    nonisolated static func defaultStore(
        identity: RafuAppIdentity = .current
    ) -> SavedWorkspaceListStore {
        SavedWorkspaceListStore(
            fileURL: identity.applicationSupportRoot().appending(path: "saved-workspaces.json"))
    }

    /// Reloads both lists. Cheap and idempotent; views call it on appear.
    func reload() {
        recentFolders = recentsStore.load()
        loadTask?.cancel()
        loadTask = Task(name: "Load saved workspaces") { [weak self, store] in
            let entries = await store.load()
            guard let self, !Task.isCancelled else { return }
            savedWorkspaces = entries
            hasLoaded = true
        }
    }

    /// Records a workspace file that was just saved or opened.
    func record(fileURL: URL, file: RafuWorkspaceFile) {
        let folderPaths = file.orderedFolders.map(\.lastKnownPath)
        Task(name: "Record saved workspace") { [weak self, store] in
            let bookmark = await WorkspaceFileIO.fileBookmark(for: fileURL)
            let entry = SavedWorkspaceEntry(
                filePath: fileURL.path, fileBookmark: bookmark, displayName: file.displayName,
                folderPaths: folderPaths, lastOpened: Date())
            guard let entries = try? await store.record(entry) else { return }
            self?.savedWorkspaces = entries
            self?.recentFolders = RecentWorkspacesStore().load()
        }
    }

    /// "Remove from List": forgets the entry. The file itself is untouched.
    func remove(_ entry: SavedWorkspaceEntry) {
        savedWorkspaces.removeAll { $0.id == entry.id }
        Task(name: "Remove saved workspace") { [weak self, store] in
            guard let entries = try? await store.remove(filePath: entry.filePath) else { return }
            self?.savedWorkspaces = entries
        }
    }

    func remove(_ entry: RecentWorkspaceEntry) {
        recentsStore.remove(rootPath: entry.rootPath)
        recentFolders = recentsStore.load()
    }

    /// Resolves an entry to its file, or reports and offers removal.
    func resolve(_ entry: SavedWorkspaceEntry) async -> URL? {
        await WorkspaceFileIO.resolveEntry(entry)
    }

    func resolve(_ entry: RecentWorkspaceEntry) -> URL? {
        if let url = try? recentsStore.resolve(entry) { return url }
        let url = URL(fileURLWithPath: entry.rootPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func revealInFinder(_ entry: SavedWorkspaceEntry) {
        Task {
            guard let url = await resolve(entry) else { return presentMissing(entry.displayName) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealInFinder(_ entry: RecentWorkspaceEntry) {
        guard let url = resolve(entry) else { return presentMissing(entry.displayName) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func presentMissing(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) could not be found."
        alert.informativeText =
            "It was moved, renamed, or deleted. Use Remove from List to forget it."
        alert.runModal()
    }
}
