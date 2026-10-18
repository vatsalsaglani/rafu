import RafuCore
import SwiftUI
import UniformTypeIdentifiers

struct EnsembleSettingsSection: View {
    @State private var model = EnsembleSettingsModel()
    @State private var isFolderImporterPresented = false
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.metadata?.name ?? "ensemble-with-rafu")
                    .font(.body.weight(.medium))
                Text(
                    model.metadata?.description
                        ?? "Loading the bundled coordinator skill…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let metadata = model.metadata {
                LabeledContent("Version") {
                    Text(
                        EnsembleSkillVersionCopy.summary(
                            skillTargets: metadata.targetsVerbVersion)
                    )
                }
                if !model.verbVersionsMatch {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(
                            EnsembleSkillVersionCopy.mismatch(
                                skillTargets: metadata.targetsVerbVersion,
                                rafuSupports: model.launcherVerbVersion)
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            } else if model.loadState == .loading {
                ProgressView("Reading bundled skill…")
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Install for Claude Code") {
                    startInstall(at: .claudeCode)
                }
                .disabled(model.loadState != .ready || model.isInstalling)
                Button("Install to Folder…") {
                    isFolderImporterPresented = true
                }
                .disabled(model.loadState != .ready || model.isInstalling)
                if model.isInstalling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Installing coordinator skill")
                }
            }

            if let message = model.operationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .accessibilityHidden(true)
                    Text(message)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if let message = model.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                    Text(message)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Ensemble Skill")
        } footer: {
            Text(
                "Claude Code installs to ~/.claude/skills/ensemble-with-rafu. For Codex or another coordinator, choose its verified skills folder; Rafu does not guess vendor directories."
            )
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
            "Choose a skills directory. Rafu creates ensemble-with-rafu inside it."
        )
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
            Text(
                "Rafu will replace only coordinator-skill destinations after this confirmation."
            )
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

/// Plain-words copy for the skill's protocol version. The internal term
/// ("verb version") never reaches the user; the numbers are the real ones.
nonisolated enum EnsembleSkillVersionCopy {
    /// "Skill version 2 · needs Rafu 2 or later"
    static func summary(skillTargets: Int) -> String {
        "Skill version \(skillTargets) · needs Rafu \(skillTargets) or later"
    }

    static func mismatch(skillTargets: Int, rafuSupports: Int) -> String {
        if rafuSupports < skillTargets {
            return
                "This skill needs Rafu \(skillTargets) or later, but this Rafu supports version \(rafuSupports). Update Rafu to use it."
        }
        return
            "This skill is version \(skillTargets), but this Rafu supports version \(rafuSupports). Install the skill again to update it."
    }
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

    let launcherVerbVersion: Int

    @ObservationIgnored private let catalogProvider: CatalogProvider
    @ObservationIgnored private var installer: ConductorSkillInstaller?

    /// Construction is presentation-state only. `catalogProvider` is not
    /// called until the Settings section's `.task` invokes `load()`.
    init(
        launcherVerbVersion: Int = LauncherIPCProtocol.ensembleVerbVersion,
        catalogProvider: @escaping CatalogProvider = {
            try ConductorBundledSkillCatalog.bundled()
        }
    ) {
        self.launcherVerbVersion = launcherVerbVersion
        self.catalogProvider = catalogProvider
    }

    var verbVersionsMatch: Bool {
        guard let metadata else { return false }
        return metadata.targetsVerbVersion == launcherVerbVersion
    }

    func load() async {
        guard installer == nil, loadState != .loading else { return }
        loadState = .loading
        errorMessage = nil
        do {
            let installer = ConductorSkillInstaller(catalog: try catalogProvider())
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
                ?? "Rafu could not read the bundled coordinator skill."
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
                ?? "Rafu could not install the coordinator skill."
        }
    }

    func clearPendingReplacement() {
        pendingReplacement = nil
    }

    func reportFileImporterError(_ error: any Error) {
        errorMessage = error.localizedDescription
    }
}
