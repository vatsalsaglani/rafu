import Foundation

/// One user-selectable pipeline file under `.rafu/workflows/`. Mirrors
/// `ConductorAgentFile`'s shape exactly.
nonisolated struct ConductorWorkflowFile: Equatable, Identifiable, Sendable {
    let relativePath: String
    let definition: ConductorWorkflowDefinition

    var id: String { relativePath }
}

nonisolated enum ConductorWorkflowCatalogError: Error, Equatable, LocalizedError, Sendable {
    case workflowsPathIsNotDirectory
    case unsafeWorkflowFile(String)
    case workflowFileTooLarge(String)
    case unreadableWorkflowFile(String)
    case invalidWorkflowFile(String, String)

    var errorDescription: String? {
        switch self {
        case .workflowsPathIsNotDirectory:
            "The workspace's .rafu/workflows path is not a readable directory."
        case .unsafeWorkflowFile(let name):
            "Workflow file \(name) must be a regular file, not a symbolic link."
        case .workflowFileTooLarge(let name):
            "Workflow file \(name) exceeds Rafu's 1 MiB workflow-file limit."
        case .unreadableWorkflowFile(let name):
            "Workflow file \(name) is not readable UTF-8 text."
        case .invalidWorkflowFile(let name, let reason):
            "Workflow file \(name) is invalid: \(reason)"
        }
    }
}

/// Bounded, read-only discovery for `.rafu/workflows/*.md` — the same
/// contract as `ConductorAgentCatalog`: an absent directory is an empty
/// catalog, never a seed, and a symlinked file or directory is refused.
nonisolated struct ConductorWorkflowCatalog: Sendable {
    static let maximumWorkflowFileBytes = 1_048_576

    @concurrent
    func load(workspaceRoot: URL) async throws -> [ConductorWorkflowFile] {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = RafuDotDirectory(workspaceRoot: workspaceRoot).workflowsURL

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw ConductorWorkflowCatalogError.workflowsPathIsNotDirectory
        }
        let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard directoryValues.isSymbolicLink != true else {
            throw ConductorWorkflowCatalogError.workflowsPathIsNotDirectory
        }

        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var files: [ConductorWorkflowFile] = []
        files.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ConductorWorkflowCatalogError.unsafeWorkflowFile(name)
            }
            guard (values.fileSize ?? 0) <= Self.maximumWorkflowFileBytes else {
                throw ConductorWorkflowCatalogError.workflowFileTooLarge(name)
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data =
                try handle.read(upToCount: Self.maximumWorkflowFileBytes + 1)
                ?? Data()
            guard data.count <= Self.maximumWorkflowFileBytes,
                let text = String(data: data, encoding: .utf8)
            else {
                if data.count > Self.maximumWorkflowFileBytes {
                    throw ConductorWorkflowCatalogError.workflowFileTooLarge(name)
                }
                throw ConductorWorkflowCatalogError.unreadableWorkflowFile(name)
            }

            let definition: ConductorWorkflowDefinition
            do {
                definition = try ConductorWorkflowFileParser.parse(
                    text,
                    defaultName: url.deletingPathExtension().lastPathComponent)
            } catch let error as ConductorParseError {
                throw ConductorWorkflowCatalogError.invalidWorkflowFile(
                    name,
                    error.errorDescription ?? "the workflow file could not be parsed")
            }
            files.append(
                ConductorWorkflowFile(
                    relativePath: ".rafu/workflows/\(name)",
                    definition: definition))
        }
        return files
    }
}

/// Typed failure binding a workflow step's `agentName` to a concrete
/// `.rafu/agents` file.
nonisolated enum ConductorWorkflowBinderError: Error, Equatable, LocalizedError, Sendable {
    case unknownAgent(name: String)

    var errorDescription: String? {
        switch self {
        case .unknownAgent(let name):
            "Workflow step references agent \"\(name)\", which has no matching .rafu/agents file."
        }
    }
}

/// Resolves a parsed `ConductorWorkflowDefinition`'s steps against the
/// workspace's loaded `.rafu/agents/*.md` catalog — the step needed before
/// `ConductorWorkflowController.start(_:launcher:)` can build its
/// index-aligned `roles` array.
nonisolated enum ConductorWorkflowBinder {
    /// Matches each step's `agentName` first against a role file's parsed
    /// `name`, then against the file's own stem — both exact, case-sensitive
    /// matches. An unmatched name fails typed and up front, before any step
    /// runs, rather than surfacing later as a launch-time adapter failure.
    static func resolve(
        workflow: ConductorWorkflowDefinition,
        agents: [ConductorAgentFile]
    ) throws -> [ConductorAgentDefinition] {
        try workflow.steps.map { step in
            if let match = agents.first(where: { $0.definition.name == step.agentName }) {
                return match.definition
            }
            if let match = agents.first(where: { Self.stem(of: $0) == step.agentName }) {
                return match.definition
            }
            throw ConductorWorkflowBinderError.unknownAgent(name: step.agentName)
        }
    }

    private static func stem(of file: ConductorAgentFile) -> String {
        URL(fileURLWithPath: file.relativePath).deletingPathExtension().lastPathComponent
    }
}
