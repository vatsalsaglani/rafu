import AppKit
import Foundation
import RafuCore
import UniformTypeIdentifiers

extension UTType {
    /// `.rafuworkspace`: a saved multi-folder workspace as versioned JSON.
    /// Declared as an exported type in the app's Info.plist
    /// (`script/build_and_run.sh`); keep both identifiers in lockstep with
    /// `RafuWorkspaceFile.typeIdentifier`.
    nonisolated static let rafuWorkspace = UTType(
        exportedAs: RafuWorkspaceFile.typeIdentifier, conformingTo: .json)
}

/// Disk access for `.rafuworkspace` files. Every function runs off the main
/// actor. Reads are bounded to `RafuWorkspaceFile.maximumBytes`; writes are
/// atomic and touch only the chosen URL (plus the system's same-directory
/// temporary file for the atomic replace).
nonisolated enum WorkspaceFileIO {
    @concurrent
    static func read(_ url: URL) async throws -> RafuWorkspaceFile {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WorkspaceFileIOError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        let limit = RafuWorkspaceFile.maximumBytes
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw RafuWorkspaceFileError.tooLarge(byteCount: data.count)
        }
        return try RafuWorkspaceFile.decode(data)
    }

    @concurrent
    static func write(_ file: RafuWorkspaceFile, to url: URL) async throws {
        let data = try file.encoded()
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    /// A file for `roots` (primary first) with a bookmark per folder.
    @concurrent
    static func makeFile(name: String, roots: [URL]) async -> RafuWorkspaceFile {
        let folders = roots.map {
            RafuWorkspaceFile.Folder(
                bookmark: WorkspaceRootBookmarks.bookmark(for: $0), lastKnownPath: $0.path)
        }
        return RafuWorkspaceFile(displayName: name, folders: folders, primaryIndex: 0)
    }

    /// Resolves every folder (bookmark first, then the last known path) and
    /// returns the primary folder plus the plan for the rest. The first
    /// folder that resolves becomes primary when the saved primary is gone.
    @concurrent
    static func openPlan(
        for file: RafuWorkspaceFile, fileURL: URL
    ) async throws -> (primary: URL, plan: WorkspaceOpenPlan) {
        let resolved = file.orderedFolders.compactMap {
            WorkspaceRootBookmarks.resolve(
                .init(bookmark: $0.bookmark, path: $0.lastKnownPath))
        }
        guard let primary = resolved.first else { throw RafuWorkspaceFileError.noFolderAvailable }
        return (
            primary,
            WorkspaceOpenPlan(
                displayName: file.displayName, additionalRoots: Array(resolved.dropFirst()),
                fileURL: fileURL)
        )
    }

    /// Resolves a saved-list entry's file: its bookmark first, then its path.
    @concurrent
    static func resolveEntry(_ entry: SavedWorkspaceEntry) async -> URL? {
        if let bookmark = entry.fileBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                bookmarkDataIsStale: &isStale),
                FileManager.default.isReadableFile(atPath: url.path)
            {
                return url
            }
        }
        let url = URL(fileURLWithPath: entry.filePath)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    @concurrent
    static func fileBookmark(for url: URL) async -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

nonisolated enum WorkspaceFileIOError: LocalizedError, Equatable {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Rafu could not read \(name)."
        }
    }
}

extension WorkspaceSession {
    /// Whether `url` names a saved workspace file (by extension).
    nonisolated static func isWorkspaceFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == RafuWorkspaceFile.pathExtension
    }

    /// The name a new workspace file gets in the save panel.
    nonisolated static func workspaceFileName(for name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = name.components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Workspace" : String(cleaned.prefix(80))) + "."
            + RafuWorkspaceFile.pathExtension
    }

    /// "Save Workspace As…": writes every root of this window to a new
    /// `.rafuworkspace` file the user chooses, then binds the window to it.
    func requestSaveWorkspaceAs() {
        guard let rootURL, let descriptor else { return }
        let panel = NSSavePanel()
        panel.title = "Save Workspace As"
        panel.allowedContentTypes = [.rafuWorkspace]
        panel.canCreateDirectories = true
        panel.directoryURL =
            workspaceFileURL?.deletingLastPathComponent()
            ?? rootURL.deletingLastPathComponent()
        panel.nameFieldStringValue = Self.workspaceFileName(for: descriptor.displayName)
        panel.prompt = "Save"
        panel.message = "The file lists this workspace's folders. It holds no file contents."
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url, self.rootURL == rootURL else {
                return
            }
            Task(name: "Save workspace file") { await self.saveWorkspace(to: url) }
        }
    }

    /// "Save Workspace": rewrites the file this window is bound to.
    func saveWorkspaceToBoundFile() {
        guard let workspaceFileURL else { return requestSaveWorkspaceAs() }
        Task(name: "Save workspace file") { await saveWorkspace(to: workspaceFileURL) }
    }

    func saveWorkspace(to fileURL: URL) async {
        let rootURLs = roots.compactMap { self.url(forRoot: $0.id) }
        guard !rootURLs.isEmpty, let descriptor else { return }
        let name = RafuWorkspaceFile.displayName(forFileName: fileURL.lastPathComponent)
        let file = await WorkspaceFileIO.makeFile(name: name, roots: rootURLs)
        let url = fileURL
        do {
            try await WorkspaceFileIO.write(file, to: url)
        } catch {
            reportWorkspaceError(
                title: "Unable to Save Workspace", message: error.localizedDescription)
            return
        }
        guard self.descriptor?.id == descriptor.id else { return }
        workspaceFileURL = url
        self.descriptor = WorkspaceDescriptor(
            id: descriptor.id, displayName: file.displayName, location: descriptor.location)
        SavedWorkspacesModel.shared.record(fileURL: url, file: file)
        scheduleCanvasWorkspaceSave()
    }

    /// "Open Workspace…": a panel for `.rafuworkspace` files.
    func requestOpenWorkspaceFile() {
        guard !isOpenFolderImporterPresented else { return }
        isOpenFolderImporterPresented = true
        let panel = NSOpenPanel()
        panel.title = "Open Workspace"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.rafuWorkspace]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self else { return }
            isOpenFolderImporterPresented = false
            guard response == .OK, let url = panel.url else { return }
            openWorkspaceFile(at: url)
        }
    }

    /// Opens a saved workspace in this window: reads the file off the main
    /// actor, resolves its folders, then opens the primary folder and adds
    /// the rest.
    func openWorkspaceFile(at url: URL) {
        let hasScope = url.startAccessingSecurityScopedResource()
        Task(name: "Open workspace file") { [weak self] in
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try await WorkspaceFileIO.read(url)
                let opened = try await WorkspaceFileIO.openPlan(for: file, fileURL: url)
                guard let self else { return }
                openLocalWorkspace(at: opened.primary, plan: opened.plan)
                SavedWorkspacesModel.shared.record(fileURL: url, file: file)
            } catch {
                self?.reportWorkspaceError(
                    title: "Unable to Open Workspace", message: error.localizedDescription)
            }
        }
    }
}

/// Routes a workspace file that arrives from outside a workspace window
/// (Finder, the Workspaces window): focus the window already bound to it,
/// else reuse an empty window, else open a new window for it. A window with
/// an open workspace is never replaced.
@MainActor
enum WorkspaceFileOpenRouter {
    static func open(_ url: URL) {
        let path = url.standardizedFileURL.path
        let registry = WorkspaceWindowRegistry.shared
        for snapshot in registry.sessionSnapshots()
        where snapshot.session.workspaceFileURL?.standardizedFileURL.path == path {
            registry.focus(session: snapshot.session)
            return
        }
        if let empty = registry.entries.values.first(where: {
            $0.window != nil && $0.session != nil && $0.session?.descriptor == nil
        })?.session {
            empty.openWorkspaceFile(at: url)
            registry.focus(session: empty)
            return
        }
        ExternalOpenRequests.shared.enqueueWorkspaceFiles([url])
        registry.openWorkspaceWindow()
    }

    /// Same rule for a plain folder (recent folders in the Workspaces window).
    static func openFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        let registry = WorkspaceWindowRegistry.shared
        for snapshot in registry.sessionSnapshots()
        where snapshot.rootURL.standardizedFileURL.path == path
            && snapshot.session.workspaceFileURL == nil
        {
            registry.focus(session: snapshot.session)
            return
        }
        if let empty = registry.entries.values.first(where: {
            $0.window != nil && $0.session != nil && $0.session?.descriptor == nil
        })?.session {
            empty.openLocalWorkspace(at: url)
            registry.focus(session: empty)
            return
        }
        ExternalOpenRequests.shared.enqueue([url])
        registry.openWorkspaceWindow()
    }
}
