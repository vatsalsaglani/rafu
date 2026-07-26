import Foundation
import RafuCore
import Testing

@testable import RafuApp

private let expectedSkillFiles = [
    "SKILL.md",
    "references/file-formats.md",
    "references/patterns.md",
    "references/troubleshooting.md",
    "references/verbs.md",
]

private func makeSkillTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
@Test("The five-file coordinator skill bundles with parseable versioned frontmatter")
func bundledSkillPackResolvesAndTargetsCurrentVerbVersion() async throws {
    let catalog = try ConductorBundledSkillCatalog.bundled()
    #expect(catalog.manifest.map(\.relativePath).sorted() == expectedSkillFiles)

    for file in catalog.manifest {
        let data = try catalog.data(for: file)
        #expect(!data.isEmpty)
        #expect(data.count <= ConductorBundledSkillCatalog.maximumSkillFileBytes)
    }

    let metadata = try await ConductorSkillInstaller(catalog: catalog).metadata()
    #expect(metadata.name == "ensemble-with-rafu")
    #expect(
        metadata.description
            == "Orchestrate parallel agent runs in Rafu via rafu ensemble — worktrees, gates, budgets"
    )
    #expect(metadata.targetsVerbVersion == LauncherIPCProtocol.ensembleVerbVersion)
}

@MainActor
@Test("verbs.md names every verb represented by the shipped parser")
func skillVerbReferenceCoversParserCases() throws {
    let catalog = try ConductorBundledSkillCatalog.bundled()
    let verbsFile = try #require(
        catalog.manifest.first(where: { $0.relativePath == "references/verbs.md" }))
    let text = try #require(String(data: catalog.data(for: verbsFile), encoding: .utf8))
    let parser = EnsembleArgumentParser()
    let invocations = try [
        parser.parse(["status", "--json"]),
        parser.parse(["artifact", "run-a", "0", "--json"]),
        parser.parse(["await", "run-a", "--state", "completed", "--json"]),
        parser.parse(["help"]),
    ]

    for invocation in invocations {
        let verb =
            switch invocation {
            case .status:
                "status"
            case .artifact:
                "artifact"
            case .await:
                "await"
            case .help:
                "help"
            }
        #expect(text.contains("`\(verb)`"), "Missing parser verb \(verb)")
    }
}

@MainActor
@Test("A fresh skill install creates five files and an idempotent reinstall skips all five")
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
    #expect(confirmed.created.count == 4)
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
            "ensemble-with-rafu/references/../SKILL.md")
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
@Test("The Claude Code destination reports the exact verified skill path")
func claudeCodeSkillDestinationIsExact() async throws {
    let fakeHome = try makeSkillTestDirectory()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let catalog = try ConductorBundledSkillCatalog.bundled()
    let installer = ConductorSkillInstaller(catalog: catalog, homeDirectory: fakeHome)
    let result = try await installer.install(at: .claudeCode)
    let expected =
        fakeHome
        .appending(path: ".claude", directoryHint: .isDirectory)
        .appending(path: "skills", directoryHint: .isDirectory)
        .appending(
            path: ConductorBundledSkillCatalog.skillIdentifier,
            directoryHint: .isDirectory)

    #expect(result.destinationDescription == expected.path)
    #expect(result.created.count == 5)
}
