import Foundation

nonisolated struct RestorableWorkspace: Codable, Sendable {
    let bookmark: Data
    let rootPath: String
    let openRelativePaths: [String]
    let selectedRelativePath: String?
    let navigatorMode: WorkspaceNavigatorMode
    let editorLayout: EditorLayoutRestoration?
    /// Inert Terminal Group metadata only. The custom decoder below isolates
    /// this optional future field so a malformed or newer group record cannot
    /// discard the existing workspace, file tabs, or editor layout.
    let terminalGroupRestoration: TerminalGroupWorkspaceRestoration?
    /// Decode-only, bounded diagnostics. They are deliberately not persisted
    /// again and contain no workspace path, terminal output, or process data.
    let terminalGroupRestorationDiagnostics: [TerminalGroupRestorationDiagnostic]

    init(
        bookmark: Data,
        rootPath: String,
        openRelativePaths: [String],
        selectedRelativePath: String?,
        navigatorMode: WorkspaceNavigatorMode,
        editorLayout: EditorLayoutRestoration?,
        terminalGroupRestoration: TerminalGroupWorkspaceRestoration? = nil
    ) {
        self.bookmark = bookmark
        self.rootPath = rootPath
        self.openRelativePaths = openRelativePaths
        self.selectedRelativePath = selectedRelativePath
        self.navigatorMode = navigatorMode
        self.editorLayout = editorLayout
        self.terminalGroupRestoration = terminalGroupRestoration
        terminalGroupRestorationDiagnostics = []
    }

    private enum CodingKeys: String, CodingKey {
        case bookmark
        case rootPath
        case openRelativePaths
        case selectedRelativePath
        case navigatorMode
        case editorLayout
        case terminalGroupRestoration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        openRelativePaths = try container.decode([String].self, forKey: .openRelativePaths)
        selectedRelativePath = try container.decodeIfPresent(
            String.self, forKey: .selectedRelativePath)
        navigatorMode = try container.decode(WorkspaceNavigatorMode.self, forKey: .navigatorMode)
        editorLayout = try container.decodeIfPresent(
            EditorLayoutRestoration.self, forKey: .editorLayout)

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
        try container.encode(bookmark, forKey: .bookmark)
        try container.encode(rootPath, forKey: .rootPath)
        try container.encode(openRelativePaths, forKey: .openRelativePaths)
        try container.encodeIfPresent(selectedRelativePath, forKey: .selectedRelativePath)
        try container.encode(navigatorMode, forKey: .navigatorMode)
        try container.encodeIfPresent(editorLayout, forKey: .editorLayout)
        try container.encodeIfPresent(terminalGroupRestoration, forKey: .terminalGroupRestoration)
    }
}

nonisolated struct WorkspaceRestorationStore: Sendable {
    private let defaultsKey = "dev.rafu.last-workspace.v1"

    @concurrent
    func save(_ workspace: RestorableWorkspace) async throws {
        let data = try JSONEncoder().encode(workspace)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    @concurrent
    func load() async throws -> RestorableWorkspace? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try JSONDecoder().decode(RestorableWorkspace.self, from: data)
    }

    @concurrent
    func clear() async {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    @concurrent
    func makeBookmark(for url: URL) async throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    @concurrent
    func resolve(_ bookmark: Data) async throws -> (url: URL, isStale: Bool) {
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
