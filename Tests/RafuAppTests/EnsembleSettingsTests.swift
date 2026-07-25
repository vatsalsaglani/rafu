import Foundation
import RafuCore
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
    #expect(model.metadata?.name == "ensemble-with-rafu")
}

@MainActor
@Test("Ensemble Settings reports matching and mismatching verb versions")
func ensembleSettingsVersionCompatibility() async {
    let matching = EnsembleSettingsModel(
        launcherVerbVersion: LauncherIPCProtocol.ensembleVerbVersion)
    let mismatching = EnsembleSettingsModel(
        launcherVerbVersion: LauncherIPCProtocol.ensembleVerbVersion + 1)

    await matching.load()
    await mismatching.load()

    #expect(matching.verbVersionsMatch)
    #expect(!mismatching.verbVersionsMatch)
    #expect(
        matching.metadata?.targetsVerbVersion
            == LauncherIPCProtocol.ensembleVerbVersion)
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
            == "Installed at \(expected.path): 5 written, 0 replaced, 0 skipped.")
    #expect(model.pendingReplacement == nil)
    #expect(model.errorMessage == nil)
}
