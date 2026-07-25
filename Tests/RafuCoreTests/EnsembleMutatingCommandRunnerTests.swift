import Foundation
import Synchronization
import Testing

@testable import RafuCore

@Suite("Ensemble mutating command runner")
struct EnsembleMutatingCommandRunnerTests {
    @Test("Every mutating verb sends the live capability without printing it")
    func capabilityPropagation() throws {
        let capability = "opaque-test-capability"
        let client = RecordingEnsembleClient(
            responses: [
                .runStarted(
                    EnsembleRunStartResult(
                        runID: "run-1",
                        workflow: "Ship",
                        worktree: "/work/.rafu-worktrees/work-run-1",
                        branch: "rafu/run-run-1",
                        state: .running,
                        startedBy: "co-test"
                    )),
                .mutation(
                    EnsembleMutationResult(
                        verb: "aborted",
                        runID: "run-1",
                        state: .aborted
                    )),
                .mutation(EnsembleMutationResult(verb: "noted", runID: "run-1")),
                .grant(
                    EnsembleGrantResult(
                        maxConcurrentChildRuns: 3,
                        activeChildRuns: 1,
                        maxTotalChildRuns: 12,
                        startedChildRuns: 1,
                        allowedProviders: ["codex"]
                    )),
            ])
        let runner = EnsembleCommandRunner(
            client: client,
            tokenProvider: { capability }
        )

        let invocations: [EnsembleInvocation] = [
            .run(
                workflow: "ship",
                roleOverrides: [],
                prompt: nil,
                artifacts: ["spec.md"],
                baseReference: nil,
                label: nil,
                json: false
            ),
            .abort(runID: "run-1"),
            .note(runID: "run-1", text: "Check this"),
            .grant(json: false),
        ]
        let results = invocations.map {
            runner.run($0, workingDirectory: "/work")
        }

        #expect(client.payloads.map(\.verb) == ["run", "abort", "note", "grant"])
        #expect(client.payloads.allSatisfy { $0.token == capability })
        #expect(client.payloads[0].artifacts == ["/work/spec.md"])
        for result in results {
            #expect(result.exitCode == .ok)
            #expect(!result.standardOutput.contains(capability))
            #expect(!result.standardError.contains(capability))
        }
    }

    @Test("Typed authorization and exhaustion codes survive the CLI boundary")
    func typedFailures() {
        for code in [EnsembleExitCode.noPermission, .tempFail] {
            let capability = "never-echo-this"
            let client = RecordingEnsembleClient(
                responses: [
                    .failure(
                        code: code.rawValue,
                        message: code == .noPermission
                            ? "A live coordinator capability is required."
                            : "The coordinator grant is exhausted."
                    )
                ])
            let result = EnsembleCommandRunner(
                client: client,
                tokenProvider: { capability }
            ).run(.grant(json: false), workingDirectory: "/work")

            #expect(result.exitCode == code)
            #expect(!result.standardError.contains(capability))
        }
    }
}

private final class RecordingEnsembleClient: EnsembleCLIClientProtocol, Sendable {
    private struct State: Sendable {
        var responses: [EnsembleResponsePayload]
        var payloads: [EnsembleRequestPayload] = []
    }

    private let state: Mutex<State>

    init(responses: [EnsembleResponsePayload]) {
        state = Mutex(State(responses: responses))
    }

    var payloads: [EnsembleRequestPayload] {
        state.withLock { $0.payloads }
    }

    func performEnsemble(
        _ payload: EnsembleRequestPayload
    ) throws -> EnsembleResponsePayload {
        try state.withLock { state in
            state.payloads.append(payload)
            guard !state.responses.isEmpty else {
                throw EnsembleCLIClientError.unexpectedResponse
            }
            return state.responses.removeFirst()
        }
    }

    func subscribe(
        payload: EnsembleRequestPayload,
        timeout: TimeInterval?,
        onSubscribed: (UInt64) throws -> Bool,
        onEvent: (EnsembleEvent) throws -> Bool
    ) throws {
        throw EnsembleCLIClientError.unexpectedResponse
    }
}
