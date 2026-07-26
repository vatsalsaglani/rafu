import Foundation
import RafuCore

/// The two file-backed definition scopes C6 resolves. The on-disk global
/// directory deliberately keeps the historical `conductor` component from
/// ADR 0018; only user-visible labels use the Ensemble name.
nonisolated enum ConductorDefinitionScope: String, CaseIterable, Sendable {
    case repository
    case userGlobal

    var displayName: String {
        switch self {
        case .repository: "Repository"
        case .userGlobal: "User"
        }
    }
}

/// Whether a definition participates in launch resolution. Both rows remain
/// visible in the library when a repository file shadows a user-global file.
nonisolated enum ConductorDefinitionResolution: Equatable, Sendable {
    case selected
    case overriddenByRepository

    var label: String {
        switch self {
        case .selected: "Active"
        case .overriddenByRepository: "Overridden by Repository"
        }
    }
}

/// One bounded, content-free problem suitable for an inline library row.
/// Messages may name a rejected token or filename, but never include prompt
/// bodies, handoff contents, CLI output, or credentials.
nonisolated struct ConductorDefinitionIssue: Equatable, Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case unsafeFile
        case fileTooLarge
        case unreadableFile
        case parseError
        case unsupportedAutonomy
        case adapterUnavailable
        case adapterDisabled
        case unknownAgent
        case invalidAgent
    }

    let kind: Kind
    let message: String
    let line: Int?

    var id: String {
        "\(kind.rawValue):\(line.map(String.init) ?? "-"):\(message)"
    }
}

/// One role file from either scope. `stem` is the resolution key: a
/// repository `reviewer.md` shadows user-global `reviewer.md` even when the
/// repository file is malformed, so Rafu never silently falls back around a
/// local override the user intended to fix.
nonisolated struct ConductorLibraryAgent: Equatable, Identifiable, Sendable {
    let fileURL: URL
    let stem: String
    let scope: ConductorDefinitionScope
    var resolution: ConductorDefinitionResolution
    let definition: ConductorAgentDefinition?
    let issues: [ConductorDefinitionIssue]

    var id: String { fileURL.standardizedFileURL.path }
    var displayName: String { definition?.name ?? stem }
    var isLaunchable: Bool {
        resolution == .selected && definition != nil && issues.isEmpty
    }

    var agentFile: ConductorAgentFile? {
        guard let definition else { return nil }
        return ConductorAgentFile(relativePath: fileURL.path, definition: definition)
    }
}

/// One workflow file from either scope. Workflow issues include both parse
/// diagnostics and pick-time binding/agent validation; an invalid file stays
/// visible and editable instead of failing the whole library load.
nonisolated struct ConductorLibraryWorkflow: Equatable, Identifiable, Sendable {
    let fileURL: URL
    let stem: String
    let scope: ConductorDefinitionScope
    var resolution: ConductorDefinitionResolution
    let definition: ConductorWorkflowDefinition?
    var issues: [ConductorDefinitionIssue]

    var id: String { fileURL.standardizedFileURL.path }
    var displayName: String { definition?.name ?? stem }
    var isLaunchable: Bool {
        resolution == .selected && definition != nil && issues.isEmpty
    }
}

nonisolated struct ConductorDefinitionLibrarySnapshot: Equatable, Sendable {
    let agents: [ConductorLibraryAgent]
    let workflows: [ConductorLibraryWorkflow]

    var launchableWorkflows: [ConductorLibraryWorkflow] {
        workflows.filter(\.isLaunchable)
    }
}

nonisolated enum ConductorDefinitionLibraryError: Error, Equatable, LocalizedError, Sendable {
    case pathIsNotDirectory(String)
    case unsafeDirectory(String)
    case unableToList(String)

    var errorDescription: String? {
        switch self {
        case .pathIsNotDirectory(let path):
            "\"\(path)\" is not a directory."
        case .unsafeDirectory(let path):
            "\"\(path)\" must be a real directory, not a symbolic link."
        case .unableToList(let path):
            "Rafu could not list definitions in \"\(path)\"."
        }
    }
}

/// File-backed C6 catalog. Reads happen on the concurrent executor because
/// Foundation's directory and file-handle APIs are synchronous. Each file is
/// independently bounded and diagnosed so one typo never hides unrelated
/// workflows from the library.
nonisolated struct ConductorDefinitionLibrary: Sendable {
    static let maximumDefinitionFileBytes = 1_048_576

    private let adapters: [any ConductorCLIAdapter]
    private let enableStore: ConductorEnableStore

    init(
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        enableStore: ConductorEnableStore = ConductorEnableStore()
    ) {
        self.adapters = adapters
        self.enableStore = enableStore
    }

    static var defaultUserLibraryRoot: URL {
        defaultUserLibraryRoot(identity: .current)
    }

    static func defaultUserLibraryRoot(identity: RafuAppIdentity) -> URL {
        identity
            .applicationSupportRoot()
            .appending(path: "conductor", directoryHint: .isDirectory)
    }

    @concurrent
    func load(
        workspaceRoot: URL,
        userLibraryRoot: URL = Self.defaultUserLibraryRoot
    ) async throws -> ConductorDefinitionLibrarySnapshot {
        try Task.checkCancellation()

        let repositoryDirectory = RafuDotDirectory(workspaceRoot: workspaceRoot)
        let repositoryAgents = try loadAgents(
            from: repositoryDirectory.agentsURL, scope: .repository)
        let globalAgents = try loadAgents(
            from: userLibraryRoot.appending(path: "agents", directoryHint: .isDirectory),
            scope: .userGlobal)
        let agents = resolve(repository: repositoryAgents, global: globalAgents)

        try Task.checkCancellation()
        let repositoryWorkflows = try loadWorkflows(
            from: repositoryDirectory.workflowsURL, scope: .repository)
        let globalWorkflows = try loadWorkflows(
            from: userLibraryRoot.appending(path: "workflows", directoryHint: .isDirectory),
            scope: .userGlobal)
        var workflows = resolve(repository: repositoryWorkflows, global: globalWorkflows)
        workflows = validateWorkflowBindings(workflows, against: agents)

        return ConductorDefinitionLibrarySnapshot(agents: agents, workflows: workflows)
    }

    private func loadAgents(
        from directory: URL,
        scope: ConductorDefinitionScope
    ) throws -> [ConductorLibraryAgent] {
        try definitionURLs(in: directory).map { url in
            try Task.checkCancellation()
            let result = readDefinition(at: url)
            guard case .success(let text) = result else {
                return ConductorLibraryAgent(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: nil,
                    issues: [result.issue])
            }

            do {
                let definition = try ConductorAgentFileParser.parse(
                    text, defaultName: stem(of: url))
                return ConductorLibraryAgent(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: definition,
                    issues: validateAgent(definition, sourceText: text))
            } catch let error as ConductorParseError {
                return ConductorLibraryAgent(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: nil,
                    issues: [
                        ConductorDefinitionIssue(
                            kind: .parseError,
                            message: error.errorDescription
                                ?? "The role file could not be parsed.",
                            line: Self.lineNumber(in: error))
                    ])
            } catch {
                return ConductorLibraryAgent(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: nil,
                    issues: [
                        ConductorDefinitionIssue(
                            kind: .parseError,
                            message: "The role file could not be parsed.",
                            line: nil)
                    ])
            }
        }
    }

    private func loadWorkflows(
        from directory: URL,
        scope: ConductorDefinitionScope
    ) throws -> [ConductorLibraryWorkflow] {
        try definitionURLs(in: directory).map { url in
            try Task.checkCancellation()
            let result = readDefinition(at: url)
            guard case .success(let text) = result else {
                return ConductorLibraryWorkflow(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: nil,
                    issues: [result.issue])
            }

            do {
                let definition = try ConductorWorkflowFileParser.parse(
                    text, defaultName: stem(of: url))
                return ConductorLibraryWorkflow(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: definition,
                    issues: [])
            } catch let error as ConductorParseError {
                return ConductorLibraryWorkflow(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: nil,
                    issues: [
                        ConductorDefinitionIssue(
                            kind: .parseError,
                            message: error.errorDescription
                                ?? "The workflow file could not be parsed.",
                            line: Self.lineNumber(in: error))
                    ])
            } catch {
                return ConductorLibraryWorkflow(
                    fileURL: url,
                    stem: stem(of: url),
                    scope: scope,
                    resolution: .selected,
                    definition: nil,
                    issues: [
                        ConductorDefinitionIssue(
                            kind: .parseError,
                            message: "The workflow file could not be parsed.",
                            line: nil)
                    ])
            }
        }
    }

    private func definitionURLs(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw ConductorDefinitionLibraryError.pathIsNotDirectory(directory.path)
        }
        let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard directoryValues.isSymbolicLink != true else {
            throw ConductorDefinitionLibraryError.unsafeDirectory(directory.path)
        }
        do {
            return try manager.contentsOfDirectory(
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
        } catch {
            throw ConductorDefinitionLibraryError.unableToList(directory.path)
        }
    }

    private enum ReadResult {
        case success(String)
        case failure(ConductorDefinitionIssue)

        var issue: ConductorDefinitionIssue {
            guard case .failure(let issue) = self else {
                preconditionFailure("Only a failed definition read carries an issue.")
            }
            return issue
        }
    }

    private func readDefinition(at url: URL) -> ReadResult {
        let name = url.lastPathComponent
        do {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .failure(
                    ConductorDefinitionIssue(
                        kind: .unsafeFile,
                        message: "\(name) must be a regular file, not a symbolic link.",
                        line: nil))
            }
            guard (values.fileSize ?? 0) <= Self.maximumDefinitionFileBytes else {
                return .failure(
                    ConductorDefinitionIssue(
                        kind: .fileTooLarge,
                        message: "\(name) exceeds Rafu's 1 MiB definition-file limit.",
                        line: nil))
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data =
                try handle.read(upToCount: Self.maximumDefinitionFileBytes + 1)
                ?? Data()
            guard data.count <= Self.maximumDefinitionFileBytes else {
                return .failure(
                    ConductorDefinitionIssue(
                        kind: .fileTooLarge,
                        message: "\(name) exceeds Rafu's 1 MiB definition-file limit.",
                        line: nil))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(
                    ConductorDefinitionIssue(
                        kind: .unreadableFile,
                        message: "\(name) is not readable UTF-8 text.",
                        line: nil))
            }
            return .success(text)
        } catch {
            return .failure(
                ConductorDefinitionIssue(
                    kind: .unreadableFile,
                    message: "\(name) could not be read.",
                    line: nil))
        }
    }

    private func validateAgent(
        _ definition: ConductorAgentDefinition,
        sourceText: String
    ) -> [ConductorDefinitionIssue] {
        var issues: [ConductorDefinitionIssue] = []
        if let autonomy = Self.rawAutonomy(in: sourceText),
            !autonomy.value.isEmpty,
            ConductorAutonomy(rawValue: autonomy.value) == nil
        {
            issues.append(
                ConductorDefinitionIssue(
                    kind: .unsupportedAutonomy,
                    message:
                        "Line \(autonomy.line): \"\(autonomy.value)\" is not a supported autonomy.",
                    line: autonomy.line))
        }

        guard let adapter = adapters.first(where: { $0.id == definition.provider }) else {
            issues.append(
                ConductorDefinitionIssue(
                    kind: .adapterUnavailable,
                    message: "\(definition.provider.displayName) is unavailable in this build.",
                    line: nil))
            return issues
        }
        if !enableStore.isEnabled(definition.provider, default: adapter.defaultEnabled) {
            issues.append(
                ConductorDefinitionIssue(
                    kind: .adapterDisabled,
                    message:
                        "\(definition.provider.displayName) is disabled in Ensemble settings.",
                    line: nil))
        }
        return issues
    }

    private func validateWorkflowBindings(
        _ workflows: [ConductorLibraryWorkflow],
        against agents: [ConductorLibraryAgent]
    ) -> [ConductorLibraryWorkflow] {
        let selectedAgents = agents.filter { $0.resolution == .selected }
        return workflows.map { workflow in
            guard workflow.resolution == .selected, let definition = workflow.definition else {
                return workflow
            }
            var validated = workflow
            for step in definition.steps {
                let match =
                    selectedAgents.first(where: { $0.definition?.name == step.agentName })
                    ?? selectedAgents.first(where: { $0.stem == step.agentName })
                guard let match else {
                    validated.issues.append(
                        ConductorDefinitionIssue(
                            kind: .unknownAgent,
                            message:
                                "Workflow step references role \"\(step.agentName)\", which has no matching agent file.",
                            line: nil))
                    continue
                }
                if let issue = match.issues.first {
                    validated.issues.append(
                        ConductorDefinitionIssue(
                            kind: .invalidAgent,
                            message: "Role \"\(step.agentName)\": \(issue.message)",
                            line: issue.line))
                } else if match.definition == nil {
                    validated.issues.append(
                        ConductorDefinitionIssue(
                            kind: .invalidAgent,
                            message: "Role \"\(step.agentName)\" is invalid.",
                            line: nil))
                }
            }
            return validated
        }
    }

    private func resolve(
        repository: [ConductorLibraryAgent],
        global: [ConductorLibraryAgent]
    ) -> [ConductorLibraryAgent] {
        let repositoryStems = Set(repository.map(\.stem))
        let resolvedGlobal = global.map { entry in
            var entry = entry
            if repositoryStems.contains(entry.stem) {
                entry.resolution = .overriddenByRepository
            }
            return entry
        }
        return Self.sorted(repository + resolvedGlobal)
    }

    private func resolve(
        repository: [ConductorLibraryWorkflow],
        global: [ConductorLibraryWorkflow]
    ) -> [ConductorLibraryWorkflow] {
        let repositoryStems = Set(repository.map(\.stem))
        let resolvedGlobal = global.map { entry in
            var entry = entry
            if repositoryStems.contains(entry.stem) {
                entry.resolution = .overriddenByRepository
            }
            return entry
        }
        return Self.sorted(repository + resolvedGlobal)
    }

    private static func sorted(
        _ entries: [ConductorLibraryAgent]
    ) -> [ConductorLibraryAgent] {
        entries.sorted {
            if $0.stem != $1.stem {
                return $0.stem.localizedStandardCompare($1.stem) == .orderedAscending
            }
            return $0.scope == .repository && $1.scope == .userGlobal
        }
    }

    private static func sorted(
        _ entries: [ConductorLibraryWorkflow]
    ) -> [ConductorLibraryWorkflow] {
        entries.sorted {
            if $0.stem != $1.stem {
                return $0.stem.localizedStandardCompare($1.stem) == .orderedAscending
            }
            return $0.scope == .repository && $1.scope == .userGlobal
        }
    }

    private func stem(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func rawAutonomy(in text: String) -> (value: String, line: Int)? {
        let lines = ConductorFrontmatter.lines(of: text)
        guard let block = try? ConductorFrontmatter.block(in: lines) else { return nil }
        var result: (value: String, line: Int)?
        for line in block.lines {
            guard let scalar = try? ConductorFrontmatter.scalar(line),
                scalar.key == "autonomy"
            else { continue }
            result = (scalar.value, line.number)
        }
        return result
    }

    private static func lineNumber(in error: ConductorParseError) -> Int {
        switch error {
        case .missingFrontmatter(let line),
            .unterminatedFrontmatter(let line),
            .malformedFrontmatterLine(let line),
            .missingProvider(let line),
            .unrecognizedProvider(_, let line),
            .malformedStep(let line),
            .workflowHasNoSteps(let line):
            line
        }
    }
}
