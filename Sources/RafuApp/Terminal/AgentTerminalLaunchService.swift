import Foundation

nonisolated enum AgentTerminalAvailability: Equatable, Sendable {
    case ready(URL)
    case notInstalled
    case notAuthenticated(String)

    var executableURL: URL? {
        guard case .ready(let url) = self else { return nil }
        return url
    }

    var reason: String? {
        switch self {
        case .ready:
            nil
        case .notInstalled:
            "Not installed — install this CLI to open an Agent Terminal."
        case .notAuthenticated(let hint):
            hint
        }
    }
}

nonisolated struct AgentTerminalOption: Equatable, Identifiable, Sendable {
    let id: ConductorCLIID
    let displayName: String
    let icon: FileIconProvider.Icon
    let availability: AgentTerminalAvailability
    let curatedModels: [String]
    let defaultModel: String?
    /// Visible when a launch shape could not be verified locally. The CLI
    /// still launches bare; Rafu never guesses a vendor model flag.
    let launchVerificationNote: String?

    var isReady: Bool {
        availability.executableURL != nil
    }
}

nonisolated enum AgentTerminalLaunchVerification: Equatable, Sendable {
    case verified
    case hypothesis(String)

    var note: String? {
        guard case .hypothesis(let reason) = self else { return nil }
        return reason
    }
}

/// The interactive invocation table verified from installed CLI `--help`
/// output on 2026-07-26. Kimi was absent and therefore deliberately has no
/// model flag: it launches bare until a future probe verifies the shape.
nonisolated struct AgentTerminalLaunchShape: Equatable, Sendable {
    let interactiveArguments: [String]
    let modelFlag: String?
    let verification: AgentTerminalLaunchVerification

    static func forCLI(_ id: ConductorCLIID) -> AgentTerminalLaunchShape {
        switch id {
        case .claudeCode:
            AgentTerminalLaunchShape(
                interactiveArguments: [], modelFlag: "--model", verification: .verified)
        case .codex:
            AgentTerminalLaunchShape(
                interactiveArguments: [], modelFlag: "--model", verification: .verified)
        case .openCode:
            AgentTerminalLaunchShape(
                interactiveArguments: [], modelFlag: "--model", verification: .verified)
        case .cline:
            AgentTerminalLaunchShape(
                interactiveArguments: ["--tui"], modelFlag: "--model", verification: .verified)
        case .kimi:
            AgentTerminalLaunchShape(
                interactiveArguments: [],
                modelFlag: nil,
                verification: .hypothesis(
                    "Kimi CLI was not installed during verification. Rafu will launch it bare and omit the model until `kimi --help` confirms the flag."
                ))
        case .geminiCLI:
            AgentTerminalLaunchShape(
                interactiveArguments: [], modelFlag: "--model", verification: .verified)
        case .cursor:
            AgentTerminalLaunchShape(
                interactiveArguments: [], modelFlag: "--model", verification: .verified)
        }
    }

    func arguments(model: String?) -> [String] {
        var result = interactiveArguments
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let modelFlag {
            result += [modelFlag, trimmed]
        }
        return result
    }
}

nonisolated enum AgentTerminalLaunchError: Error, Equatable, Sendable {
    case unavailable
    case startingDirectoryOutsideWorkspace
}

/// Resolves the adapter registry into launch options, then maps one ready
/// option to the existing terminal process-spec seam. It performs no spawn
/// and gives the child exactly one environment key: the curated `PATH`.
@MainActor
struct AgentTerminalLaunchService {
    private let workspaceRoot: URL
    private let adapters: [any ConductorCLIAdapter]
    private let defaultModelStore: ConductorDefaultModelStore
    private let roleLaunchService = ConductorRoleLaunchService()

    init(
        workspaceRoot: URL,
        adapters: [any ConductorCLIAdapter] = ConductorAdapterRegistry.all,
        defaultModelStore: ConductorDefaultModelStore = ConductorDefaultModelStore()
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.adapters = adapters
        self.defaultModelStore = defaultModelStore
    }

    /// One stable row per injected registry entry. A CLI whose auth state is
    /// genuinely unknowable remains launchable: the adapter contract makes
    /// the vendor CLI the authority in that case.
    func options() async -> [AgentTerminalOption] {
        var result: [AgentTerminalOption] = []
        result.reserveCapacity(adapters.count)

        for adapter in adapters {
            guard !Task.isCancelled else { break }
            let availability: AgentTerminalAvailability
            do {
                let resolved = try await roleLaunchService.resolve(adapter)
                guard !Task.isCancelled else { break }
                let authStatus = await adapter.authStatus()
                guard !Task.isCancelled else { break }
                switch authStatus {
                case .authenticated, .unknown:
                    availability = .ready(resolved.executableURL)
                case .notAuthenticated(let hint):
                    availability = .notAuthenticated(hint)
                }
            } catch {
                availability = .notInstalled
            }

            let storedDefault = defaultModelStore.defaultModel(for: adapter.id)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shape = AgentTerminalLaunchShape.forCLI(adapter.id)
            result.append(
                AgentTerminalOption(
                    id: adapter.id,
                    displayName: adapter.id.displayName,
                    icon: ConductorCLIIcons.icon(for: adapter.id),
                    availability: availability,
                    curatedModels: adapter.curatedModels().map(\.id),
                    defaultModel: storedDefault.isEmpty ? nil : storedDefault,
                    launchVerificationNote: shape.verification.note
                ))
        }
        return result
    }

    /// Pure process mapping. The selected directory is normalized and must
    /// remain at or below the workspace root.
    func specification(
        option: AgentTerminalOption,
        model: String?,
        startingDirectory: URL
    ) throws -> TerminalProcessSpec {
        guard let executableURL = option.availability.executableURL else {
            throw AgentTerminalLaunchError.unavailable
        }
        let directory = startingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isStartingDirectory(directory, inside: workspaceRoot) else {
            throw AgentTerminalLaunchError.startingDirectoryOutsideWorkspace
        }

        let shape = AgentTerminalLaunchShape.forCLI(option.id)
        return TerminalProcessSpec(
            executableURL: executableURL,
            arguments: shape.arguments(model: model),
            currentDirectoryPath: directory.path,
            environment: [
                RafuConductorEnvironment.path:
                    Self.curatedPath(prependingParentOf: executableURL)
            ],
            roleBadge: option.displayName,
            outputLogURL: nil,
            resourceAttribution: "\(option.displayName) (agent terminal)",
            agentProvider: option.id
        )
    }

    static func isStartingDirectory(_ candidate: URL, inside workspaceRoot: URL) -> Bool {
        guard candidate.isFileURL, workspaceRoot.isFileURL else { return false }
        let rootPath = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func curatedPath(prependingParentOf executableURL: URL) -> String {
        let curated = RafuConductorEnvironment.curatedPath
        let executableDirectory = executableURL.deletingLastPathComponent().standardizedFileURL.path
        let components = curated.split(separator: ":").map(String.init)
        guard !components.contains(executableDirectory) else { return curated }
        return "\(executableDirectory):\(curated)"
    }
}
