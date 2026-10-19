import Foundation

/// One extra folder of a multi-folder workspace, for relaunch restoration.
nonisolated struct RestorableWorkspaceRoot: Codable, Equatable, Sendable {
    let bookmark: Data?
    let path: String
}

nonisolated struct RestorableWorkspace: Codable, Sendable {
    let bookmark: Data
    let rootPath: String
    let openRelativePaths: [String]
    let selectedRelativePath: String?
    let navigatorMode: WorkspaceNavigatorMode
    let editorLayout: EditorLayoutRestoration?
    let canvasIDs: [CanvasID]
    /// Inert Terminal Group metadata only. The custom decoder below isolates
    /// this optional future field so a malformed or newer group record cannot
    /// discard the existing workspace, file tabs, or editor layout.
    let terminalGroupRestoration: TerminalGroupWorkspaceRestoration?
    /// Decode-only, bounded diagnostics. They are deliberately not persisted
    /// again and contain no workspace path, terminal output, or process data.
    let terminalGroupRestorationDiagnostics: [TerminalGroupRestorationDiagnostic]
    /// Folders after the primary root (multi-folder workspaces), in order.
    /// Optional on decode: older payloads have none, and a damaged list is
    /// dropped without losing the rest of the workspace.
    let additionalRoots: [RestorableWorkspaceRoot]
    /// The `.rafuworkspace` file the window was bound to, if any.
    let workspaceFilePath: String?
    /// The left sidebar pane's width while expanded, in points. Optional on
    /// decode: a record saved before the window redesign's phase 3 has
    /// none, and falls back to `WorkbenchSidebarResize.idealWidth` (300).
    let sidebarWidth: Double
    /// Optional on decode for the same reason; an older record without this
    /// field restores expanded.
    let isSidebarCollapsed: Bool

    init(
        bookmark: Data,
        rootPath: String,
        openRelativePaths: [String],
        selectedRelativePath: String?,
        navigatorMode: WorkspaceNavigatorMode,
        editorLayout: EditorLayoutRestoration?,
        terminalGroupRestoration: TerminalGroupWorkspaceRestoration? = nil,
        canvasIDs: [CanvasID] = [],
        additionalRoots: [RestorableWorkspaceRoot] = [],
        workspaceFilePath: String? = nil,
        sidebarWidth: Double = 300,
        isSidebarCollapsed: Bool = false
    ) {
        self.additionalRoots = Array(additionalRoots.prefix(16))
        self.workspaceFilePath = workspaceFilePath
        self.canvasIDs = Array(canvasIDs.prefix(CanvasLimits.boards))
        self.bookmark = bookmark
        self.rootPath = rootPath
        self.openRelativePaths = openRelativePaths
        self.selectedRelativePath = selectedRelativePath
        self.navigatorMode = navigatorMode
        self.editorLayout = editorLayout
        self.terminalGroupRestoration = terminalGroupRestoration
        terminalGroupRestorationDiagnostics = []
        self.sidebarWidth = sidebarWidth
        self.isSidebarCollapsed = isSidebarCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case bookmark
        case rootPath
        case openRelativePaths
        case selectedRelativePath
        case navigatorMode
        case editorLayout
        case terminalGroupRestoration
        case canvasIDs
        case additionalRoots
        case workspaceFilePath
        case sidebarWidth
        case isSidebarCollapsed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        openRelativePaths = try container.decode([String].self, forKey: .openRelativePaths)
        selectedRelativePath = try container.decodeIfPresent(
            String.self, forKey: .selectedRelativePath)
        navigatorMode = try container.decode(WorkspaceNavigatorMode.self, forKey: .navigatorMode)
        editorLayout = try? container.decodeIfPresent(
            EditorLayoutRestoration.self, forKey: .editorLayout)
        let roots = try? container.decodeIfPresent(
            [RestorableWorkspaceRoot].self, forKey: .additionalRoots)
        additionalRoots = Array((roots ?? []).prefix(16))
        workspaceFilePath = try? container.decodeIfPresent(
            String.self, forKey: .workspaceFilePath)
        sidebarWidth =
            (try? container.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? 300
        isSidebarCollapsed =
            (try? container.decodeIfPresent(Bool.self, forKey: .isSidebarCollapsed)) ?? false

        if let list = try? container.nestedUnkeyedContainer(forKey: .canvasIDs),
            (list.count ?? Int.max) <= CanvasLimits.boards
        {
            canvasIDs = (try? container.decode([CanvasID].self, forKey: .canvasIDs)) ?? []
        } else {
            canvasIDs = []
        }

        guard container.contains(.terminalGroupRestoration) else {
            terminalGroupRestoration = nil
            terminalGroupRestorationDiagnostics = [.missingTerminalGroupField]
            return
        }

        do {
            terminalGroupRestoration = try container.decodeIfPresent(
                TerminalGroupWorkspaceRestoration.self,
                forKey: .terminalGroupRestoration
            )
            terminalGroupRestorationDiagnostics = terminalGroupRestoration?.diagnostics ?? []
        } catch TerminalGroupRestorationError.unsupportedWorkspaceSchema(let version) {
            terminalGroupRestoration = nil
            terminalGroupRestorationDiagnostics = [.unsupportedTerminalGroupSchema(version)]
        } catch {
            terminalGroupRestoration = nil
            terminalGroupRestorationDiagnostics = [.malformedTerminalGroupField]
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canvasIDs, forKey: .canvasIDs)
        try container.encode(bookmark, forKey: .bookmark)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(openRelativePaths, forKey: .openRelativePaths)
        try container.encodeIfPresent(selectedRelativePath, forKey: .selectedRelativePath)
        try container.encode(navigatorMode, forKey: .navigatorMode)
        try container.encodeIfPresent(editorLayout, forKey: .editorLayout)
        try container.encodeIfPresent(terminalGroupRestoration, forKey: .terminalGroupRestoration)
        if !additionalRoots.isEmpty {
            try container.encode(additionalRoots, forKey: .additionalRoots)
        }
        try container.encodeIfPresent(workspaceFilePath, forKey: .workspaceFilePath)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(isSidebarCollapsed, forKey: .isSidebarCollapsed)
    }
}

/// Serializes each complete metadata blob and bookmark access off MainActor.
/// There is no suspension between the cancellation check and the atomic
/// UserDefaults value replacement. No document text or process state is saved.
actor WorkspaceRestorationStore {
    private let defaultsKey: String
    private let defaultsSuiteName: String?
    private let bookmarkMaker: @Sendable (URL) async throws -> Data
    private var cachedBookmark: (url: URL, authorizationID: UUID?, data: Data)?
    private var bookmarkGeneration = UUID()

    init(
        defaultsSuiteName: String? = nil,
        defaultsKey: String = "dev.rafu.last-workspace.v1",
        bookmarkMaker: @escaping @Sendable (URL) async throws -> Data = { url in
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        }
    ) {
        self.defaultsSuiteName = defaultsSuiteName
        self.defaultsKey = defaultsKey
        self.bookmarkMaker = bookmarkMaker
    }

    private var defaults: UserDefaults {
        if let defaultsSuiteName, let suite = UserDefaults(suiteName: defaultsSuiteName) {
            return suite
        }
        return .standard
    }

    func save(_ workspace: RestorableWorkspace) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(workspace)
        try Task.checkCancellation()
        defaults.set(data, forKey: defaultsKey)
    }

    func load() throws -> RestorableWorkspace? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try JSONDecoder().decode(RestorableWorkspace.self, from: data)
    }

    func clear() {
        bookmarkGeneration = UUID()
        cachedBookmark = nil
        defaults.removeObject(forKey: defaultsKey)
    }

    func cacheBookmark(_ data: Data?, for url: URL, authorizationID: UUID) {
        bookmarkGeneration = UUID()
        cachedBookmark = data.map { (url, authorizationID, $0) }
    }

    func makeBookmark(for url: URL, authorizationID: UUID? = nil) async throws -> Data {
        try Task.checkCancellation()
        if let cachedBookmark,
            cachedBookmark.url == url,
            cachedBookmark.authorizationID == authorizationID
        {
            return cachedBookmark.data
        }
        let generation = UUID()
        bookmarkGeneration = generation
        let data = try await bookmarkMaker(url)
        try Task.checkCancellation()
        if bookmarkGeneration == generation {
            cachedBookmark = (url, authorizationID, data)
        }
        return data
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}
