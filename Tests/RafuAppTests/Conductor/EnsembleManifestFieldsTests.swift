import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble manifest additive fields")
struct EnsembleManifestFieldsTests {
    @Test("A pre-C8 manifest decodes with nil additive fields")
    func oldManifestDecodes() throws {
        let data = Data(
            """
            {
              "id":"old-run",
              "workflowName":"Workflow",
              "baseCommit":"abc",
              "worktreeBranch":"rafu/run-old",
              "createdAt":"2026-07-26T00:00:00Z",
              "updatedAt":"2026-07-26T00:01:00Z",
              "steps":[]
            }
            """.utf8
        )
        let decoded = try ConductorRunStore.makeDecoder().decode(
            ConductorRunManifest.self,
            from: data
        )

        #expect(decoded.startedBy == nil)
        #expect(decoded.label == nil)
        #expect(decoded.mergedAt == nil)
    }

    @Test("startedBy, label, and mergedAt round-trip")
    func fieldsRoundTrip() throws {
        let mergedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let value = ConductorRunManifest(
            id: "new-run",
            workflowName: "Workflow",
            baseCommit: "abc",
            worktreeBranch: "rafu/run-new",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            steps: [],
            startedBy: "coordinator",
            label: "Parser",
            mergedAt: mergedAt
        )
        let data = try ConductorRunStore.makeEncoder().encode(value)
        let decoded = try ConductorRunStore.makeDecoder().decode(
            ConductorRunManifest.self,
            from: data
        )

        #expect(decoded == value)
        #expect(decoded.startedBy == "coordinator")
        #expect(decoded.label == "Parser")
        #expect(decoded.mergedAt == mergedAt)
    }

    @Test("A pre-C8-04 manifest with no gate/proposals decodes unchanged")
    func preC804ManifestDecodesUnchanged() throws {
        let data = Data(
            """
            {
              "id":"old-run",
              "workflowName":"Workflow",
              "baseCommit":"abc",
              "worktreeBranch":"rafu/run-old",
              "createdAt":"2026-07-26T00:00:00Z",
              "updatedAt":"2026-07-26T00:01:00Z",
              "steps":[
                {
                  "agentName":"worker",
                  "binding":{"provider":"codex","model":"gpt-5","autonomy":"readOnly"},
                  "inputArtifacts":[],
                  "handoffArtifact":"report.md",
                  "gateAfter":false,
                  "status":{"state":"completed"}
                }
              ]
            }
            """.utf8
        )
        let decoded = try ConductorRunStore.makeDecoder().decode(
            ConductorRunManifest.self,
            from: data
        )

        #expect(decoded.gate == nil)
        #expect(decoded.steps[0].proposals == nil)
    }

    @Test("Gate.Kind.plan and Step.proposals round-trip")
    func planGateAndProposalsRoundTrip() throws {
        let binding = ConductorRunManifest.AgentBinding(
            provider: .codex, model: "gpt-5", autonomy: .readOnly, adapterVersion: "1")
        var step = ConductorRunManifest.Step(
            agentName: "worker",
            binding: binding,
            inputArtifacts: [],
            handoffArtifact: "report.md",
            gateAfter: false,
            status: .completed,
            startedAt: nil,
            finishedAt: nil)
        step.proposals = ["Add a retry policy", "… (truncated)"]
        var value = ConductorRunManifest(
            id: "plan-run",
            workflowName: "Workflow",
            baseCommit: "abc",
            worktreeBranch: "",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            steps: [step])
        value.gate = ConductorRunManifest.Gate(kind: .plan, stepIndex: 0)

        let data = try ConductorRunStore.makeEncoder().encode(value)
        let decoded = try ConductorRunStore.makeDecoder().decode(
            ConductorRunManifest.self,
            from: data
        )

        #expect(decoded == value)
        #expect(decoded.gate?.kind == .plan)
        #expect(decoded.steps[0].proposals == ["Add a retry policy", "… (truncated)"])
    }
}
