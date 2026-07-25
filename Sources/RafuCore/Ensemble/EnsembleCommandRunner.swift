import Foundation

public enum EnsembleHelp {
    public static let text = """
        OVERVIEW: Observe and coordinate Ensemble runs in an open Rafu workspace.

        USAGE:
          rafu ensemble run <workflow> [--role <name>=<cli>[:<model>]] [--prompt <text>]
            [--artifact <path>]... [--base <ref>] [--label <text>] [--json]
          rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
          rafu ensemble artifact <run> <step> [--json]
          rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
          rafu ensemble abort <run>
          rafu ensemble note <run> <text>
          rafu ensemble grant [--json]
          rafu ensemble help

        AUTHORITY:
          status, artifact, and await are read-only. run, abort, note, and grant
          require the live coordinator capability injected by Rafu.
        """
}

public struct EnsembleCommandResult: Equatable, Sendable {
    public let exitCode: EnsembleExitCode
    public let standardOutput: String
    public let standardError: String

    public init(
        exitCode: EnsembleExitCode,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public struct EnsembleCommandRunner: Sendable {
    private let client: any EnsembleCLIClientProtocol
    private let tokenProvider: @Sendable () -> String?

    public init(
        client: any EnsembleCLIClientProtocol = EnsembleCLIClient(),
        tokenProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["RAFU_ENSEMBLE_TOKEN"]
        }
    ) {
        self.client = client
        self.tokenProvider = tokenProvider
    }

    public func run(
        _ invocation: EnsembleInvocation,
        workingDirectory: String
    ) -> EnsembleCommandResult {
        let directory = URL(fileURLWithPath: workingDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        do {
            switch invocation {
            case .help:
                return EnsembleCommandResult(
                    exitCode: .ok,
                    standardOutput: EnsembleHelp.text
                )
            case .run(
                let workflow,
                let roleOverrides,
                let prompt,
                let artifacts,
                let baseReference,
                let label,
                let json
            ):
                return try startRun(
                    workflow: workflow,
                    roleOverrides: roleOverrides,
                    prompt: prompt,
                    artifacts: artifacts,
                    baseReference: baseReference,
                    label: label,
                    json: json,
                    workingDirectory: directory
                )
            case .status(let runIDs, let tree, let sinceCursor, let json):
                return try status(
                    runIDs: runIDs,
                    tree: tree,
                    sinceCursor: sinceCursor,
                    json: json,
                    workingDirectory: directory
                )
            case .artifact(let runID, let stepIndex, let json):
                return try artifact(
                    runID: runID,
                    stepIndex: stepIndex,
                    json: json,
                    workingDirectory: directory
                )
            case .await(let runIDs, let states, let any, let timeout, let json):
                return try awaitRuns(
                    runIDs: runIDs,
                    states: states,
                    any: any,
                    timeout: timeout,
                    json: json,
                    workingDirectory: directory
                )
            case .abort(let runID):
                return try mutate(
                    verb: "abort",
                    runID: runID,
                    text: nil,
                    workingDirectory: directory
                )
            case .note(let runID, let text):
                return try mutate(
                    verb: "note",
                    runID: runID,
                    text: text,
                    workingDirectory: directory
                )
            case .grant(let json):
                return try grant(json: json, workingDirectory: directory)
            }
        } catch let error as EnsembleCLIClientError {
            return result(for: error)
        } catch {
            return EnsembleCommandResult(
                exitCode: .dataError,
                standardError: "rafu ensemble: invalid response from Rafu.app"
            )
        }
    }

    private func startRun(
        workflow: String,
        roleOverrides: [EnsembleRoleOverride],
        prompt: String?,
        artifacts: [String],
        baseReference: String?,
        label: String?,
        json: Bool,
        workingDirectory: String
    ) throws -> EnsembleCommandResult {
        let absoluteArtifacts = artifacts.map { artifact in
            let url =
                artifact.hasPrefix("/")
                ? URL(fileURLWithPath: artifact)
                : URL(fileURLWithPath: workingDirectory, isDirectory: true)
                    .appending(path: artifact)
            return url.standardizedFileURL.path
        }
        let response = try client.performEnsemble(
            EnsembleRequestPayload(
                verb: "run",
                workingDirectory: workingDirectory,
                token: tokenProvider(),
                workflow: workflow,
                roleOverrides: roleOverrides,
                prompt: prompt,
                artifacts: absoluteArtifacts,
                baseReference: baseReference,
                label: label
            ))
        switch response {
        case .runStarted(let result):
            let output =
                try json
                ? encodeJSON(result)
                : "\(result.runID) \(result.state.rawValue) \(result.worktree)"
            return EnsembleCommandResult(exitCode: .ok, standardOutput: output)
        case .failure(let code, let message):
            return remoteFailure(code: code, message: message)
        case .status, .artifact, .mutation, .grant, .subscribed:
            throw EnsembleCLIClientError.unexpectedResponse
        }
    }

    private func status(
        runIDs: [String],
        tree: Bool,
        sinceCursor: UInt64?,
        json: Bool,
        workingDirectory: String
    ) throws -> EnsembleCommandResult {
        let response = try client.performEnsemble(
            EnsembleRequestPayload(
                verb: "status",
                workingDirectory: workingDirectory,
                runIDs: runIDs,
                sinceCursor: sinceCursor,
                tree: tree
            ))
        switch response {
        case .status(let status):
            return EnsembleCommandResult(
                exitCode: .ok,
                standardOutput: try render(status: status, json: json)
            )
        case .failure(let code, let message):
            return remoteFailure(code: code, message: message)
        case .artifact, .runStarted, .mutation, .grant, .subscribed:
            throw EnsembleCLIClientError.unexpectedResponse
        }
    }

    private func artifact(
        runID: String,
        stepIndex: Int,
        json: Bool,
        workingDirectory: String
    ) throws -> EnsembleCommandResult {
        let response = try client.performEnsemble(
            EnsembleRequestPayload(
                verb: "artifact",
                workingDirectory: workingDirectory,
                runIDs: [runID],
                stepIndex: stepIndex
            ))
        switch response {
        case .artifact(let artifact):
            let output =
                try json
                ? encodeJSON(artifact)
                : artifact.artifacts.joined(separator: "\n")
            return EnsembleCommandResult(exitCode: .ok, standardOutput: output)
        case .failure(let code, let message):
            return remoteFailure(code: code, message: message)
        case .status, .runStarted, .mutation, .grant, .subscribed:
            throw EnsembleCLIClientError.unexpectedResponse
        }
    }

    private func mutate(
        verb: String,
        runID: String,
        text: String?,
        workingDirectory: String
    ) throws -> EnsembleCommandResult {
        let response = try client.performEnsemble(
            EnsembleRequestPayload(
                verb: verb,
                workingDirectory: workingDirectory,
                runIDs: [runID],
                token: tokenProvider(),
                text: text
            ))
        switch response {
        case .mutation(let result):
            let state = result.state.map { " \($0.rawValue)" } ?? ""
            return EnsembleCommandResult(
                exitCode: .ok,
                standardOutput: "\(result.runID) \(result.verb)\(state)"
            )
        case .failure(let code, let message):
            return remoteFailure(code: code, message: message)
        case .status, .artifact, .runStarted, .grant, .subscribed:
            throw EnsembleCLIClientError.unexpectedResponse
        }
    }

    private func grant(
        json: Bool,
        workingDirectory: String
    ) throws -> EnsembleCommandResult {
        let response = try client.performEnsemble(
            EnsembleRequestPayload(
                verb: "grant",
                workingDirectory: workingDirectory,
                token: tokenProvider()
            ))
        switch response {
        case .grant(let grant):
            let output: String
            if json {
                output = try encodeJSON(grant)
            } else {
                output = [
                    "active \(grant.activeChildRuns)/\(grant.maxConcurrentChildRuns)",
                    "started \(grant.startedChildRuns)/\(grant.maxTotalChildRuns)",
                    "providers \(grant.allowedProviders.joined(separator: ","))",
                ].joined(separator: "\n")
            }
            return EnsembleCommandResult(exitCode: .ok, standardOutput: output)
        case .failure(let code, let message):
            return remoteFailure(code: code, message: message)
        case .status, .artifact, .runStarted, .mutation, .subscribed:
            throw EnsembleCLIClientError.unexpectedResponse
        }
    }

    private func awaitRuns(
        runIDs: [String],
        states: [EnsembleRunState],
        any: Bool,
        timeout: TimeInterval?,
        json: Bool,
        workingDirectory: String
    ) throws -> EnsembleCommandResult {
        var matchedOutput: AwaitOutput?
        var currentStates: [String: EnsembleRunState] = [:]
        let requestedStates = Set(states)

        try client.subscribe(
            payload: EnsembleRequestPayload(
                verb: "await",
                workingDirectory: workingDirectory,
                runIDs: runIDs,
                states: states,
                any: any
            ),
            timeout: timeout,
            onSubscribed: { _ in
                let response = try client.performEnsemble(
                    EnsembleRequestPayload(
                        verb: "status",
                        workingDirectory: workingDirectory,
                        runIDs: runIDs
                    ))
                switch response {
                case .status(let snapshot):
                    currentStates = Dictionary(
                        uniqueKeysWithValues: snapshot.runs.map { ($0.runID, $0.state) })
                    if conditionMet(
                        runIDs: runIDs,
                        states: currentStates,
                        requestedStates: requestedStates,
                        any: any
                    ) {
                        matchedOutput = AwaitOutput(
                            matchedRunIDs: matchingRunIDs(
                                runIDs: runIDs,
                                states: currentStates,
                                requestedStates: requestedStates
                            ),
                            states: currentStates,
                            cursor: snapshot.cursor
                        )
                        return true
                    }
                    return false
                case .failure(let code, let message):
                    throw EnsembleCLIClientError.failure(code: code, message: message)
                case .artifact, .runStarted, .mutation, .grant, .subscribed:
                    throw EnsembleCLIClientError.unexpectedResponse
                }
            },
            onEvent: { event in
                if let state = event.state, runIDs.contains(event.runID) {
                    currentStates[event.runID] = state
                }
                guard
                    conditionMet(
                        runIDs: runIDs,
                        states: currentStates,
                        requestedStates: requestedStates,
                        any: any
                    )
                else { return false }
                matchedOutput = AwaitOutput(
                    matchedRunIDs: matchingRunIDs(
                        runIDs: runIDs,
                        states: currentStates,
                        requestedStates: requestedStates
                    ),
                    states: currentStates,
                    cursor: event.cursor
                )
                return true
            }
        )

        guard let matchedOutput else {
            throw EnsembleCLIClientError.unexpectedResponse
        }
        let output: String
        if json {
            output = try encodeJSON(matchedOutput)
        } else {
            output = matchedOutput.matchedRunIDs
                .compactMap { runID in
                    matchedOutput.states[runID].map { "\(runID) \($0.rawValue)" }
                }
                .joined(separator: "\n")
        }
        return EnsembleCommandResult(exitCode: .ok, standardOutput: output)
    }

    private func render(status: EnsembleStatusResult, json: Bool) throws -> String {
        if json { return try encodeJSON(status) }
        var lines = status.runs.map { run in
            "\(run.runID) \(run.state.rawValue) \(run.label ?? run.workflowName)"
        }
        lines.append(
            contentsOf: status.events.map { event in
                "\(event.cursor) \(event.runID) \(event.kind)"
            })
        return lines.joined(separator: "\n")
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func conditionMet(
        runIDs: [String],
        states: [String: EnsembleRunState],
        requestedStates: Set<EnsembleRunState>,
        any: Bool
    ) -> Bool {
        if any {
            return runIDs.contains { runID in
                states[runID].map(requestedStates.contains) ?? false
            }
        }
        return runIDs.allSatisfy { runID in
            states[runID].map(requestedStates.contains) ?? false
        }
    }

    private func matchingRunIDs(
        runIDs: [String],
        states: [String: EnsembleRunState],
        requestedStates: Set<EnsembleRunState>
    ) -> [String] {
        runIDs.filter { runID in
            states[runID].map(requestedStates.contains) ?? false
        }
    }

    private func result(for error: EnsembleCLIClientError) -> EnsembleCommandResult {
        switch error {
        case .timedOut:
            EnsembleCommandResult(
                exitCode: .tempFail,
                standardError: "rafu ensemble: \(error.localizedDescription)"
            )
        case .failure(let code, let message):
            remoteFailure(code: code, message: message)
        case .disconnected, .heartbeatTimeout, .rejected, .systemCall, .unexpectedResponse:
            EnsembleCommandResult(
                exitCode: .unavailable,
                standardError: "rafu ensemble: \(error.localizedDescription)"
            )
        }
    }

    private func remoteFailure(code: Int32, message: String) -> EnsembleCommandResult {
        EnsembleCommandResult(
            exitCode: EnsembleExitCode(rawValue: code) ?? .dataError,
            standardError: "rafu ensemble: \(message)"
        )
    }

    private struct AwaitOutput: Codable {
        let matchedRunIDs: [String]
        let states: [String: EnsembleRunState]
        let cursor: UInt64
    }
}
