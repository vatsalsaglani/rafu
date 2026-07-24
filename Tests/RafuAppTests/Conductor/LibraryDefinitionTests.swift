import Foundation
import Testing

@testable import RafuApp

private struct LibraryTestRoots {
    let container: URL
    let workspace: URL
    let userLibrary: URL
}

private func makeLibraryTestRoots() throws -> LibraryTestRoots {
    let container = FileManager.default.temporaryDirectory
        .appending(path: "rafu-library-\(UUID().uuidString)", directoryHint: .isDirectory)
    let workspace = container.appending(path: "workspace", directoryHint: .isDirectory)
    let userLibrary = container.appending(path: "user-library", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return LibraryTestRoots(
        container: container,
        workspace: workspace,
        userLibrary: userLibrary)
}

private func writeLibraryFile(
    _ text: String,
    under directory: URL,
    name: String
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(
        to: directory.appending(path: name, directoryHint: .notDirectory),
        options: .atomic)
}

private func libraryAgentText(
    name: String,
    provider: String = ConductorCLIID.claudeCode.rawValue,
    autonomy: String = ConductorAutonomy.readOnly.rawValue
) -> String {
    """
    ---
    name: \(name)
    provider: \(provider)
    autonomy: \(autonomy)
    handoffArtifact: \(name.lowercased()).md
    ---
    Follow the role instructions.
    """
}

private func libraryWorkflowText(name: String, step: String) -> String {
    """
    ---
    name: \(name)
    steps:
      - \(step)
    ---
    """
}

private func makeLibrary(
    adapters: [any ConductorCLIAdapter] = [
        FakeConductorAdapter(id: .claudeCode)
    ],
    suiteName: String? = nil
) -> ConductorDefinitionLibrary {
    ConductorDefinitionLibrary(
        adapters: adapters,
        enableStore: ConductorEnableStore(suiteName: suiteName))
}

@Test("Repository definitions override same-stem user definitions while both keep scope labels")
func repositoryDefinitionsOverrideGlobalWithLabels() async throws {
    let roots = try makeLibraryTestRoots()
    defer { try? FileManager.default.removeItem(at: roots.container) }
    let dot = RafuDotDirectory(workspaceRoot: roots.workspace)

    try writeLibraryFile(
        libraryAgentText(name: "Advisor"),
        under: roots.userLibrary.appending(path: "agents"),
        name: "advisor.md")
    try writeLibraryFile(
        libraryWorkflowText(name: "Global Ship", step: "Advisor"),
        under: roots.userLibrary.appending(path: "workflows"),
        name: "ship.md")
    try writeLibraryFile(
        libraryWorkflowText(name: "Repository Ship", step: "Advisor"),
        under: dot.workflowsURL,
        name: "ship.md")

    let snapshot = try await makeLibrary().load(
        workspaceRoot: roots.workspace,
        userLibraryRoot: roots.userLibrary)

    #expect(snapshot.workflows.count == 2)
    #expect(snapshot.workflows.map(\.scope) == [.repository, .userGlobal])
    #expect(snapshot.workflows.map(\.scope.displayName) == ["Repository", "User"])
    #expect(
        snapshot.workflows.map(\.resolution)
            == [.selected, .overriddenByRepository])
    #expect(snapshot.launchableWorkflows.map(\.displayName) == ["Repository Ship"])
}

@Test("A malformed repository override shadows the global file instead of silently falling back")
func malformedRepositoryOverrideStillShadowsGlobal() async throws {
    let roots = try makeLibraryTestRoots()
    defer { try? FileManager.default.removeItem(at: roots.container) }
    let dot = RafuDotDirectory(workspaceRoot: roots.workspace)

    try writeLibraryFile(
        libraryAgentText(name: "Advisor"),
        under: roots.userLibrary.appending(path: "agents"),
        name: "advisor.md")
    try writeLibraryFile(
        libraryWorkflowText(name: "Global Ship", step: "Advisor"),
        under: roots.userLibrary.appending(path: "workflows"),
        name: "ship.md")
    try writeLibraryFile(
        "---\nname: Broken\nsteps:\n---\n",
        under: dot.workflowsURL,
        name: "ship.md")

    let snapshot = try await makeLibrary().load(
        workspaceRoot: roots.workspace,
        userLibraryRoot: roots.userLibrary)

    let repository = try #require(snapshot.workflows.first { $0.scope == .repository })
    let global = try #require(snapshot.workflows.first { $0.scope == .userGlobal })
    #expect(repository.resolution == .selected)
    #expect(repository.issues.map(\.kind) == [.parseError])
    #expect(global.resolution == .overriddenByRepository)
    #expect(snapshot.launchableWorkflows.isEmpty)
}

@Test(
    "Definition errors stay inline and include provider, autonomy, enablement, and binding failures"
)
func definitionValidationStaysInline() async throws {
    let roots = try makeLibraryTestRoots()
    defer { try? FileManager.default.removeItem(at: roots.container) }
    let suiteName = "rafu-library-validation-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let store = ConductorEnableStore(suiteName: suiteName)
    store.setEnabled(false, for: .codex)
    let dot = RafuDotDirectory(workspaceRoot: roots.workspace)

    try writeLibraryFile(
        libraryAgentText(name: "Valid"),
        under: dot.agentsURL,
        name: "valid.md")
    try writeLibraryFile(
        libraryAgentText(name: "Unknown", provider: "notAProvider"),
        under: dot.agentsURL,
        name: "unknown-provider.md")
    try writeLibraryFile(
        libraryAgentText(name: "Unsupported", provider: "geminiCLI", autonomy: "fullAccess"),
        under: dot.agentsURL,
        name: "unsupported.md")
    try writeLibraryFile(
        libraryAgentText(name: "Disabled", provider: "codex"),
        under: dot.agentsURL,
        name: "disabled.md")
    try writeLibraryFile(
        libraryWorkflowText(name: "Valid Flow", step: "Valid"),
        under: dot.workflowsURL,
        name: "valid.md")
    try writeLibraryFile(
        libraryWorkflowText(name: "Missing Role", step: "Ghost"),
        under: dot.workflowsURL,
        name: "missing.md")
    try writeLibraryFile(
        libraryWorkflowText(name: "Invalid Role", step: "Unsupported"),
        under: dot.workflowsURL,
        name: "invalid-role.md")

    let library = makeLibrary(
        adapters: [
            FakeConductorAdapter(id: .claudeCode),
            FakeConductorAdapter(id: .codex),
            FakeConductorAdapter(id: .geminiCLI),
        ],
        suiteName: suiteName)
    let snapshot = try await library.load(
        workspaceRoot: roots.workspace,
        userLibraryRoot: roots.userLibrary)

    #expect(
        snapshot.agents.first { $0.stem == "unknown-provider" }?.issues.map(\.kind)
            == [.parseError])
    #expect(
        snapshot.agents.first { $0.stem == "unsupported" }?.issues.map(\.kind)
            == [.unsupportedAutonomy])
    #expect(
        snapshot.agents.first { $0.stem == "disabled" }?.issues.map(\.kind)
            == [.adapterDisabled])
    #expect(
        snapshot.workflows.first { $0.stem == "missing" }?.issues.map(\.kind)
            == [.unknownAgent])
    #expect(
        snapshot.workflows.first { $0.stem == "invalid-role" }?.issues.map(\.kind)
            == [.invalidAgent])
    #expect(snapshot.launchableWorkflows.map(\.displayName) == ["Valid Flow"])
}

@Test("Library discovery is read-only when both scopes are absent")
func absentLibraryScopesStayReadOnly() async throws {
    let roots = try makeLibraryTestRoots()
    defer { try? FileManager.default.removeItem(at: roots.container) }

    let snapshot = try await makeLibrary().load(
        workspaceRoot: roots.workspace,
        userLibraryRoot: roots.userLibrary)

    #expect(snapshot.agents.isEmpty)
    #expect(snapshot.workflows.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: roots.workspace.appending(path: ".rafu").path))
    #expect(!FileManager.default.fileExists(atPath: roots.userLibrary.path))
}

@Test("A symlinked definition is visible as unsafe and is never parsed")
func symlinkedDefinitionIsInlineUnsafe() async throws {
    let roots = try makeLibraryTestRoots()
    defer { try? FileManager.default.removeItem(at: roots.container) }
    let dot = RafuDotDirectory(workspaceRoot: roots.workspace)
    let outside = roots.container.appending(path: "outside.md")
    try Data(libraryAgentText(name: "Outside").utf8).write(to: outside)
    try FileManager.default.createDirectory(
        at: dot.agentsURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: dot.agentsURL.appending(path: "linked.md"),
        withDestinationURL: outside)

    let snapshot = try await makeLibrary().load(
        workspaceRoot: roots.workspace,
        userLibraryRoot: roots.userLibrary)

    let linked = try #require(snapshot.agents.first)
    #expect(linked.definition == nil)
    #expect(linked.issues.map(\.kind) == [.unsafeFile])
}
