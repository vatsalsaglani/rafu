import SwiftUI
import UniformTypeIdentifiers

/// Settings > Ensemble: installs the Rafu agent skill that teaches Claude Code
/// and Codex to use the Ensemble tools.
struct EnsembleSettingsSection: View {
    @State private var model = EnsembleSettingsModel()
    @State private var isFolderImporterPresented = false
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.metadata?.name ?? ConductorBundledSkillCatalog.skillIdentifier)
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
                .help("Writes ~/.claude/skills/rafu-ensemble")
                Button("Install for Codex") {
                    startInstall(at: .codex)
                }
                .help("Writes ~/.codex/skills/rafu-ensemble")
                Button("Install to Folder…") {
                    isFolderImporterPresented = true
                }
                .help("Choose another skills folder. Rafu creates rafu-ensemble inside it.")
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
        .fileDialogMessage("Choose a skills folder. Rafu creates rafu-ensemble inside it.")
        .fileDialogConfirmationLabel("Install Here")
        .confirmationDialog(
            "Replace existing skill files?",
            isPresented: pendingReplacementPresented,
            titleVisibility: .visible
        ) {
            if let pending = model.pendingReplacement {
                Button(
                    "Replace \(pending.conflicts.count) Existing File(s)",
                    role: .destructive
                ) {
                    startInstall(
                        at: pending.destination,
                        replaceConfirmed: true,
                        requiresSecurityScope: pending.requiresSecurityScope)
                }
            }
            Button("Cancel", role: .cancel) {
                model.clearPendingReplacement()
            }
        } message: {
            Text("Rafu replaces only the rafu-ensemble skill files after this confirmation.")
        }
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

/// Plain-words copy for the agent skill section.
nonisolated enum EnsembleSkillCopy {
    static let summary =
        "Teaches Claude Code and Codex to use an Ensemble: read the board, start a peer agent, link it, delegate work, share notes, draw and export diagrams, and open and check apps."

    static let footer =
        "Claude Code reads ~/.claude/skills/rafu-ensemble and Codex reads ~/.codex/skills/rafu-ensemble. For another agent, choose its skills folder; Rafu does not guess other vendor folders. Install again after a Rafu update to refresh the skill."
}

@MainActor
@Observable
final class EnsembleSettingsModel {
    typealias CatalogProvider = @MainActor () throws -> ConductorBundledSkillCatalog

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
    @ObservationIgnored private let homeDirectory: URL
    @ObservationIgnored private var installer: ConductorSkillInstaller?

    /// Construction is presentation-state only. `catalogProvider` is not
    /// called until the Settings section's `.task` invokes `load()`.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        catalogProvider: @escaping CatalogProvider = {
            try ConductorBundledSkillCatalog.bundled()
        }
    ) {
        self.homeDirectory = homeDirectory
        self.catalogProvider = catalogProvider
    }

    func load() async {
        guard installer == nil, loadState != .loading else { return }
        loadState = .loading
        errorMessage = nil
        do {
            let installer = ConductorSkillInstaller(
                catalog: try catalogProvider(), homeDirectory: homeDirectory)
            let metadata = try await installer.metadata()
            try Task.checkCancellation()
            self.installer = installer
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
        guard !isInstalling, let installer else { return }
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
            let result = try await installer.install(
                at: destination,
                existingFilePolicy: replaceConfirmed
                    ? .replaceConfirmed
                    : .requireConfirmation)
            try Task.checkCancellation()
            if result.requiresConfirmation {
                pendingReplacement = PendingReplacement(
                    destination: destination,
                    conflicts: result.conflicts,
                    requiresSecurityScope: requiresSecurityScope)
                return
            }
            pendingReplacement = nil
            operationMessage =
                "Installed at \(result.destinationDescription): "
                + "\(result.created.count) written, "
                + "\(result.replaced.count) replaced, "
                + "\(result.unchanged.count) skipped."
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not install the agent skill."
        }
    }

    func clearPendingReplacement() {
        pendingReplacement = nil
    }

    func reportFileImporterError(_ error: any Error) {
        errorMessage = error.localizedDescription
    }
}
