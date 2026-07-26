import Foundation
import Testing

@testable import RafuApp

/// The resolver four surfaces share. Its precedence is the contract; its
/// refusal to guess is the safety property.
@Suite("Conductor model resolution")
struct ConductorModelResolutionTests {
    private static let catalog = [
        ConductorModelChoice(id: "gpt-5.6", displayName: "GPT-5.6", source: .curated),
        ConductorModelChoice(id: "claude-haiku-4-5", displayName: "Haiku 4.5", source: .curated),
    ]

    @Test("Explicit beats the ensemble default, which beats the Settings default")
    func precedence() {
        let explicit = ConductorModelResolution.resolve(
            explicit: "gpt-5.6", ensembleDefault: "a", settingsDefault: "b")
        #expect(explicit.modelID == "gpt-5.6")
        #expect(explicit.source == .explicit)

        let ensemble = ConductorModelResolution.resolve(
            explicit: nil, ensembleDefault: "a", settingsDefault: "b")
        #expect(ensemble.modelID == "a")
        #expect(ensemble.source == .ensembleDefault)

        let settings = ConductorModelResolution.resolve(
            explicit: nil, ensembleDefault: nil, settingsDefault: "b")
        #expect(settings.modelID == "b")
        #expect(settings.source == .settingsDefault)
    }

    /// `""` is the established "not set" value in `ConductorDefaultModelStore`,
    /// so an empty string at any level must fall through rather than resolve to
    /// a model with an empty name.
    @Test("Empty and whitespace-only values fall through at every level")
    func emptyValuesFallThrough() {
        let resolution = ConductorModelResolution.resolve(
            explicit: "", ensembleDefault: "   ", settingsDefault: "\n\t")
        #expect(resolution.modelID == nil)
        #expect(resolution.source == .cliDecides)

        let trailing = ConductorModelResolution.resolve(
            explicit: "  gpt-5.6  ", ensembleDefault: nil, settingsDefault: nil)
        #expect(trailing.modelID == "gpt-5.6", "the value handed to --model must be trimmed")
    }

    /// The safety property: with nothing set, the adapter passes no `--model`
    /// flag and the CLI applies its own config. Rafu cannot read that, so it
    /// must say so rather than name the first curated model — a guess that
    /// looks like knowledge and is wrong exactly when it matters.
    @Test("With nothing set, no model is named and no catalog entry is guessed")
    func unsetNamesNoModel() {
        let resolution = ConductorModelResolution.resolve(
            explicit: nil, ensembleDefault: nil, settingsDefault: nil, catalog: Self.catalog)
        #expect(resolution.modelID == nil)
        #expect(resolution.source == .cliDecides)
        #expect(!resolution.namesAModel)
        #expect(resolution.displayName == "CLI default")
        #expect(resolution.displayName != Self.catalog[0].displayName)
        #expect(resolution.displayName != Self.catalog[0].id)
    }

    @Test("A catalog id displays its friendly name; an unknown id displays itself")
    func displayNames() {
        let known = ConductorModelResolution.resolve(
            explicit: "claude-haiku-4-5", ensembleDefault: nil, settingsDefault: nil,
            catalog: Self.catalog)
        #expect(known.displayName == "Haiku 4.5")

        // A model Rafu has never heard of is still legitimate — the user may
        // run anything their CLI accepts — so it resolves and displays as
        // itself rather than being rejected or hidden.
        let unknown = ConductorModelResolution.resolve(
            explicit: "some-private-model", ensembleDefault: nil, settingsDefault: nil,
            catalog: Self.catalog)
        #expect(unknown.modelID == "some-private-model")
        #expect(unknown.displayName == "some-private-model")
    }

    /// The detailed label exists so a user can tell their own choice from an
    /// inherited one. If every source rendered identically the label would be
    /// decorative.
    @Test("The detailed label distinguishes an inherited default from a chosen one")
    func detailedLabelNamesItsSource() {
        let ensemble = ConductorModelResolution.resolve(
            explicit: nil, ensembleDefault: "gpt-5.6", settingsDefault: nil, catalog: Self.catalog)
        let settings = ConductorModelResolution.resolve(
            explicit: nil, ensembleDefault: nil, settingsDefault: "gpt-5.6", catalog: Self.catalog)
        let explicit = ConductorModelResolution.resolve(
            explicit: "gpt-5.6", ensembleDefault: nil, settingsDefault: nil, catalog: Self.catalog)

        #expect(ensemble.detailedLabel != settings.detailedLabel)
        #expect(explicit.detailedLabel == "GPT-5.6")
        #expect(ensemble.detailedLabel.contains("Ensemble"))
        #expect(
            settings.detailedLabel.contains("Settings")
                || settings.detailedLabel.contains("your default"))
    }

    /// This string drifted once already — run detail said "Adapter default",
    /// the creation canvas said "Provider default", for the same state — and
    /// the drift was invisible because each site read correctly on its own.
    /// Every surface now reads one constant, so a source scan is the guard
    /// that keeps a fresh literal from reintroducing a second vocabulary.
    @Test("One unset wording, referenced rather than retyped, across every surface")
    func unsetWordingIsCentralised() throws {
        let sites = [
            "Sources/RafuApp/Conductor/Run/ConductorRunPresentation.swift",
            "Sources/RafuApp/Views/EnsembleModelField.swift",
            "Sources/RafuApp/Settings/ConductorSettingsTab.swift",
        ]
        for site in sites {
            let text = try Self.source(site)
            #expect(
                text.contains("ConductorModelResolution.unsetLabel"),
                "\(site) should reference the shared constant")
            // Comments are excluded deliberately: the doc comment on
            // `unsetModelLabel` *quotes* both retired strings to explain why
            // they were retired, and a scan that punished the explanation
            // would push the reasoning out of the code.
            for line in Self.codeLines(text) {
                #expect(
                    !line.contains("\"Adapter default\""),
                    "\(site) still carries the old wording that named the wrong party")
                #expect(
                    !line.contains("\"Provider default\""),
                    "\(site) still carries the creation canvas's competing wording")
            }
        }
    }

    @Test("A caller may state its own unset wording without changing the semantics")
    func customUnsetLabel() {
        let resolution = ConductorModelResolution.resolve(
            explicit: nil, ensembleDefault: nil, settingsDefault: nil,
            unsetLabel: "Adapter default")
        #expect(resolution.displayName == "Adapter default")
        #expect(resolution.modelID == nil)
        #expect(resolution.source == .cliDecides)
    }

    /// Lines that are not `//` comments. Crude on purpose — it does not try to
    /// parse block comments or strings, because the only thing it must get
    /// right is "don't fail the file for explaining itself".
    private static func codeLines(_ text: String) -> [Substring] {
        text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ModelResolutionTestError.repositoryRootNotFound
    }

    private enum ModelResolutionTestError: Error {
        case repositoryRootNotFound
    }
}
