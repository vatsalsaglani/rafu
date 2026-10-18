import Foundation
import RafuCore
import Testing

@testable import RafuApp

private let expectedSkillFiles = [
    "SKILL.md",
    "references/codex-agents-snippet.md",
    "references/recipes.md",
    "references/tools.md",
]

private func makeSkillTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
@Test("The Rafu agent skill bundles with parseable frontmatter")
func bundledAgentSkillResolves() async throws {
    let catalog = try ConductorBundledSkillCatalog.bundled()
    #expect(catalog.manifest.map(\.relativePath).sorted() == expectedSkillFiles)

    for file in catalog.manifest {
        let data = try catalog.data(for: file)
        #expect(!data.isEmpty)
        #expect(data.count <= ConductorBundledSkillCatalog.maximumSkillFileBytes)
    }

    let metadata = try await ConductorSkillInstaller(catalog: catalog).metadata()
    #expect(metadata.name == "rafu-ensemble")
    #expect(metadata.description.contains("Ensemble"))
    #expect(!metadata.description.contains("Conductor"))
}

@MainActor
@Test("The agent skill names every orchestration tool")
func bundledAgentSkillCoversEveryTool() throws {
    let catalog = try ConductorBundledSkillCatalog.bundled()
    let reference = try catalog.data(for: .init(pathComponents: ["references", "tools.md"]))
    let text = String(decoding: reference, as: UTF8.self)
    for tool in CanvasAgentTool.allCases {
        #expect(text.contains("`\(tool.rawValue)`"), "tools.md does not name \(tool.rawValue)")
    }
}

@Test("Skill frontmatter parsing reads keys and rejects a missing block")
func skillFrontmatterParsing() throws {
    let values = try ConductorBundledSkillCatalog.frontmatter(
        "---\nname: rafu-ensemble\nDescription: Use it: well\n  nested: no\n---\n# Body")
    #expect(values["name"] == "rafu-ensemble")
    #expect(values["description"] == "Use it: well")
    #expect(values["nested"] == nil)
    #expect(throws: ConductorBundledSkillError.self) {
        try ConductorBundledSkillCatalog.frontmatter("# No frontmatter")
    }
}

@MainActor
@Test("A fresh skill install creates every file and an idempotent reinstall skips them")
func skillInstallationIsFreshThenIdempotent() async throws {
    let destination = try makeSkillTestDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }
    let catalog = try ConductorBundledSkillCatalog.bundled()
    let installer = ConductorSkillInstaller(catalog: catalog)
    let expectedRoot = destination.appending(
        path: ConductorBundledSkillCatalog.skillIdentifier,
        directoryHint: .isDirectory)

    let first = try await installer.install(at: .custom(destination))
    let second = try await installer.install(at: .custom(destination))

    #expect(first.created.sorted() == expectedSkillFiles)
    #expect(first.replaced.isEmpty)
    #expect(first.unchanged.isEmpty)
    #expect(first.destinationDescription == expectedRoot.path)
    #expect(second.created.isEmpty)
    #expect(second.replaced.isEmpty)
    #expect(second.unchanged.sorted() == expectedSkillFiles)
    #expect(second.destinationDescription == expectedRoot.path)
}

@MainActor
@Test("A skill conflict writes nothing before confirmation, then replaces only after confirmation")
func skillConflictRequiresConfirmedReplacement() async throws {
    let destination = try makeSkillTestDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }
    let skillRoot = destination.appending(
        path: ConductorBundledSkillCatalog.skillIdentifier,
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    let skillFile = skillRoot.appending(path: "SKILL.md", directoryHint: .notDirectory)
    try Data("user-authored skill".utf8).write(to: skillFile)

    let catalog = try ConductorBundledSkillCatalog.bundled()
    let installer = ConductorSkillInstaller(catalog: catalog)
    let refused = try await installer.install(at: .custom(destination))

    #expect(refused.conflicts == ["SKILL.md"])
    #expect(refused.created.isEmpty)
    #expect(refused.replaced.isEmpty)
    #expect(try String(contentsOf: skillFile, encoding: .utf8) == "user-authored skill")
    #expect(
        !FileManager.default.fileExists(
            atPath: skillRoot.appending(path: "references", directoryHint: .isDirectory).path))

    let confirmed = try await installer.install(
        at: .custom(destination),
        existingFilePolicy: .replaceConfirmed)
    #expect(confirmed.replaced == ["SKILL.md"])
    #expect(confirmed.created.count == expectedSkillFiles.count - 1)
    #expect(try String(contentsOf: skillFile, encoding: .utf8) != "user-authored skill")
}

@MainActor
@Test("The skill installer refuses every unsafe manifest path component")
func skillInstallerRefusesUnsafeManifestPath() async throws {
    let destination = try makeSkillTestDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }
    let bundled = try ConductorBundledSkillCatalog.bundled()
    let catalog = ConductorBundledSkillCatalog(
        resourceRootURL: bundled.resourceRootURL,
        manifest: [.init(pathComponents: ["references", "..", "SKILL.md"])])
    let installer = ConductorSkillInstaller(catalog: catalog)

    await #expect(
        throws: ConductorBundledSkillError.unsafeResourcePath(
            "rafu-ensemble/references/../SKILL.md")
    ) {
        _ = try await installer.install(at: .custom(destination))
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: destination.appending(
                path: ConductorBundledSkillCatalog.skillIdentifier,
                directoryHint: .isDirectory
            ).path))
}

@MainActor
@Test(
    "Claude Code and Codex destinations report the exact skill paths",
    arguments: [
        (ConductorSkillDestination.claudeCode, ".claude"),
        (ConductorSkillDestination.codex, ".codex"),
    ])
func vendorSkillDestinationsAreExact(destination: ConductorSkillDestination, folder: String)
    async throws
{
    let fakeHome = try makeSkillTestDirectory()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let catalog = try ConductorBundledSkillCatalog.bundled()
    let installer = ConductorSkillInstaller(catalog: catalog, homeDirectory: fakeHome)
    let result = try await installer.install(at: destination)
    let expected =
        fakeHome
        .appending(path: folder, directoryHint: .isDirectory)
        .appending(path: "skills", directoryHint: .isDirectory)
        .appending(
            path: ConductorBundledSkillCatalog.skillIdentifier,
            directoryHint: .isDirectory)

    #expect(result.destinationDescription == expected.path)
    #expect(installer.destinationRootURL(for: destination).path == expected.path)
    #expect(result.created.count == expectedSkillFiles.count)
}
