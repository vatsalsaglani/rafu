import Foundation
import Testing

@testable import RafuApp

@Suite("Step proposals parser")
struct ConductorStepProposalsParserTests {
    @Test("A list-valued proposes: key parses trimmed, non-empty entries")
    func listParses() {
        let text = """
            ---
            proposes:
              - Add a retry policy
              - Document the new flag
            ---
            Body text.
            """
        #expect(
            ConductorStepProposalsParser.parse(text)
                == ["Add a retry policy", "Document the new flag"])
    }

    @Test("A scalar proposes: value is rejected, not read as one entry")
    func scalarValueIsNil() {
        let text = """
            ---
            proposes: something
            ---
            Body text.
            """
        #expect(ConductorStepProposalsParser.parse(text) == nil)
    }

    @Test("No frontmatter at all parses to nil")
    func noFrontmatterIsNil() {
        #expect(ConductorStepProposalsParser.parse("plain markdown, no fence") == nil)
    }

    @Test("Frontmatter with no proposes: key parses to nil")
    func noKeyIsNil() {
        let text = """
            ---
            name: Something
            ---
            Body text.
            """
        #expect(ConductorStepProposalsParser.parse(text) == nil)
    }

    @Test("Over-cap entries truncate to 16, the 16th becoming the truncation marker")
    func overCapTruncates() throws {
        let items = (1...20).map { "- Proposal \($0)" }.joined(separator: "\n")
        let text = """
            ---
            proposes:
            \(items)
            ---
            """
        let parsed = try #require(ConductorStepProposalsParser.parse(text))
        #expect(parsed.count == 16)
        #expect(parsed[0] == "Proposal 1")
        #expect(parsed[14] == "Proposal 15")
        #expect(parsed[15] == "… (truncated)")
    }

    @Test("An over-length entry is truncated to 200 characters")
    func longEntryIsTruncated() throws {
        let longEntry = String(repeating: "x", count: 500)
        let text = """
            ---
            proposes:
              - \(longEntry)
            ---
            """
        let parsed = try #require(ConductorStepProposalsParser.parse(text))
        #expect(parsed.count == 1)
        #expect(parsed[0].count == 200)
    }

    @Test("A list continuation before any proposes: key is ignored, not misread")
    func unrelatedListIsIgnored() {
        let text = """
            ---
            tags:
              - release
            proposes:
              - Real entry
            ---
            """
        #expect(ConductorStepProposalsParser.parse(text) == ["Real entry"])
    }
}

/// Integration coverage for `ConductorWorkflowController.stepDidComplete`
/// actually wiring the parser above into a real completed step, and — the
/// non-negotiable half of the contract — that a malformed artifact NEVER
/// fails the step it belongs to.
@Suite("Step completion parses proposals, never fails on malformed artifacts")
struct ConductorStepCompletionProposalsTests {
    @MainActor
    @Test("A completed step's proposes: frontmatter becomes Step.proposals")
    func completedStepParsesProposals() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, controller) = makeWorkflowController(root: root)
        let launcher = WorkflowFakeLauncher()
        let runID = "proposals-happy"

        let workflow = workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)])
        let request = ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: [workflowRole(name: "worker", handoffArtifact: "report.md")],
            taskPrompt: "Ship it.",
            runID: runID)

        await controller.start(request, launcher: launcher)
        #expect(controller.state == .runningStep(index: 0))

        let artifactURL = root.appending(
            path: ".rafu/runs/\(runID)/steps/01-worker-a1/handoff/report.md")
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            ---
            proposes:
              - Add integration tests
            ---
            Report body.
            """.utf8
        ).write(to: artifactURL)
        launcher.finish(0, exitCode: 0)
        await controller.waitForPendingOperation()

        #expect(controller.state == .completed)
        #expect(controller.manifest?.steps[0].proposals == ["Add integration tests"])
    }

    @MainActor
    @Test("A binary, non-UTF8 artifact never fails the step; proposals are simply nil")
    func malformedArtifactNeverFailsTheStep() async throws {
        let root = try makeWorkflowTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, controller) = makeWorkflowController(root: root)
        let launcher = WorkflowFakeLauncher()
        let runID = "proposals-malformed"

        let workflow = workflowDefinition(
            steps: [(agentName: "worker", inputArtifacts: [], gateAfter: false)])
        let request = ConductorWorkflowRunRequest(
            workflow: workflow,
            roles: [workflowRole(name: "worker", handoffArtifact: "report.md")],
            taskPrompt: "Ship it.",
            runID: runID)

        await controller.start(request, launcher: launcher)
        #expect(controller.state == .runningStep(index: 0))

        let artifactURL = root.appending(
            path: ".rafu/runs/\(runID)/steps/01-worker-a1/handoff/report.md")
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Invalid UTF-8 bytes — not decodable as `String`.
        try Data([0xFF, 0xFE, 0x00, 0xD8, 0x00, 0x00]).write(to: artifactURL)
        launcher.finish(0, exitCode: 0)
        await controller.waitForPendingOperation()

        #expect(controller.state == .completed)
        #expect(controller.manifest?.steps[0].proposals == nil)
    }
}
