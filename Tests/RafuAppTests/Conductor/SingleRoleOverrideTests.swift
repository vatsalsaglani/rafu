import Foundation
import Testing

@testable import RafuApp

/// The New Run model needs an authenticated provider to make its availability
/// gate executable. The run itself still uses `FakeConductorAdapter`, so the
/// manifest path stays on the suite's established fake-launcher seam.
nonisolated struct ReadySingleRoleFixtureAdapter: ConductorCLIAdapter {
    let id: ConductorCLIID
    let defaultEnabled = true
    let supportsModelDiscovery = false
    let readOnlyHandoffSupport = ConductorReadOnlyHandoffSupport.supported

    func probe() async -> AdapterProbe {
        AdapterProbe(
            installed: true,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            version: "single-role-fixture-1")
    }

    func authStatus() async -> AdapterAuthStatus { .authenticated }

    func curatedModels() -> [ConductorModelChoice] {
        FakeConductorAdapter.curatedModelChoices
    }

    func discoverModels() async -> [ConductorModelChoice]? { nil }

    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation {
        AdapterInvocation(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [prompt],
            environment: [:])
    }
}

private func writeSingleRoleAgent(
    provider: ConductorCLIID = .claudeCode,
    model: String = "frontmatter-model",
    to workspaceRoot: URL
) throws -> (url: URL, bytes: Data) {
    let url = RafuDotDirectory(workspaceRoot: workspaceRoot).agentsURL
        .appending(path: "reviewer.md", directoryHint: .notDirectory)
    let bytes = Data(
        """
        ---
        name: Reviewer
        provider: \(provider.rawValue)
        model: \(model)
        autonomy: readOnly
        handoffArtifact: brief.md
        ---
        Review the assigned work and write the brief.
        """.utf8)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url, options: .atomic)
    return (url, bytes)
}

@MainActor
private func makeSingleRoleOverrideModel() -> ConductorNewRunModel {
    ConductorNewRunModel(
        adapters: [
            ReadySingleRoleFixtureAdapter(id: .claudeCode),
            ReadySingleRoleFixtureAdapter(id: .codex),
        ])
}

@MainActor
@Suite("Single Role overrides")
struct SingleRoleOverrideTests {
    @Test("Single Role defaults come from the selected agent frontmatter")
    func frontmatterDefaults() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeSingleRoleAgent(to: root)

        let model = makeSingleRoleOverrideModel()
        await model.load(workspaceRoot: root)
        model.taskPrompt = "Review the change."

        #expect(model.singleRoleProvider == .claudeCode)
        #expect(model.singleRoleModel == "frontmatter-model")
        let request = try model.request(runID: "frontmatter-defaults")
        #expect(request.role.provider == .claudeCode)
        #expect(request.role.model == "frontmatter-model")
    }

    @Test("A Single Role override is snapshotted into the manifest binding")
    func overrideIsRecordedInBinding() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeSingleRoleAgent(to: root)

        let model = makeSingleRoleOverrideModel()
        await model.load(workspaceRoot: root)
        model.taskPrompt = "Review the change."
        model.selectSingleRoleProvider(.codex)
        model.singleRoleModel = "per-run-model"

        let controller = ConductorRunController(adapters: [FakeConductorAdapter(id: .codex)])
        controller.attach(workspaceRoot: root)
        await controller.start(
            try model.request(runID: "single-role-override"),
            launcher: WorkflowFakeLauncher())

        let manifest = try #require(controller.manifest)
        #expect(manifest.steps[0].binding.provider == .codex)
        #expect(manifest.steps[0].binding.model == "per-run-model")
        controller.abort()
    }

    @Test("An overridden Single Role run never edits the selected agent file")
    func overriddenRunLeavesAgentFileUntouched() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try writeSingleRoleAgent(to: root)

        let model = makeSingleRoleOverrideModel()
        await model.load(workspaceRoot: root)
        model.taskPrompt = "Review the change."
        model.selectSingleRoleProvider(.codex)
        model.singleRoleModel = "custom-run-model"

        let controller = ConductorRunController(adapters: [FakeConductorAdapter(id: .codex)])
        controller.attach(workspaceRoot: root)
        await controller.start(
            try model.request(runID: "single-role-file-integrity"),
            launcher: WorkflowFakeLauncher())

        #expect(try Data(contentsOf: agent.url) == agent.bytes)
        controller.abort()
    }
}
