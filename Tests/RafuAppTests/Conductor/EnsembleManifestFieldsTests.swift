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
}
