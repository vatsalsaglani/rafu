import Foundation
import Observation

nonisolated enum ConductorWorkflowFileActionError: Error, Equatable, LocalizedError, Sendable {
    case sourceUnavailable
    case sourceTooLarge
    case unsafeSource
    case unableToCreateCopy

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The workflow file is unavailable."
        case .sourceTooLarge:
            "The workflow file exceeds Rafu's 1 MiB definition-file limit."
        case .unsafeSource:
            "Workflow copies require a regular file and a real destination directory."
        case .unableToCreateCopy:
            "Rafu could not create a unique workflow copy."
        }
    }
}

nonisolated struct ConductorWorkflowFileDuplicator: Sendable {
    @concurrent
    func duplicate(_ workflow: ConductorLibraryWorkflow) async throws -> URL {
        try Task.checkCancellation()
        let source = workflow.fileURL
        let values = try source.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConductorWorkflowFileActionError.unsafeSource
        }
        guard (values.fileSize ?? 0) <= ConductorDefinitionLibrary.maximumDefinitionFileBytes
        else {
            throw ConductorWorkflowFileActionError.sourceTooLarge
        }

        let directory = source.deletingLastPathComponent()
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw ConductorWorkflowFileActionError.unsafeSource
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data =
            try handle.read(upToCount: ConductorDefinitionLibrary.maximumDefinitionFileBytes + 1)
            ?? Data()
        guard data.count <= ConductorDefinitionLibrary.maximumDefinitionFileBytes else {
            throw ConductorWorkflowFileActionError.sourceTooLarge
        }

        for suffix in 1...1_000 {
            try Task.checkCancellation()
            let copySuffix = suffix == 1 ? "-copy" : "-copy-\(suffix)"
            let destination = directory.appending(
                path: "\(workflow.stem)\(copySuffix).md",
                directoryHint: .notDirectory)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                continue
            }
            do {
                try writeNewFileAtomically(data, to: destination)
                return destination
            } catch {
                if FileManager.default.fileExists(atPath: destination.path) {
                    continue
                }
                throw ConductorWorkflowFileActionError.unableToCreateCopy
            }
        }
        throw ConductorWorkflowFileActionError.unableToCreateCopy
    }

    private func writeNewFileAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(
                path: ".\(destination.lastPathComponent).rafu-\(UUID().uuidString).tmp",
                directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.linkItem(at: temporary, to: destination)
    }
}

nonisolated struct ConductorTemplateReplacement: Equatable, Sendable {
    let templateID: String
    let scope: ConductorDefinitionScope
    let conflicts: [String]
}

/// UI-facing library metadata only. Definition text remains owned by editor
/// documents and on-disk Markdown; this model retains parsed, bounded
/// snapshots and short operation messages.
@Observable
@MainActor
final class ConductorWorkflowLibraryModel {
    private(set) var snapshot: ConductorDefinitionLibrarySnapshot?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var errorMessage: String?
    private(set) var operationMessage: String?
    private(set) var pendingReplacement: ConductorTemplateReplacement?

    @ObservationIgnored
    private let library: ConductorDefinitionLibrary

    @ObservationIgnored
    private let duplicator: ConductorWorkflowFileDuplicator

    @ObservationIgnored
    private var workspaceRoot: URL?

    @ObservationIgnored
    private var userLibraryRoot = ConductorDefinitionLibrary.defaultUserLibraryRoot

    @ObservationIgnored
    private var loadGeneration = UUID()

    init(
        library: ConductorDefinitionLibrary = ConductorDefinitionLibrary(),
        duplicator: ConductorWorkflowFileDuplicator = ConductorWorkflowFileDuplicator()
    ) {
        self.library = library
        self.duplicator = duplicator
    }

    var workflows: [ConductorLibraryWorkflow] { snapshot?.workflows ?? [] }

    func load(
        workspaceRoot: URL?,
        userLibraryRoot: URL = ConductorDefinitionLibrary.defaultUserLibraryRoot
    ) async {
        let generation = UUID()
        loadGeneration = generation
        guard let workspaceRoot else {
            self.workspaceRoot = nil
            snapshot = nil
            errorMessage = "Open a local workspace to use the Ensemble workflow library."
            return
        }

        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        do {
            let loaded = try await library.load(
                workspaceRoot: workspaceRoot,
                userLibraryRoot: userLibraryRoot)
            guard loadGeneration == generation else { return }
            self.workspaceRoot = workspaceRoot.standardizedFileURL
            self.userLibraryRoot = userLibraryRoot.standardizedFileURL
            snapshot = loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            snapshot = nil
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not load Ensemble workflows."
        }
    }

    func duplicate(_ workflow: ConductorLibraryWorkflow) async -> URL? {
        guard !isMutating else { return nil }
        isMutating = true
        errorMessage = nil
        operationMessage = nil
        defer { isMutating = false }
        do {
            let url = try await duplicator.duplicate(workflow)
            operationMessage = "Created \(url.lastPathComponent)."
            await reload()
            return url
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not duplicate the workflow."
            return nil
        }
    }

    func instantiate(
        templateID: String,
        scope: ConductorDefinitionScope,
        replaceConfirmed: Bool = false
    ) async {
        guard !isMutating, let workspaceRoot else { return }
        isMutating = true
        errorMessage = nil
        operationMessage = nil
        defer { isMutating = false }

        do {
            let catalog = try ConductorBundledTemplateCatalog.bundled()
            let destination: ConductorTemplateDestination =
                switch scope {
                case .repository:
                    .repository(workspaceRoot: workspaceRoot)
                case .userGlobal:
                    .userGlobal(libraryRoot: userLibraryRoot)
                }
            let result = try await ConductorTemplateInstantiator(catalog: catalog).instantiate(
                templateID: templateID,
                at: destination,
                existingFilePolicy: replaceConfirmed ? .replaceConfirmed : .requireConfirmation)
            if result.requiresConfirmation {
                pendingReplacement = ConductorTemplateReplacement(
                    templateID: templateID,
                    scope: scope,
                    conflicts: result.conflicts)
                return
            }
            pendingReplacement = nil
            operationMessage =
                result.didChangeAnything
                ? "Created the Ensemble template in \(scope.displayName)."
                : "The Ensemble template is already up to date."
            await reload()
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "Rafu could not create the Ensemble template."
        }
    }

    func clearPendingReplacement() {
        pendingReplacement = nil
    }

    private func reload() async {
        await load(
            workspaceRoot: workspaceRoot,
            userLibraryRoot: userLibraryRoot)
    }
}
