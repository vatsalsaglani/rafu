import Foundation
import Testing

@testable import RafuCore

@Suite("Ensemble IPC framing")
struct EnsembleFramingTests {
    private let event = EnsembleEvent(
        cursor: 8,
        at: Date(timeIntervalSince1970: 1_700_000_000),
        runID: "run-a",
        kind: "state",
        state: .running,
        stepIndex: 1,
        label: "Parser",
        startedBy: "coordinator"
    )

    @Test("Request payload and envelope round-trip every read-only kind")
    func payloadRoundTrips() throws {
        let payload = EnsembleRequestPayload(
            verb: "status",
            workingDirectory: "/work/project",
            runIDs: ["run-a"],
            states: [.running, .completed],
            any: true,
            sinceCursor: 7,
            tree: true
        )
        for kind in [
            LauncherIPCRequestKind.ensembleStatus,
            .ensembleArtifact,
            .ensembleSubscribe,
        ] {
            let envelope = LauncherIPCEnvelope(kind: kind, ensemble: payload)
            let decoded: LauncherIPCEnvelope = try frameRoundTrip(envelope)
            #expect(decoded == envelope)
            #expect(decoded.kind.isEnsemble)
            #expect(decoded.kind.isStreaming == (kind == .ensembleSubscribe))
        }
    }

    @Test("Status, artifact, subscribed, and failure responses use stable result envelopes")
    func responsesRoundTrip() throws {
        let run = EnsembleRunSummary(
            runID: "run-a",
            workflowName: "Implement",
            label: "Parser",
            state: .running,
            startedBy: "coordinator",
            gate: EnsembleGateSummary(kind: "step", stepIndex: 0),
            steps: [
                EnsembleStepSummary(
                    index: 0,
                    agentName: "implementor",
                    provider: "codex",
                    model: "gpt-5.6",
                    state: "running",
                    attempt: 1,
                    evidencePath: "/work/.rafu/runs/run-a/steps/01",
                    artifacts: ["/work/.rafu/runs/run-a/steps/01/report.md"]
                )
            ],
            usageLines: ["Codex: 2.1%"]
        )
        let responses: [EnsembleResponsePayload] = [
            .status(
                EnsembleStatusResult(
                    runs: [run],
                    cursor: 8,
                    verbVersion: 1,
                    tree: true,
                    events: [event]
                )),
            .artifact(
                EnsembleArtifactResult(
                    runID: "run-a",
                    stepIndex: 0,
                    artifacts: ["/work/report.md"]
                )),
            .subscribed(cursor: 8),
            .failure(code: 65, message: "step not found"),
        ]

        for response in responses {
            let roundTripped: LauncherIPCResponse = try frameRoundTrip(.ensemble(response))
            #expect(roundTripped == .ensemble(response))
            let data = try JSONEncoder().encode(response)
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["result"] != nil)
        }
    }

    @Test("Events round-trip as independent RAFU frames")
    func eventRoundTrips() throws {
        let decoded: EnsembleEvent = try frameRoundTrip(event)
        #expect(decoded == event)
    }

    @Test("Failure retains its typed exit code")
    func failureCode() throws {
        let response = EnsembleResponsePayload.failure(code: 77, message: "not permitted")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(EnsembleResponsePayload.self, from: data)
        #expect(decoded == response)
    }

    @Test("Unknown fields are tolerated throughout the additive payload")
    func unknownFields() throws {
        let data = Data(
            """
            {
              "verb":"status",
              "workingDirectory":"/work",
              "runIDs":[],
              "states":[],
              "any":false,
              "future":{"nested":true}
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(EnsembleRequestPayload.self, from: data)
        #expect(decoded.verb == "status")
        #expect(decoded.workingDirectory == "/work")
        #expect(decoded.tree == nil)

        let oldEnvelope = Data(
            """
            {
              "wireVersion":1,
              "protocolVersion":1,
              "requestID":"old",
              "kind":"handshake",
              "payload":null
            }
            """.utf8
        )
        #expect(
            try JSONDecoder().decode(LauncherIPCEnvelope.self, from: oldEnvelope).ensemble == nil)
    }

    private func frameRoundTrip<T: Codable>(_ value: T) throws -> T {
        var decoder = LauncherIPCFrameDecoder()
        let bodies = try decoder.consume(LauncherIPCCodec.encode(value))
        let body = try #require(bodies.first)
        try decoder.finish()
        return try LauncherIPCCodec.decode(T.self, from: body)
    }
}
