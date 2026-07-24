import Foundation
import Observation

/// One user-selectable role file under `.rafu/agents/`.
///
/// The parsed definition is kept beside its repository-relative path so the
/// launch sheet can identify the file the user chose without ever copying its
/// prompt body into logs or app-level persistence.
nonisolated struct ConductorAgentFile: Equatable, Identifiable, Sendable {
    let relativePath: String
    let definition: ConductorAgentDefinition

    var id: String { relativePath }
}

nonisolated enum ConductorAgentCatalogError: Error, Equatable, LocalizedError, Sendable {
    case agentsPathIsNotDirectory
    case unsafeAgentFile(String)
    case agentFileTooLarge(String)
    case unreadableAgentFile(String)
    case invalidAgentFile(String, String)

    var errorDescription: String? {
        switch self {
        case .agentsPathIsNotDirectory:
            "The workspace's .rafu/agents path is not a readable directory."
        case .unsafeAgentFile(let name):
            "Agent file \(name) must be a regular file, not a symbolic link."
        case .agentFileTooLarge(let name):
            "Agent file \(name) exceeds Rafu's 1 MiB role-file limit."
        case .unreadableAgentFile(let name):
            "Agent file \(name) is not readable UTF-8 text."
        case .invalidAgentFile(let name, let reason):
            "Agent file \(name) is invalid: \(reason)"
        }
    }
}

/// Bounded, read-only discovery for `.rafu/agents/*.md`.
///
/// Opening the launch sheet never seeds `.rafu/`: an absent agents directory
/// honestly returns an empty catalog. Symlinks are refused so selecting a
/// repository role cannot silently read prompt material from outside the
/// workspace.
nonisolated struct ConductorAgentCatalog: Sendable {
    static let maximumAgentFileBytes = 1_048_576

    @concurrent
    func load(workspaceRoot: URL) async throws -> [ConductorAgentFile] {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = RafuDotDirectory(workspaceRoot: workspaceRoot).agentsURL

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw ConductorAgentCatalogError.agentsPathIsNotDirectory
        }
        let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard directoryValues.isSymbolicLink != true else {
            throw ConductorAgentCatalogError.agentsPathIsNotDirectory
        }

        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var files: [ConductorAgentFile] = []
        files.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ConductorAgentCatalogError.unsafeAgentFile(name)
            }
            guard (values.fileSize ?? 0) <= Self.maximumAgentFileBytes else {
                throw ConductorAgentCatalogError.agentFileTooLarge(name)
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data =
                try handle.read(upToCount: Self.maximumAgentFileBytes + 1)
                ?? Data()
            guard data.count <= Self.maximumAgentFileBytes,
                let text = String(data: data, encoding: .utf8)
            else {
                if data.count > Self.maximumAgentFileBytes {
                    throw ConductorAgentCatalogError.agentFileTooLarge(name)
                }
                throw ConductorAgentCatalogError.unreadableAgentFile(name)
            }

            let definition: ConductorAgentDefinition
            do {
                definition = try ConductorAgentFileParser.parse(
                    text,
                    defaultName: url.deletingPathExtension().lastPathComponent)
            } catch let error as ConductorParseError {
                throw ConductorAgentCatalogError.invalidAgentFile(
                    name,
                    error.errorDescription ?? "the role file could not be parsed")
            }
            files.append(
                ConductorAgentFile(
                    relativePath: ".rafu/agents/\(name)",
                    definition: definition))
        }
        return files
    }
}

nonisolated enum ConductorNewRunInputError: Error, Equatable, LocalizedError, Sendable {
    case workspaceUnavailable
    case agentUnavailable
    case emptyTaskPrompt

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "Open a local workspace before starting a run."
        case .agentUnavailable:
            "Choose an agent file before starting the run."
        case .emptyTaskPrompt:
            "Enter a task prompt before starting the run."
        }
    }
}

/// Window-owned launch-form state. The role prompt remains inside the parsed
/// file definition and the task prompt remains ephemeral until the explicit
/// Run action asks `ConductorRunController` to persist the run evidence.
@Observable
@MainActor
final class ConductorNewRunModel {
    var agents: [ConductorAgentFile] = []
    var selectedAgentID: ConductorAgentFile.ID?
    var taskPrompt = ""
    var baseReference = "HEAD"
    private(set) var isLoading = false
    private(set) var isStarting = false
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let catalog: ConductorAgentCatalog

    @ObservationIgnored
    private var loadedWorkspaceRoot: URL?

    init(catalog: ConductorAgentCatalog = ConductorAgentCatalog()) {
        self.catalog = catalog
    }

    var canStart: Bool {
        !isLoading && !isStarting && selectedAgent != nil
            && !taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedAgent: ConductorAgentFile? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    func load(workspaceRoot: URL?) async {
        guard let workspaceRoot else {
            agents = []
            selectedAgentID = nil
            errorMessage = ConductorNewRunInputError.workspaceUnavailable.errorDescription
            return
        }

        let root = workspaceRoot.standardizedFileURL
        loadedWorkspaceRoot = root
        isLoading = true
        errorMessage = nil
        defer {
            if loadedWorkspaceRoot == root {
                isLoading = false
            }
        }

        do {
            let loaded = try await catalog.load(workspaceRoot: root)
            try Task.checkCancellation()
            guard loadedWorkspaceRoot == root else { return }
            agents = loaded
            if !loaded.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = loaded.first?.id
            }
        } catch is CancellationError {
            return
        } catch let error as ConductorAgentCatalogError {
            guard loadedWorkspaceRoot == root else { return }
            agents = []
            selectedAgentID = nil
            errorMessage = error.errorDescription
        } catch {
            guard loadedWorkspaceRoot == root else { return }
            agents = []
            selectedAgentID = nil
            errorMessage = "Rafu could not read this workspace's agent files."
        }
    }

    func request(runID: String = UUID().uuidString.lowercased()) throws -> ConductorRunRequest {
        guard loadedWorkspaceRoot != nil else {
            throw ConductorNewRunInputError.workspaceUnavailable
        }
        guard let selectedAgent else {
            throw ConductorNewRunInputError.agentUnavailable
        }
        let task = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            throw ConductorNewRunInputError.emptyTaskPrompt
        }
        let base = baseReference.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConductorRunRequest(
            role: selectedAgent.definition,
            taskPrompt: task,
            baseReference: base.isEmpty ? "HEAD" : base,
            runID: runID)
    }

    /// Returns `true` only after the terminal-backed run has launched.
    func start(in session: WorkspaceSession) async -> Bool {
        let request: ConductorRunRequest
        do {
            request = try self.request()
        } catch let error as ConductorNewRunInputError {
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = "Rafu could not prepare this run."
            return false
        }

        guard let workspaceRoot = session.rootURL else {
            errorMessage = ConductorNewRunInputError.workspaceUnavailable.errorDescription
            return false
        }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }

        let controller = session.conductorRunController
        controller.attach(workspaceRoot: workspaceRoot)
        guard controller.canStartNewRun else {
            errorMessage = "Finish the current run before starting another."
            return false
        }
        let launcher = WorkspaceConductorRunLauncher(
            workspaceSession: session,
            runID: request.runID)
        await controller.start(request, launcher: launcher)

        switch controller.state {
        case .running, .awaitingArtifact, .awaitingMergeGate, .completed:
            return true
        case .failed(let reason):
            errorMessage = reason
        case .aborted:
            errorMessage = "The run was aborted before launch completed."
        case .idle, .preparing:
            errorMessage = "Rafu could not launch the run."
        }
        return false
    }
}
