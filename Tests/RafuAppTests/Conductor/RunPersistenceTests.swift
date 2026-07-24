import Foundation
import Testing

@testable import RafuApp

private func makeRunPersistenceRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-run-persistence-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeAgent(
    named fileName: String,
    name: String,
    to root: URL,
    autonomy: ConductorAutonomy = .readOnly
) throws {
    let agents = root.appending(path: ".rafu/agents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let text = """
        ---
        name: \(name)
        provider: claudeCode
        model: fake-fast
        autonomy: \(autonomy.rawValue)
        handoffArtifact: brief.md
        ---
        Follow the role instructions.
        """
    try Data(text.utf8).write(to: agents.appending(path: fileName), options: .atomic)
}

private func runPersistenceManifest(
    id: String,
    createdAt: Date,
    status: RunStepStatus
) -> ConductorRunManifest {
    ConductorRunManifest(
        id: id,
        workflowName: "advisor",
        baseCommit: "0123456789abcdef",
        worktreeBranch: "",
        createdAt: createdAt,
        updatedAt: createdAt,
        steps: [
            ConductorRunManifest.Step(
                agentName: "advisor",
                binding: ConductorRunManifest.AgentBinding(
                    provider: .claudeCode,
                    model: "fake-fast",
                    autonomy: .readOnly,
                    adapterVersion: "fake-1.0"),
                inputArtifacts: [],
                handoffArtifact: "brief.md",
                gateAfter: true,
                status: status,
                startedAt: nil,
                finishedAt: nil)
        ])
}

private func writeWorkflow(
    named fileName: String,
    name: String,
    to root: URL,
    steps: String
) throws {
    let workflows = root.appending(path: ".rafu/workflows", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    let text = """
        ---
        name: \(name)
        steps:
        \(steps)
        ---
        """
    try Data(text.utf8).write(to: workflows.appending(path: fileName), options: .atomic)
}

@Test("Opening an absent workflow catalog is read-only and does not seed .rafu")
func absentWorkflowCatalogDoesNotSeedRafu() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let files = try await ConductorWorkflowCatalog().load(workspaceRoot: root)

    #expect(files.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".rafu").path))
}

@Test("Workflow catalog loads pipeline Markdown files in stable file order")
func workflowCatalogLoadsPipelinesInStableOrder() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeWorkflow(
        named: "z-ship.md", name: "Ship", to: root,
        steps: "  - advisor\n  - implementor <- brief.md [gate]")
    try writeWorkflow(named: "a-review.md", name: "Review", to: root, steps: "  - advisor")

    let files = try await ConductorWorkflowCatalog().load(workspaceRoot: root)

    #expect(
        files.map(\.relativePath) == [
            ".rafu/workflows/a-review.md",
            ".rafu/workflows/z-ship.md",
        ])
    #expect(files.map(\.definition.name) == ["Review", "Ship"])
    #expect(files[1].definition.steps.count == 2)
    #expect(files[1].definition.steps[1].gateAfter)
}

@Test("Workflow catalog refuses pipeline-file symlinks")
func workflowCatalogRefusesSymlinks() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appending(path: "outside.md")
    try Data(
        """
        ---
        steps:
          - advisor
        ---
        """.utf8
    ).write(to: outside)
    let workflows = root.appending(path: ".rafu/workflows", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: workflows.appending(path: "linked.md"),
        withDestinationURL: outside)

    await #expect(
        throws: ConductorWorkflowCatalogError.unsafeWorkflowFile("linked.md")
    ) {
        _ = try await ConductorWorkflowCatalog().load(workspaceRoot: root)
    }
}

@Test("The workflow binder matches a step's agentName by parsed name, then by file stem")
func workflowBinderMatchesByNameThenStem() throws {
    let byName = ConductorAgentFile(
        relativePath: ".rafu/agents/one.md",
        definition: ConductorAgentDefinition(
            name: "Advisor", provider: .claudeCode, model: "fake-fast", autonomy: .readOnly,
            handoffArtifact: "brief.md", promptBody: "Assess."))
    let byStem = ConductorAgentFile(
        relativePath: ".rafu/agents/implementor.md",
        definition: ConductorAgentDefinition(
            name: "Some Display Name", provider: .claudeCode, model: "fake-fast",
            autonomy: .worktreeWrite, handoffArtifact: "patch.md", promptBody: "Implement."))
    let workflow = ConductorWorkflowDefinition(
        name: "pipeline",
        steps: [
            ConductorWorkflowDefinition.Step(
                agentName: "Advisor", inputArtifacts: [], gateAfter: false),
            ConductorWorkflowDefinition.Step(
                agentName: "implementor", inputArtifacts: ["brief.md"], gateAfter: false),
        ])

    let resolved = try ConductorWorkflowBinder.resolve(
        workflow: workflow, agents: [byName, byStem])

    #expect(resolved.map(\.name) == ["Advisor", "Some Display Name"])
}

@Test("The workflow binder throws a typed error for an unmatched agent name")
func workflowBinderThrowsForUnknownAgent() throws {
    let workflow = ConductorWorkflowDefinition(
        name: "pipeline",
        steps: [
            ConductorWorkflowDefinition.Step(
                agentName: "ghost", inputArtifacts: [], gateAfter: false)
        ])

    #expect(throws: ConductorWorkflowBinderError.unknownAgent(name: "ghost")) {
        try ConductorWorkflowBinder.resolve(workflow: workflow, agents: [])
    }
}

@Test("Opening an absent agent catalog is read-only and does not seed .rafu")
func absentAgentCatalogDoesNotSeedRafu() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let files = try await ConductorAgentCatalog().load(workspaceRoot: root)

    #expect(files.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".rafu").path))
}

@Test("Agent catalog loads Markdown roles in stable file order")
func agentCatalogLoadsRolesInStableOrder() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeAgent(named: "z-documentor.md", name: "Documentor", to: root)
    try writeAgent(named: "a-advisor.md", name: "Advisor", to: root)

    let files = try await ConductorAgentCatalog().load(workspaceRoot: root)

    #expect(
        files.map(\.relativePath) == [
            ".rafu/agents/a-advisor.md",
            ".rafu/agents/z-documentor.md",
        ])
    #expect(files.map(\.definition.name) == ["Advisor", "Documentor"])
}

@Test("Agent catalog refuses role-file symlinks")
func agentCatalogRefusesSymlinks() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appending(path: "outside.md")
    try Data(
        """
        ---
        provider: claudeCode
        ---
        External prompt.
        """.utf8
    ).write(to: outside)
    let agents = root.appending(path: ".rafu/agents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: agents.appending(path: "linked.md"),
        withDestinationURL: outside)

    await #expect(
        throws: ConductorAgentCatalogError.unsafeAgentFile("linked.md")
    ) {
        _ = try await ConductorAgentCatalog().load(workspaceRoot: root)
    }
}

@MainActor
@Test("Persisted runs reload newest first without restoring a terminal")
func persistedRunsReloadWithoutRestoringTerminal() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConductorRunStore(workspaceRoot: root)
    let older = runPersistenceManifest(
        id: "older-run",
        createdAt: Date(timeIntervalSince1970: 100),
        status: .completed)
    let newer = runPersistenceManifest(
        id: "newer-run",
        createdAt: Date(timeIntervalSince1970: 200),
        status: .running)
    try await store.save(older)
    try await store.save(newer)

    let session = WorkspaceSession()
    session.conductorRunController.attach(workspaceRoot: root)
    await session.conductorRunController.reloadRuns()

    #expect(session.conductorRuns.map(\.id) == ["newer-run", "older-run"])
    #expect(session.conductorRunController.state == .idle)
    #expect(session.conductorRunController.manifest == nil)
    #expect(session.terminal.sessions.isEmpty)
}

@MainActor
@Test("New-run form builds a trimmed request and defaults an empty base to HEAD")
func newRunModelBuildsRequest() async throws {
    let root = try makeRunPersistenceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeAgent(named: "advisor.md", name: "Advisor", to: root)
    let model = ConductorNewRunModel()

    await model.load(workspaceRoot: root)
    model.taskPrompt = "  Review the persistence boundary.  \n"
    model.baseReference = "   "
    let request = try model.request(runID: "ui-run")

    #expect(request.role.name == "Advisor")
    #expect(request.taskPrompt == "Review the persistence boundary.")
    #expect(request.baseReference == "HEAD")
    #expect(request.runID == "ui-run")
}
