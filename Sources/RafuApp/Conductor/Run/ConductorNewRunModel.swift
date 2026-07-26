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
    case workflowUnavailable
    case emptyTaskPrompt

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "Open a local workspace before starting a run."
        case .agentUnavailable:
            "Choose an agent file before starting the run."
        case .workflowUnavailable:
            "Choose a workflow file before starting the run."
        case .emptyTaskPrompt:
            "Enter a task prompt before starting the run."
        }
    }
}

/// Single role (C1) or a multi-step pipeline (C5) — the New Run sheet's mode
/// picker. Switching modes never clears the task prompt: only the
/// role/workflow selection is mode-specific.
nonisolated enum ConductorNewRunMode: String, CaseIterable, Identifiable, Sendable {
    case singleRole
    case workflow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleRole: "Single Role"
        case .workflow: "Workflow"
        }
    }
}

/// Window-owned launch-form state. The role prompt remains inside the parsed
/// file definition and the task prompt remains ephemeral until the explicit
/// Run action asks `ConductorRunController`/`ConductorWorkflowController` to
/// persist the run evidence.
@Observable
@MainActor
final class ConductorNewRunModel {
    var agents: [ConductorAgentFile] = []
    var selectedAgentID: ConductorAgentFile.ID?
    var mode: ConductorNewRunMode = .singleRole
    var workflows: [ConductorWorkflowFile] = []
    var selectedWorkflowID: ConductorWorkflowFile.ID?
    var taskPrompt = ""
    var baseReference = "HEAD"
    private(set) var isLoading = false
    private(set) var isStarting = false
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let catalog: ConductorAgentCatalog

    @ObservationIgnored
    private let workflowCatalog: ConductorWorkflowCatalog

    @ObservationIgnored
    private var loadedWorkspaceRoot: URL?

    init(
        catalog: ConductorAgentCatalog = ConductorAgentCatalog(),
        workflowCatalog: ConductorWorkflowCatalog = ConductorWorkflowCatalog()
    ) {
        self.catalog = catalog
        self.workflowCatalog = workflowCatalog
    }

    var canStart: Bool {
        guard !isLoading, !isStarting,
            !taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        switch mode {
        case .singleRole:
            return selectedAgent != nil
        case .workflow:
            guard let selectedWorkflow else { return false }
            let resolved = try? ConductorWorkflowBinder.resolve(
                workflow: selectedWorkflow.definition, agents: agents)
            return resolved != nil
        }
    }

    var selectedAgent: ConductorAgentFile? {
        guard let selectedAgentID else { return nil }
        return agents.first { $0.id == selectedAgentID }
    }

    var selectedWorkflow: ConductorWorkflowFile? {
        guard let selectedWorkflowID else { return nil }
        return workflows.first { $0.id == selectedWorkflowID }
    }

    /// The resolved step preview for the selected workflow (agent name →
    /// role definition, index-aligned with `selectedWorkflow.definition
    /// .steps`), or the typed binder failure — shown inline before Run
    /// enables, per-step, so an unmatched agent name is visible immediately
    /// rather than surfacing later as a launch-time failure.
    var resolvedWorkflowSteps: Result<[ConductorAgentDefinition], ConductorWorkflowBinderError>? {
        guard let selectedWorkflow else { return nil }
        do {
            let roles = try ConductorWorkflowBinder.resolve(
                workflow: selectedWorkflow.definition, agents: agents)
            return .success(roles)
        } catch let error as ConductorWorkflowBinderError {
            return .failure(error)
        } catch {
            return .failure(.unknownAgent(name: ""))
        }
    }

    func load(workspaceRoot: URL?) async {
        guard let workspaceRoot else {
            agents = []
            selectedAgentID = nil
            workflows = []
            selectedWorkflowID = nil
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
            let loadedAgents = try await catalog.load(workspaceRoot: root)
            try Task.checkCancellation()
            let loadedWorkflows = try await workflowCatalog.load(workspaceRoot: root)
            try Task.checkCancellation()
            guard loadedWorkspaceRoot == root else { return }
            agents = loadedAgents
            if !loadedAgents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = loadedAgents.first?.id
            }
            workflows = loadedWorkflows
            if !loadedWorkflows.contains(where: { $0.id == selectedWorkflowID }) {
                selectedWorkflowID = loadedWorkflows.first?.id
            }
        } catch is CancellationError {
            return
        } catch let error as ConductorAgentCatalogError {
            guard loadedWorkspaceRoot == root else { return }
            agents = []
            selectedAgentID = nil
            errorMessage = error.errorDescription
        } catch let error as ConductorWorkflowCatalogError {
            guard loadedWorkspaceRoot == root else { return }
            workflows = []
            selectedWorkflowID = nil
            errorMessage = error.errorDescription
        } catch {
            guard loadedWorkspaceRoot == root else { return }
            agents = []
            selectedAgentID = nil
            workflows = []
            selectedWorkflowID = nil
            errorMessage = "Rafu could not read this workspace's agent or workflow files."
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

    func requestWorkflow(
        runID: String = UUID().uuidString.lowercased()
    ) throws -> ConductorWorkflowRunRequest {
        guard loadedWorkspaceRoot != nil else {
            throw ConductorNewRunInputError.workspaceUnavailable
        }
        guard let selectedWorkflow else {
            throw ConductorNewRunInputError.workflowUnavailable
        }
        let task = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            throw ConductorNewRunInputError.emptyTaskPrompt
        }
        let roles = try ConductorWorkflowBinder.resolve(
            workflow: selectedWorkflow.definition, agents: agents)
        let base = baseReference.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConductorWorkflowRunRequest(
            workflow: selectedWorkflow.definition,
            roles: roles,
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
        // Defense in depth (advisor note A): the views already disable
        // "New Run…" while EITHER engine is busy, but this model must not
        // rely on that — a single-role start must refuse on its own when a
        // C5 pipeline is in flight, not only when C1 itself is busy.
        // `session` already carries the reference this needs; nothing is
        // stored, so there is no retain-cycle risk.
        guard controller.canStartNewRun, !session.conductorWorkflowController.isInFlight else {
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

    /// Returns `true` only after the workflow engine's first step has
    /// launched, mirroring `start(in:)` exactly for the pipeline path.
    func startWorkflow(in session: WorkspaceSession) async -> Bool {
        let request: ConductorWorkflowRunRequest
        do {
            request = try self.requestWorkflow()
        } catch let error as ConductorNewRunInputError {
            errorMessage = error.errorDescription
            return false
        } catch let error as ConductorWorkflowBinderError {
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

        let controller = session.conductorWorkflowController
        controller.attach(workspaceRoot: workspaceRoot)
        // Symmetric with `start(in:)` above (advisor note A): a workflow
        // must not launch while C1's single-role engine is itself busy.
        guard controller.canStartNewRun, session.conductorRunController.canStartNewRun else {
            errorMessage = "Finish the current run before starting another."
            return false
        }
        let launcher = WorkspaceConductorRunLauncher(
            workspaceSession: session,
            runID: request.runID)
        await controller.start(request, launcher: launcher)

        switch controller.state {
        case .runningStep, .awaitingArtifact, .awaitingGate, .awaitingPlanGate,
            .awaitingMergeGate, .completed:
            // This sheet never sets `planGateRequested`, so `.awaitingPlanGate`
            // is unreachable in practice today — included for exhaustiveness
            // and so a future plan-gate entry point here reads as success,
            // not failure, exactly like every other in-flight/parked state.
            return true
        case .failed(_, let reason):
            errorMessage = reason
        case .aborted:
            errorMessage = "The run was aborted before launch completed."
        case .idle, .preparing:
            errorMessage = "Rafu could not launch the run."
        }
        return false
    }
}
