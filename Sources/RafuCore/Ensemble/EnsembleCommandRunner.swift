import Foundation

public enum EnsembleHelp {
    public static let text = """
        OVERVIEW: Observe Ensemble runs in an open Rafu workspace.

        USAGE:
          rafu ensemble status [<run>...] [--tree] [--since <cursor>] [--json]
          rafu ensemble artifact <run> <step> [--json]
          rafu ensemble await <run>... --state <state> [--any] [--timeout <sec>] [--json]
          rafu ensemble help

        READ-ONLY:
          These verbs never start a run, write repository state, or merge.
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

    public init(client: any EnsembleCLIClientProtocol = EnsembleCLIClient()) {
        self.client = client
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
        case .artifact, .subscribed:
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
        case .status, .subscribed:
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
                case .artifact, .subscribed:
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
