import Foundation
import Testing

@testable import RafuApp

@MainActor
@Test("Constructing Ensemble Settings performs no catalog or file work")
func ensembleSettingsConstructionDoesNoIO() async throws {
    var providerCalls = 0
    let model = EnsembleSettingsModel {
        providerCalls += 1
        return try ConductorBundledSkillCatalog.bundled()
    }

    #expect(providerCalls == 0)
    #expect(model.loadState == .idle)
    #expect(model.metadata == nil)
    #expect(!model.isInstalling)
    #expect(model.operationMessage == nil)
    #expect(model.errorMessage == nil)

    await model.load()
    #expect(providerCalls == 1)
    #expect(model.loadState == .ready)
    #expect(model.metadata?.name == "rafu-ensemble")
}

@MainActor
@Test("Ensemble Settings exposes exact install result state")
func ensembleSettingsInstallResultState() async throws {
    let destination = FileManager.default.temporaryDirectory
        .appending(path: "rafu-settings-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    let model = EnsembleSettingsModel()

    await model.load()
    await model.install(at: .custom(destination))

    let expected = destination.appending(
        path: ConductorBundledSkillCatalog.skillIdentifier,
        directoryHint: .isDirectory)
    #expect(!model.isInstalling)
    #expect(
        model.operationMessage
            == "Installed at \(expected.path) and 1 more beside it: 6 written, 0 replaced, 0 skipped."
    )
    #expect(
        FileManager.default.fileExists(
            atPath: destination.appending(path: "rafu-view/SKILL.md").path))
    #expect(model.pendingReplacement == nil)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test("Installing for Codex writes only inside the Codex skills folder")
func ensembleSettingsInstallsForCodex() async throws {
    let home = FileManager.default.temporaryDirectory
        .appending(path: "rafu-settings-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let model = EnsembleSettingsModel(homeDirectory: home)

    await model.load()
    await model.install(at: .codex)

    let skill = home.appending(path: ".codex/skills/rafu-ensemble/SKILL.md")
    #expect(FileManager.default.fileExists(atPath: skill.path))
    #expect(
        FileManager.default.fileExists(
            atPath: home.appending(path: ".codex/skills/rafu-view/references/examples.md").path))
    #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude").path))
    #expect(model.errorMessage == nil)
}

@Test("Agent skill copy names both verified folders")
func ensembleSkillCopyNamesVerifiedFolders() {
    #expect(EnsembleSkillCopy.footer.contains("~/.claude/skills/rafu-ensemble"))
    #expect(EnsembleSkillCopy.footer.contains("~/.codex/skills/rafu-ensemble"))
    #expect(!EnsembleSkillCopy.summary.contains("Conductor"))
}

@MainActor
@Test("A conflict in any skill writes nothing until the user confirms")
func ensembleSettingsAsksBeforeAnySkillIsWritten() async throws {
    let destination = FileManager.default.temporaryDirectory
        .appending(path: "rafu-settings-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
    let view = destination.appending(path: "rafu-view", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: view, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destination) }
    try Data("user-authored".utf8).write(to: view.appending(path: "SKILL.md"))
    let model = EnsembleSettingsModel()

    await model.load()
    #expect(model.skillNames == ["rafu-ensemble", "rafu-view"])
    await model.install(at: .custom(destination))
    #expect(model.pendingReplacement?.conflicts == ["rafu-view/SKILL.md"])
    #expect(
        !FileManager.default.fileExists(
            atPath: destination.appending(path: "rafu-ensemble").path))

    await model.install(at: .custom(destination), replaceConfirmed: true)
    #expect(model.errorMessage == nil)
    #expect(
        try String(contentsOf: view.appending(path: "SKILL.md"), encoding: .utf8)
            .hasPrefix("---\nname: rafu-view"))
}
