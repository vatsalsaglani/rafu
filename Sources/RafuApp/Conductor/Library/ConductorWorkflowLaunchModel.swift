import Foundation
import Observation

nonisolated struct ConductorWorkflowLaunchRole: Equatable, Identifiable, Sendable {
    let stepIndex: Int
    let step: ConductorWorkflowDefinition.Step
    let definition: ConductorAgentDefinition
    let modelChoices: [ConductorModelChoice]

    var id: Int { stepIndex }
}

nonisolated enum ConductorWorkflowLaunchError: Error, Equatable, LocalizedError, Sendable {
    case workspaceUnavailable
    case workflowUnavailable
    case workflowInvalid
    case unresolvedAgent(step: Int)
    case emptyTaskPrompt

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "Open a local workspace before starting a run."
        case .workflowUnavailable:
            "Choose a workflow before starting the run."
        case .workflowInvalid:
            "Fix this workflow's validation issues before starting the run."
        case .unresolvedAgent(let step):
            "Step \(step + 1) does not resolve to an active role."
        case .emptyTaskPrompt:
            "Enter a task prompt before starting the run."
        }
    }
}

/// Persists only the selected definition's file identity. Definitions,
/// prompts, and launch-time model overrides remain file-backed or ephemeral.
@MainActor
final class ConductorLastWorkflowStore {
    private let defaults: UserDefaults
    private let keyPrefix = "conductorLastWorkflow"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func workflowID(for workspaceRoot: URL) -> String? {
        defaults.string(forKey: key(for: workspaceRoot))
    }

    func setWorkflowID(_ workflowID: String?, for workspaceRoot: URL) {
        let key = key(for: workspaceRoot)
        if let workflowID {
            defaults.set(workflowID, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(for workspaceRoot: URL) -> String {
        let path = workspaceRoot.standardizedFileURL.path
        let encoded = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(keyPrefix).\(encoded)"
    }
}

/// Window-owned workflow picker state. Loading always resolves definitions
/// from disk; selecting a workflow stores only its path, and `makeRequest`
/// reconstructs each role so launch-time model choices are snapshotted by the
/// existing C5 manifest writer without mutating the source Markdown.
@Observable
@MainActor
final class ConductorWorkflowLaunchModel {
    private(set) var snapshot: ConductorDefinitionLibrarySnapshot?
    private(set) var selectedWorkflowID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var taskPrompt = ""
    var baseReference = "HEAD"
    var modelOverrides: [Int: String] = [:]

    @ObservationIgnored
    private let library: ConductorDefinitionLibrary

    @ObservationIgnored
    private let lastWorkflowStore: ConductorLastWorkflowStore

    @ObservationIgnored
    private let adapters: [any ConductorCLIAdapter]

    @ObservationIgnored
    private var workspaceRoot: URL?

    @ObservationIgnored
    private var loadGeneration = UUID()

    init(
        library: ConductorDefinitionLibrary = ConductorDefinitionLibrary(),
        lastWorkflowStore: ConductorLastWorkflowStore = ConductorLastWorkflowStore(),
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all
    ) {
        self.library = library
        self.lastWorkflowStore = lastWorkflowStore
        self.adapters = adapters
    }

    var workflows: [ConductorLibraryWorkflow] {
        snapshot?.workflows ?? []
    }

    var launchableWorkflows: [ConductorLibraryWorkflow] {
        snapshot?.launchableWorkflows ?? []
    }

    var selectedWorkflow: ConductorLibraryWorkflow? {
        guard let selectedWorkflowID else { return nil }
        return workflows.first { $0.id == selectedWorkflowID }
    }

    var resolvedRoles: [ConductorWorkflowLaunchRole] {
        guard let selectedWorkflow,
            selectedWorkflow.isLaunchable,
            let definition = selectedWorkflow.definition,
            let agents = snapshot?.agents
        else { return [] }

        return definition.steps.enumerated().compactMap { index, step in
            guard
                let agent = agents.first(where: {
                    $0.isLaunchable
                        && ($0.definition?.name == step.agentName || $0.stem == step.agentName)
                }),
                let agentDefinition = agent.definition
            else { return nil }
            let choices =
                adapters.first(where: { $0.id == agentDefinition.provider })?
                .curatedModels() ?? []
            return ConductorWorkflowLaunchRole(
                stepIndex: index,
                step: step,
                definition: agentDefinition,
                modelChoices: choices)
        }
    }

    var canStart: Bool {
        guard
            !isLoading,
            selectedWorkflow?.isLaunchable == true,
            let stepCount = selectedWorkflow?.definition?.steps.count,
            resolvedRoles.count == stepCount
        else { return false }
        return !taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(
        workspaceRoot: URL?,
        userLibraryRoot: URL = ConductorDefinitionLibrary.defaultUserLibraryRoot
    ) async {
        let generation = UUID()
        loadGeneration = generation
        guard let workspaceRoot else {
            self.workspaceRoot = nil
            snapshot = nil
            selectedWorkflowID = nil
            modelOverrides = [:]
            errorMessage = ConductorWorkflowLaunchError.workspaceUnavailable.errorDescription
            return
        }

        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            let loaded = try await library.load(
                workspaceRoot: workspaceRoot,
                userLibraryRoot: userLibraryRoot)
            guard loadGeneration == generation else { return }
            self.workspaceRoot = workspaceRoot.standardizedFileURL
            snapshot = loaded

            let remembered = lastWorkflowStore.workflowID(for: workspaceRoot)
            let selected =
                loaded.launchableWorkflows.first(where: { $0.id == remembered })
                ?? loaded.launchableWorkflows.first
            selectedWorkflowID = selected?.id
            modelOverrides = [:]
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            snapshot = nil
            selectedWorkflowID = nil
            modelOverrides = [:]
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not load Ensemble workflows."
        }
    }

    func selectWorkflow(id: String) {
        guard
            let workspaceRoot,
            let workflow = workflows.first(where: { $0.id == id })
        else { return }
        selectedWorkflowID = workflow.id
        modelOverrides = [:]
        lastWorkflowStore.setWorkflowID(workflow.id, for: workspaceRoot)
    }

    func modelValue(for stepIndex: Int) -> String {
        if let override = modelOverrides[stepIndex] {
            return override
        }
        return resolvedRoles.first(where: { $0.stepIndex == stepIndex })?.definition.model ?? ""
    }

    func setModelValue(_ model: String, for stepIndex: Int) {
        guard resolvedRoles.contains(where: { $0.stepIndex == stepIndex }) else { return }
        modelOverrides[stepIndex] = model
    }

    func makeRequest(runID: String = UUID().uuidString.lowercased()) throws
        -> ConductorWorkflowRunRequest
    {
        guard workspaceRoot != nil else {
            throw ConductorWorkflowLaunchError.workspaceUnavailable
        }
        guard let selectedWorkflow else {
            throw ConductorWorkflowLaunchError.workflowUnavailable
        }
        guard selectedWorkflow.isLaunchable, let workflow = selectedWorkflow.definition else {
            throw ConductorWorkflowLaunchError.workflowInvalid
        }

        let task = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            throw ConductorWorkflowLaunchError.emptyTaskPrompt
        }
        let roles = resolvedRoles
        guard roles.count == workflow.steps.count else {
            let unresolved =
                workflow.steps.indices.first { index in
                    !roles.contains(where: { $0.stepIndex == index })
                } ?? 0
            throw ConductorWorkflowLaunchError.unresolvedAgent(step: unresolved)
        }

        let definitions = roles.map { role in
            let override = modelOverrides[role.stepIndex]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ConductorAgentDefinition(
                name: role.definition.name,
                provider: role.definition.provider,
                model: override ?? role.definition.model,
                autonomy: role.definition.autonomy,
                handoffArtifact: role.definition.handoffArtifact,
                promptBody: role.definition.promptBody)
        }
        return ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: definitions,
            taskPrompt: task,
            baseReference: baseReference.trimmingCharacters(in: .whitespacesAndNewlines),
            runID: runID)
    }
}
