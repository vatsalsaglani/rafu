import Foundation
import Testing

@testable import RafuApp

private func makeTemplateRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-template-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let templateFakeAdapters: [any ConductorCLIAdapter] = [
    FakeConductorAdapter(id: .claudeCode),
    FakeConductorAdapter(id: .codex),
    FakeConductorAdapter(id: .geminiCLI),
]

@MainActor
@Test("All bundled templates instantiate as valid file-backed workflows")
func bundledTemplatesInstantiateAsValidLibraries() async throws {
    let catalog = try ConductorBundledTemplateCatalog.bundled()
    #expect(
        ConductorBundledTemplateCatalog.templates.map(\.id)
            == ["advise-implement-document", "review-only", "implement-review"])

    for template in ConductorBundledTemplateCatalog.templates {
        let root = try makeTemplateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await ConductorTemplateInstantiator(catalog: catalog).instantiate(
            templateID: template.id,
            at: .repository(workspaceRoot: root))
        #expect(result.created.count == template.files.count)
        #expect(!result.requiresConfirmation)

        let snapshot = try await ConductorDefinitionLibrary(
            adapters: templateFakeAdapters,
            enableStore: ConductorEnableStore()
        ).load(
            workspaceRoot: root,
            userLibraryRoot: root.appending(path: "absent-global"))
        #expect(snapshot.agents.allSatisfy { $0.isLaunchable })
        #expect(snapshot.launchableWorkflows.count == 1)
    }
}

@MainActor
@Test("The flagship template binds three providers and leaves models for the user")
func flagshipTemplateDemonstratesProviderChoiceWithoutModels() async throws {
    let root = try makeTemplateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = try ConductorBundledTemplateCatalog.bundled()
    _ = try await ConductorTemplateInstantiator(catalog: catalog).instantiate(
        templateID: "advise-implement-document",
        at: .repository(workspaceRoot: root))
    let snapshot = try await ConductorDefinitionLibrary(
        adapters: templateFakeAdapters
    ).load(
        workspaceRoot: root,
        userLibraryRoot: root.appending(path: "absent-global"))

    let definitions = snapshot.agents.compactMap(\.definition)
    #expect(Set(definitions.map(\.provider)) == [.claudeCode, .codex, .geminiCLI])
    #expect(definitions.allSatisfy { $0.model.isEmpty })
}

@MainActor
@Test("Template instantiation is idempotent and reports unchanged files")
func templateInstantiationIsIdempotent() async throws {
    let root = try makeTemplateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = try ConductorBundledTemplateCatalog.bundled()
    let instantiator = ConductorTemplateInstantiator(catalog: catalog)

    let first = try await instantiator.instantiate(
        templateID: "review-only",
        at: .repository(workspaceRoot: root))
    let second = try await instantiator.instantiate(
        templateID: "review-only",
        at: .repository(workspaceRoot: root))

    #expect(first.created == ["agents/reviewer.md", "workflows/review-only.md"])
    #expect(second.created.isEmpty)
    #expect(second.replaced.isEmpty)
    #expect(second.unchanged == ["agents/reviewer.md", "workflows/review-only.md"])
}

@MainActor
@Test("A conflicting file blocks the entire copy until replacement is explicitly confirmed")
func templateConflictRequiresConfirmation() async throws {
    let root = try makeTemplateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let agents = root.appending(path: ".rafu/agents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let reviewer = agents.appending(path: "reviewer.md")
    try Data("custom content".utf8).write(to: reviewer)
    let catalog = try ConductorBundledTemplateCatalog.bundled()
    let instantiator = ConductorTemplateInstantiator(catalog: catalog)

    let refused = try await instantiator.instantiate(
        templateID: "review-only",
        at: .repository(workspaceRoot: root))
    #expect(refused.conflicts == ["agents/reviewer.md"])
    #expect(refused.created.isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appending(path: ".rafu/workflows/review-only.md").path))
    #expect(try String(contentsOf: reviewer, encoding: .utf8) == "custom content")

    let confirmed = try await instantiator.instantiate(
        templateID: "review-only",
        at: .repository(workspaceRoot: root),
        existingFilePolicy: .replaceConfirmed)
    #expect(confirmed.replaced == ["agents/reviewer.md"])
    #expect(confirmed.created == ["workflows/review-only.md"])
    #expect(try String(contentsOf: reviewer, encoding: .utf8) != "custom content")
}

@MainActor
@Test("Template instantiation refuses a symlinked definition directory")
func templateInstantiationRefusesSymlinkedDirectory() async throws {
    let root = try makeTemplateRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dot = RafuDotDirectory(workspaceRoot: root)
    let outside = root.appending(path: "outside-agents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: dot.directoryURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: dot.agentsURL, withDestinationURL: outside)
    let catalog = try ConductorBundledTemplateCatalog.bundled()

    await #expect(throws: ConductorTemplateInstantiationError.self) {
        _ = try await ConductorTemplateInstantiator(catalog: catalog).instantiate(
            templateID: "review-only",
            at: .repository(workspaceRoot: root))
    }
}
