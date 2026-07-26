import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble graph model")
struct GraphModelTests {
    @Test("Layout is deterministic and step chains advance left to right")
    func deterministicStepLayout() throws {
        let run = manifest(
            id: "alpha",
            createdAt: Date(timeIntervalSince1970: 10),
            steps: [
                step(agent: "advisor", artifact: "brief.md", status: .completed),
                step(
                    agent: "implementor",
                    inputs: ["brief.md"],
                    artifact: "patch.md",
                    status: .running),
            ])

        let first = ConductorGraphModel.build(
            manifests: [run],
            liveStates: ["alpha": .runningStep(index: 1)],
            coordinators: [])
        let second = ConductorGraphModel.build(
            manifests: [run],
            liveStates: ["alpha": .runningStep(index: 1)],
            coordinators: [])

        #expect(first == second)
        let root = try #require(first.nodes.first(where: { $0.id == "run-alpha" }))
        let step1 = try #require(first.nodes.first(where: { $0.id == "run-alpha/step-1" }))
        let step2 = try #require(first.nodes.first(where: { $0.id == "run-alpha/step-2" }))
        #expect((root.column, step1.column, step2.column) == (0, 1, 2))
        #expect(first.edges.contains(ConductorGraphEdge(from: root.id, to: step1.id)))
        #expect(first.edges.contains(ConductorGraphEdge(from: step1.id, to: step2.id)))
    }

    @Test("Two coordinator trees plus one orphan produce three column-zero roots")
    func startedByGroupingAndOrphanRoot() {
        let runs = [
            manifest(id: "a", startedBy: "co-a"),
            manifest(id: "b", startedBy: "co-b"),
            manifest(id: "orphan"),
        ]
        let graph = ConductorGraphModel.build(
            manifests: runs,
            liveStates: [:],
            coordinators: [
                coordinator(id: "co-b", at: 2),
                coordinator(id: "co-a", at: 1),
            ])

        let roots = graph.nodes.filter { $0.column == 0 }
        #expect(Set(roots.map(\.id)) == ["co-a", "co-b", "run-orphan"])
        #expect(graph.nodes.first(where: { $0.id == "run-a" })?.column == 1)
        #expect(graph.nodes.first(where: { $0.id == "run-b" })?.column == 1)
        #expect(graph.edges.contains(ConductorGraphEdge(from: "co-a", to: "run-a")))
        #expect(graph.edges.contains(ConductorGraphEdge(from: "co-b", to: "run-b")))
    }

    @Test("A missing live coordinator is synthesized as an ended root")
    func endedCoordinatorSynthesis() throws {
        let graph = ConductorGraphModel.build(
            manifests: [manifest(id: "child", startedBy: "co-ended")],
            liveStates: [:],
            coordinators: [])

        let root = try #require(graph.nodes.first(where: { $0.id == "co-ended" }))
        #expect(root.kind == .coordinator)
        #expect(root.title == "Coordinator (ended)")
        #expect(root.runState == .ended)
        #expect(root.provider == nil)
    }

    @Test("Artifact inputs add dependency edges from earlier producers")
    func artifactEdgeDerivation() {
        let graph = ConductorGraphModel.build(
            manifests: [
                manifest(
                    id: "dependencies",
                    steps: [
                        step(agent: "advisor", artifact: "brief.md", status: .completed),
                        step(agent: "implementor", artifact: "patch.md", status: .completed),
                        step(
                            agent: "reviewer",
                            inputs: ["brief.md", "patch.md"],
                            artifact: "review.md",
                            status: .pending),
                    ])
            ],
            liveStates: [:],
            coordinators: [])

        #expect(
            graph.edges.contains(
                ConductorGraphEdge(
                    from: "run-dependencies/step-1",
                    to: "run-dependencies/step-3")))
        #expect(
            graph.edges.contains(
                ConductorGraphEdge(
                    from: "run-dependencies/step-2",
                    to: "run-dependencies/step-3")))
    }

    @Test("An open gate appends a semantic gate node after the run")
    func gateNodeAppended() throws {
        var run = manifest(
            id: "gate",
            steps: [step(agent: "implementor", artifact: "patch.md", status: .completed)])
        run.gate = ConductorRunManifest.Gate(kind: .merge, stepIndex: 0)

        let graph = ConductorGraphModel.build(
            manifests: [run],
            liveStates: ["gate": .awaitingMergeGate],
            coordinators: [])

        let gate = try #require(graph.nodes.first(where: { $0.id == "run-gate/gate" }))
        #expect(gate.kind == .gate)
        #expect(gate.runState == .mergeGate)
        #expect(gate.column == 2)
        #expect(
            graph.edges.contains(
                ConductorGraphEdge(from: "run-gate/step-1", to: "run-gate/gate")))
    }

    @Test("Unknown artifact inputs degrade to a waiting node without crashing or inventing edges")
    func unknownInputTolerance() throws {
        let graph = ConductorGraphModel.build(
            manifests: [
                manifest(
                    id: "unknown-input",
                    steps: [
                        step(
                            agent: "reviewer",
                            inputs: ["future-proposal.json"],
                            artifact: "review.md",
                            status: .pending)
                    ])
            ],
            liveStates: [:],
            coordinators: [])

        let node = try #require(
            graph.nodes.first(where: { $0.id == "run-unknown-input/step-1" }))
        #expect(node.runState == .blocked)
        #expect(node.detail.contains("future-proposal.json"))
        #expect(graph.edges == [ConductorGraphEdge(from: "run-unknown-input", to: node.id)])
    }

    @Test("A plan gate node renders the \"Plan gate\" title and reuses the awaitingGate state")
    func planGateNodeRendersPlanGateTitle() throws {
        var run = manifest(
            id: "planned",
            steps: [step(agent: "advisor", artifact: "brief.md", status: .pending)])
        run.gate = ConductorRunManifest.Gate(kind: .plan, stepIndex: 0)

        let graph = ConductorGraphModel.build(
            manifests: [run],
            liveStates: ["planned": .awaitingPlanGate],
            coordinators: [])

        let gate = try #require(graph.nodes.first(where: { $0.id == "run-planned/gate" }))
        #expect(gate.kind == .gate)
        #expect(gate.title == "Plan gate")
        // No new `EnsembleGraphState` case for the plan gate — it reuses
        // `.awaitingGate` exactly like a step gate (C1 hard limit).
        #expect(gate.runState == .awaitingGate)
    }

    @Test("Each proposal renders a dashed ghost node edged from its producing step")
    func proposalsRenderGhostNodes() throws {
        var completedStep = step(agent: "advisor", artifact: "brief.md", status: .completed)
        completedStep.proposals = ["Add a retry policy", "Document the new flag"]
        let run = manifest(id: "proposed", steps: [completedStep])

        let graph = ConductorGraphModel.build(
            manifests: [run], liveStates: [:], coordinators: [])

        let ghosts = graph.nodes.filter { $0.kind == .proposedGhost }
        #expect(ghosts.count == 2)
        #expect(ghosts.map(\.title) == ["Proposed", "Proposed"])
        #expect(ghosts.map(\.detail) == ["Add a retry policy", "Document the new flag"])
        #expect(ghosts.allSatisfy { $0.runState == .pending })
        for ghost in ghosts {
            #expect(
                graph.edges.contains(
                    ConductorGraphEdge(from: "run-proposed/step-1", to: ghost.id)))
        }
    }

    @Test("Over-cap proposals never emit more than 16 ghost nodes")
    func proposalsCapAtSixteenGhostNodes() throws {
        // Deliberately 20, ABOVE the cap. The parser normally caps at 16
        // before this point, so feeding an already-capped 16 would leave
        // `ConductorGraphModel`'s own `prefix(16)` — the belt-and-braces this
        // test exists to pin — never exercised. A hand-edited or
        // future-version manifest can carry more.
        var completedStep = step(agent: "advisor", artifact: "brief.md", status: .completed)
        completedStep.proposals = (1...20).map { "Proposal \($0)" }
        #expect(completedStep.proposals?.count == 20)
        let run = manifest(id: "capped", steps: [completedStep])

        let graph = ConductorGraphModel.build(
            manifests: [run], liveStates: [:], coordinators: [])

        let ghosts = graph.nodes.filter { $0.kind == .proposedGhost }
        #expect(ghosts.count == 16)
        #expect(ghosts.first?.detail == "Proposal 1")
        #expect(ghosts.last?.detail == "Proposal 16")
    }

    @Test("Graph step states keep shape-distinct glyphs and non-empty labels")
    func graphGlyphsAreShapeDistinctAndLabeled() {
        let statuses: [RunStepStatus] = [
            .pending, .running, .awaitingGate, .completed, .failed("boom"), .aborted,
            .interrupted,
        ]
        let presentations = statuses.map { ConductorRunPresentation.graphNode(for: $0) }
        #expect(Set(presentations.map(\.symbol)).count == presentations.count)
        #expect(presentations.allSatisfy { !$0.label.isEmpty })
    }

    private func coordinator(id: String, at: TimeInterval) -> CoordinatorNodeInput {
        CoordinatorNodeInput(
            id: id,
            title: "Coordinator",
            provider: .codex,
            terminalSessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: at),
            endedAt: nil)
    }

    private func manifest(
        id: String,
        startedBy: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1),
        steps: [ConductorRunManifest.Step] = []
    ) -> ConductorRunManifest {
        var value = ConductorRunManifest(
            id: id,
            workflowName: "Workflow \(id)",
            baseCommit: "0123456789012345678901234567890123456789",
            worktreeBranch: "rafu/run-\(id)",
            createdAt: createdAt,
            updatedAt: createdAt,
            steps: steps)
        value.startedBy = startedBy
        return value
    }

    private func step(
        agent: String,
        inputs: [String] = [],
        artifact: String,
        status: RunStepStatus
    ) -> ConductorRunManifest.Step {
        ConductorRunManifest.Step(
            agentName: agent,
            binding: ConductorRunManifest.AgentBinding(
                provider: .codex,
                model: "gpt-5",
                autonomy: .readOnly,
                adapterVersion: "test"),
            inputArtifacts: inputs,
            handoffArtifact: artifact,
            gateAfter: false,
            status: status,
            startedAt: nil,
            finishedAt: nil)
    }
}
