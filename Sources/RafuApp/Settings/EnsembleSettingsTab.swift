import SwiftUI
import UniformTypeIdentifiers

/// Settings > Ensemble: installs the Rafu agent skill that teaches Claude Code
/// and Codex to use the Ensemble tools.
struct EnsembleSettingsSection: View {
    @State private var model = EnsembleSettingsModel()
    @State private var isFolderImporterPresented = false
    @State private var installTask: Task<Void, Never>?
    @AppStorage(CanvasChannelPromptPreference.key) private var confirmsChannelPrompt = true

    var body: some View {
        Section {
            Toggle(
                "Confirm Rafu's development-channel prompt automatically",
                isOn: $confirmsChannelPrompt
            )
            .help(EnsembleChannelPromptCopy.help)
        } header: {
            Text("Claude Code Prompt")
        } footer: {
            Text(EnsembleChannelPromptCopy.footer)
        }

        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.skillNames.joined(separator: ", "))
                    .font(.body.weight(.medium))
                Text(
                    model.loadState == .ready
                        ? EnsembleSkillCopy.summary
                        : "Loading the bundled agent skill…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if model.loadState == .loading {
                ProgressView("Reading bundled skill…")
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Install for Claude Code") {
                    startInstall(at: .claudeCode)
                }
                .help("Writes ~/.claude/skills/rafu-ensemble and ~/.claude/skills/rafu-view")
                Button("Install for Codex") {
                    startInstall(at: .codex)
                }
                .help("Writes ~/.codex/skills/rafu-ensemble and ~/.codex/skills/rafu-view")
                Button("Install to Folder…") {
                    isFolderImporterPresented = true
                }
                .help(
                    "Choose another skills folder. Rafu creates rafu-ensemble and rafu-view inside it."
                )
                if model.isInstalling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Installing agent skill")
                }
            }
            .disabled(model.loadState != .ready || model.isInstalling)

            if let message = model.operationMessage {
                EnsembleSettingsNotice(symbol: "checkmark.circle", message: message)
            }

            if let message = model.errorMessage {
                EnsembleSettingsNotice(symbol: "exclamationmark.triangle", message: message)
            }
        } header: {
            Text("Agent Skill")
        } footer: {
            Text(EnsembleSkillCopy.footer)
        }
        .task {
            await model.load()
        }
        .onDisappear {
            installTask?.cancel()
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let directory = urls.first else { return }
                startInstall(at: .custom(directory), requiresSecurityScope: true)
            case .failure(let error):
                model.reportFileImporterError(error)
            }
        }
        .fileDialogMessage(
            "Choose a skills folder. Rafu creates rafu-ensemble and rafu-view inside it."
        )
        .fileDialogConfirmationLabel("Install Here")
        .sheet(isPresented: pendingReplacementPresented) {
            if let pending = model.pendingReplacement {
                RafuConfirmPopup(
                    title: "Replace existing skill files?",
                    message:
                        "Rafu replaces only the rafu-ensemble and rafu-view skill files after this confirmation.",
                    actions: [
                        .init(
                            "Replace \(pending.conflicts.count) Existing File(s)",
                            isDestructive: true
                        ) {
                            startInstall(
                                at: pending.destination,
                                replaceConfirmed: true,
                                requiresSecurityScope: pending.requiresSecurityScope)
                            // The confirmation is answered; the install task
                            // owns the outcome.
                            model.clearPendingReplacement()
                        }
                    ]
                ) {
                    model.clearPendingReplacement()
                }
            }
        }

        ImageTrustSettingsSection()
    }

    private var pendingReplacementPresented: Binding<Bool> {
        Binding(
            get: { model.pendingReplacement != nil },
            set: { presented in
                if !presented {
                    model.clearPendingReplacement()
                }
            })
    }

    private func startInstall(
        at destination: ConductorSkillDestination,
        replaceConfirmed: Bool = false,
        requiresSecurityScope: Bool = false
    ) {
        installTask?.cancel()
        installTask = Task {
            await model.install(
                at: destination,
                replaceConfirmed: replaceConfirmed,
                requiresSecurityScope: requiresSecurityScope)
        }
    }
}

private struct EnsembleSettingsNotice: View {
    let symbol: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(message)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Plain-words copy for the Claude Code prompt setting. It says exactly what
/// Rafu answers (ADR 0026).
nonisolated enum EnsembleChannelPromptCopy {
    static let help =
        "Presses Return once on Claude Code's \"Loading development channels\" dialog for server:rafu."

    static let footer =
        "When Rafu starts Claude Code in an Ensemble terminal, Claude asks you to confirm Rafu's own channel, server:rafu. With this on and the Ensemble's Agent control set to Allow, Rafu presses Return once to choose \"I am using this for local development\" and shows a notice. Rafu never answers any other prompt, such as folder trust, new MCP servers, or tool permissions. In Ask or Off, you answer the dialog yourself."
}

/// Plain-words copy for the agent skill section.
nonisolated enum EnsembleSkillCopy {
    static let summary =
        "Teaches Claude Code and Codex to use an Ensemble: read the board, start a peer agent, link it, delegate work, share notes, draw and export diagrams, open and check apps, and show native views."

    static let footer =
        "One install writes two skills, rafu-ensemble and rafu-view. Claude Code reads ~/.claude/skills/rafu-ensemble and ~/.claude/skills/rafu-view; Codex reads ~/.codex/skills/rafu-ensemble and ~/.codex/skills/rafu-view. For another agent, choose its skills folder; Rafu does not guess other vendor folders. Install again after a Rafu update to refresh the skills."
}

@MainActor
@Observable
final class EnsembleSettingsModel {
    typealias CatalogProvider = @MainActor () throws -> ConductorBundledSkillCatalog
    typealias CatalogsProvider = @MainActor () throws -> [ConductorBundledSkillCatalog]

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed
    }

    struct PendingReplacement: Equatable {
        let destination: ConductorSkillDestination
        let conflicts: [String]
        let requiresSecurityScope: Bool
    }

    private(set) var loadState = LoadState.idle
    private(set) var metadata: ConductorBundledSkillMetadata?
    private(set) var isInstalling = false
    private(set) var operationMessage: String?
    private(set) var errorMessage: String?
    private(set) var pendingReplacement: PendingReplacement?

    @ObservationIgnored private let catalogProvider: CatalogProvider
    @ObservationIgnored private let otherCatalogsProvider: CatalogsProvider
    @ObservationIgnored private let homeDirectory: URL
    /// The first skill's installer first, then the others.
    @ObservationIgnored private var installers: [ConductorSkillInstaller] = []

    /// The skill folders one install writes.
    var skillNames: [String] { ConductorBundledSkillCatalog.skills.map(\.identifier) }

    /// Construction is presentation-state only. The providers are not
    /// called until the Settings section's `.task` invokes `load()`.
    /// `catalogProvider` gives the first skill (its metadata is shown);
    /// `otherCatalogsProvider` gives the skills installed beside it.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        catalogProvider: @escaping CatalogProvider = {
            try ConductorBundledSkillCatalog.bundled()
        },
        otherCatalogsProvider: @escaping CatalogsProvider = {
            Array(try ConductorBundledSkillCatalog.bundledSkills().dropFirst())
        }
    ) {
        self.homeDirectory = homeDirectory
        self.catalogProvider = catalogProvider
        self.otherCatalogsProvider = otherCatalogsProvider
    }

    func load() async {
        guard installers.isEmpty, loadState != .loading else { return }
        loadState = .loading
        errorMessage = nil
        do {
            let catalogs = [try catalogProvider()] + (try otherCatalogsProvider())
            let installers = catalogs.map {
                ConductorSkillInstaller(catalog: $0, homeDirectory: homeDirectory)
            }
            let metadata = try await installers[0].metadata()
            for other in installers.dropFirst() { _ = try await other.metadata() }
            try Task.checkCancellation()
            self.installers = installers
            self.metadata = metadata
            loadState = .ready
        } catch is CancellationError {
            loadState = .idle
        } catch {
            loadState = .failed
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not read the bundled agent skill."
        }
    }

    func install(
        at destination: ConductorSkillDestination,
        replaceConfirmed: Bool = false,
        requiresSecurityScope: Bool = false
    ) async {
        guard !isInstalling, !installers.isEmpty else { return }
        isInstalling = true
        operationMessage = nil
        errorMessage = nil
        defer { isInstalling = false }

        let securityScopedURL: URL? =
            if requiresSecurityScope, case .custom(let url) = destination {
                url
            } else {
                nil
            }
        let accessed = securityScopedURL?.startAccessingSecurityScopedResource() ?? false
        defer {
            if accessed {
                securityScopedURL?.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // Ask about every skill before writing any of them.
            if !replaceConfirmed {
                var conflicts: [String] = []
                for installer in installers {
                    conflicts += try await installer.conflicts(at: destination).map {
                        "\(installer.skillIdentifier)/\($0)"
                    }
                }
                try Task.checkCancellation()
                if !conflicts.isEmpty {
                    pendingReplacement = PendingReplacement(
                        destination: destination,
                        conflicts: conflicts,
                        requiresSecurityScope: requiresSecurityScope)
                    return
                }
            }
            var results: [ConductorSkillInstallationResult] = []
            for installer in installers {
                let result = try await installer.install(
                    at: destination,
                    existingFilePolicy: replaceConfirmed
                        ? .replaceConfirmed
                        : .requireConfirmation)
                try Task.checkCancellation()
                if result.requiresConfirmation {
                    // A file appeared after the check above.
                    pendingReplacement = PendingReplacement(
                        destination: destination,
                        conflicts: result.conflicts.map { "\(installer.skillIdentifier)/\($0)" },
                        requiresSecurityScope: requiresSecurityScope)
                    return
                }
                results.append(result)
            }
            pendingReplacement = nil
            operationMessage = Self.installedMessage(results)
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not install the agent skill."
        }
    }

    /// "Installed at <first skill folder> and 1 more beside it: N written, …".
    static func installedMessage(_ results: [ConductorSkillInstallationResult]) -> String {
        let place = results.first?.destinationDescription ?? ""
        let others = results.count - 1
        let beside = others > 0 ? " and \(others) more beside it" : ""
        return "Installed at \(place)\(beside): "
            + "\(results.reduce(0) { $0 + $1.created.count }) written, "
            + "\(results.reduce(0) { $0 + $1.replaced.count }) replaced, "
            + "\(results.reduce(0) { $0 + $1.unchanged.count }) skipped."
    }

    func clearPendingReplacement() {
        pendingReplacement = nil
    }

    func reportFileImporterError(_ error: any Error) {
        errorMessage = error.localizedDescription
    }
}
