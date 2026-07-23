import Foundation
import Testing

@testable import RafuApp

/// conductor/C0-shim.md increments 1 and 2: the `.rafu/` file parsers, the
/// run-manifest envelope, `.rafu/` seeding, `ConductorRunStore`, and the
/// adapter registry's completeness/honesty contract. Everything here is
/// headless — no PTY, no CLI, no network — and every filesystem test works
/// inside its own temporary directory.

// MARK: - Temporary workspace helper

/// Every filesystem test gets its own throwaway root, removed afterwards, so
/// nothing here can see or disturb the developer's real repository.
private func withTemporaryWorkspaceAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "rafu-c0-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

// MARK: - Agent file parser

@Test("Agent parser reads every frontmatter field and the prompt body")
func agentParserReadsEveryField() throws {
    let text = """
        ---
        name: Advisor
        provider: claudeCode
        model: claude-sonnet-4-5
        autonomy: worktreeWrite
        handoffArtifact: brief.md
        ---
        You are the advisor.

        Write a brief.
        """
    let agent = try ConductorAgentFileParser.parse(text, defaultName: "advisor")
    #expect(agent.name == "Advisor")
    #expect(agent.provider == .claudeCode)
    #expect(agent.model == "claude-sonnet-4-5")
    #expect(agent.autonomy == .worktreeWrite)
    #expect(agent.handoffArtifact == "brief.md")
    #expect(agent.promptBody == "You are the advisor.\n\nWrite a brief.")
}

@Test("Agent parser ignores unknown frontmatter keys and strips quoted values")
func agentParserIgnoresUnknownKeys() throws {
    let text = """
        ---
        provider: "codex"
        name: 'Implementor'
        futureKeyFromANewerRafu: whatever
        # a comment
        ---
        Body.
        """
    let agent = try ConductorAgentFileParser.parse(text, defaultName: "implementor")
    #expect(agent.provider == .codex)
    #expect(agent.name == "Implementor")
    #expect(agent.promptBody == "Body.")
}

@Test("Agent parser tolerates another tool's list-valued metadata instead of failing the file")
func agentParserSkipsForeignListMetadata() throws {
    // The commonest shape of foreign frontmatter is a YAML list, whose
    // continuation lines carry no ":". Rejecting them would make the
    // "unknown keys are ignored" contract false exactly where it matters.
    let text = """
        ---
        provider: codex
        tags:
          - release
          - needs-review
        reviewers:
        -
        ---
        Body.
        """
    let agent = try ConductorAgentFileParser.parse(text, defaultName: "implementor")
    #expect(agent.provider == .codex)
    #expect(agent.name == "implementor")
    #expect(agent.promptBody == "Body.")

    // A genuinely malformed scalar line is still rejected — the tolerance is
    // for list items only.
    let garbage = """
        ---
        provider: codex
        this line has no separator
        ---
        Body.
        """
    #expect(throws: ConductorParseError.malformedFrontmatterLine(line: 3)) {
        _ = try ConductorAgentFileParser.parse(garbage, defaultName: "x")
    }
}

@Test("Agent parser throws when provider is missing or unrecognized")
func agentParserRequiresAKnownProvider() {
    let missing = """
        ---
        name: Nameless
        ---
        Body.
        """
    #expect(throws: ConductorParseError.missingProvider(line: 3)) {
        _ = try ConductorAgentFileParser.parse(missing, defaultName: "x")
    }

    let unknown = """
        ---
        provider: notARealCLI
        ---
        Body.
        """
    #expect(throws: ConductorParseError.unrecognizedProvider("notARealCLI", line: 3)) {
        _ = try ConductorAgentFileParser.parse(unknown, defaultName: "x")
    }
}

@Test("Agent parser defaults autonomy to readOnly — least privilege, never worktreeWrite")
func agentParserDefaultsAutonomyToReadOnly() throws {
    let absent = """
        ---
        provider: cline
        ---
        Body.
        """
    #expect(try ConductorAgentFileParser.parse(absent, defaultName: "x").autonomy == .readOnly)

    let garbled = """
        ---
        provider: cline
        autonomy: worktree-write
        ---
        Body.
        """
    #expect(try ConductorAgentFileParser.parse(garbled, defaultName: "x").autonomy == .readOnly)
}

@Test("Agent parser defaults name to the file stem and handoff artifact to handoff.md")
func agentParserAppliesDefaults() throws {
    let text = """
        ---
        provider: kimi
        ---
        Body.
        """
    let agent = try ConductorAgentFileParser.parse(text, defaultName: "documentor")
    #expect(agent.name == "documentor")
    #expect(agent.handoffArtifact == ConductorAgentFileParser.defaultHandoffArtifact)
    #expect(agent.handoffArtifact == "handoff.md")
    #expect(agent.model.isEmpty)
}

@Test("Agent parser trims leading and trailing blank lines from the prompt body")
func agentParserTrimsBody() throws {
    let text = "---\nprovider: cursor\n---\n\n\n  keep\n\n  me\n\n   \n"
    let agent = try ConductorAgentFileParser.parse(text, defaultName: "x")
    #expect(agent.promptBody == "  keep\n\n  me")
}

@Test("Agent parser throws with a line number when there is no frontmatter fence")
func agentParserRequiresFrontmatter() {
    #expect(throws: ConductorParseError.missingFrontmatter(line: 2)) {
        _ = try ConductorAgentFileParser.parse("\nJust a prompt, no fence.\n", defaultName: "x")
    }
    #expect(throws: ConductorParseError.missingFrontmatter(line: 1)) {
        _ = try ConductorAgentFileParser.parse("", defaultName: "x")
    }
    #expect(throws: ConductorParseError.unterminatedFrontmatter(line: 1)) {
        _ = try ConductorAgentFileParser.parse("---\nprovider: codex\n", defaultName: "x")
    }
}

// MARK: - Workflow file parser

@Test("Workflow parser reads ordered steps, input artifacts, and the [gate] marker")
func workflowParserReadsSteps() throws {
    let text = """
        ---
        name: Ship a change
        unknownKey: ignored
        steps:
          - advisor
          - implementor <- brief.md [gate]
          - documentor <- brief.md, patch.diff
        ---
        """
    let workflow = try ConductorWorkflowFileParser.parse(text, defaultName: "ship")
    #expect(workflow.name == "Ship a change")
    #expect(workflow.steps.map(\.agentName) == ["advisor", "implementor", "documentor"])
    #expect(workflow.steps[0].inputArtifacts.isEmpty)
    #expect(workflow.steps[1].inputArtifacts == ["brief.md"])
    #expect(workflow.steps[2].inputArtifacts == ["brief.md", "patch.diff"])
    #expect(workflow.steps.map(\.gateAfter) == [false, true, false])
}

@Test("Workflow parser tolerates extra whitespace and defaults the name to the file stem")
func workflowParserToleratesWhitespace() throws {
    let text = """
        ---
        steps:
            -   advisor    <-   a.md ,  b.md    [gate]
        ---
        """
    let workflow = try ConductorWorkflowFileParser.parse(text, defaultName: "review")
    #expect(workflow.name == "review")
    #expect(workflow.steps.count == 1)
    #expect(workflow.steps[0].agentName == "advisor")
    #expect(workflow.steps[0].inputArtifacts == ["a.md", "b.md"])
    #expect(workflow.steps[0].gateAfter)
}

@Test("Workflow parser throws with a line number for a malformed step line")
func workflowParserRejectsMalformedSteps() {
    let emptyAgent = """
        ---
        steps:
          - <- brief.md
        ---
        """
    #expect(throws: ConductorParseError.malformedStep(line: 3)) {
        _ = try ConductorWorkflowFileParser.parse(emptyAgent, defaultName: "x")
    }

    let danglingArrow = """
        ---
        steps:
          - advisor <-
        ---
        """
    #expect(throws: ConductorParseError.malformedStep(line: 3)) {
        _ = try ConductorWorkflowFileParser.parse(danglingArrow, defaultName: "x")
    }

    let listWithoutStepsKey = """
        ---
        name: x
          - advisor
        ---
        """
    #expect(throws: ConductorParseError.malformedStep(line: 3)) {
        _ = try ConductorWorkflowFileParser.parse(listWithoutStepsKey, defaultName: "x")
    }
}

@Test("Workflow parser rejects a mid-line [gate] instead of inventing an agent name")
func workflowParserRejectsAMisplacedGateMarker() {
    // `[gate]` is a suffix marker. Accepting it mid-line would bind the step
    // to an agent literally named "advisor [gate]", silently drop the gate,
    // and only surface much later as an unrelated "unknown agent" failure.
    let misplacedGate = """
        ---
        steps:
          - advisor [gate] <- brief.md
        ---
        """
    #expect(throws: ConductorParseError.malformedStep(line: 3)) {
        _ = try ConductorWorkflowFileParser.parse(misplacedGate, defaultName: "x")
    }

    let strayBracket = """
        ---
        steps:
          - advisor [review]
        ---
        """
    #expect(throws: ConductorParseError.malformedStep(line: 3)) {
        _ = try ConductorWorkflowFileParser.parse(strayBracket, defaultName: "x")
    }

    // The supported order still parses, gate and artifacts intact.
    let wellFormed = """
        ---
        steps:
          - advisor <- brief.md [gate]
        ---
        """
    let workflow = try? ConductorWorkflowFileParser.parse(wellFormed, defaultName: "x")
    #expect(workflow?.steps.first?.agentName == "advisor")
    #expect(workflow?.steps.first?.gateAfter == true)
    #expect(workflow?.steps.first?.inputArtifacts == ["brief.md"])
}

@Test("Workflow parser throws when the file declares no steps")
func workflowParserRequiresSteps() {
    #expect(throws: ConductorParseError.workflowHasNoSteps(line: 3)) {
        _ = try ConductorWorkflowFileParser.parse("---\nname: x\n---\n", defaultName: "x")
    }
}

// MARK: - Run manifest

private func manifestCoveringEveryStatus() -> ConductorRunManifest {
    let binding = ConductorRunManifest.AgentBinding(
        provider: .codex, model: "gpt-5", autonomy: .worktreeWrite, adapterVersion: "1.2.3")
    let statuses: [RunStepStatus] = [
        .pending, .running, .awaitingGate, .completed, .failed("boom"), .aborted,
    ]
    let steps = statuses.enumerated().map { index, status in
        ConductorRunManifest.Step(
            agentName: "role-\(index)",
            binding: binding,
            inputArtifacts: index == 0 ? [] : ["brief.md"],
            handoffArtifact: "handoff.md",
            gateAfter: index == 1,
            status: status,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: nil)
    }
    return ConductorRunManifest(
        id: "20260724-101500",
        workflowName: "Ship a change",
        baseCommit: "0123456789abcdef",
        worktreeBranch: "rafu/run-20260724-101500",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_060),
        steps: steps)
}

@Test("Run manifest round-trips every RunStepStatus case, including failed(_)")
func manifestRoundTripsEveryStatus() throws {
    let manifest = manifestCoveringEveryStatus()
    let data = try ConductorRunStore.makeEncoder().encode(manifest)
    let decoded = try ConductorRunStore.makeDecoder().decode(
        ConductorRunManifest.self, from: data)
    #expect(decoded == manifest)
    #expect(decoded.steps.map(\.status) == manifest.steps.map(\.status))
}

@Test("Run manifest JSON uses a stable {state, message} envelope and ISO-8601 dates")
func manifestJSONEnvelopeIsStable() throws {
    let data = try ConductorRunStore.makeEncoder().encode(manifestCoveringEveryStatus())
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains("\"state\" : \"failed\""))
    #expect(json.contains("\"boom\""))
    #expect(json.contains("\"state\" : \"awaitingGate\""))
    // `.iso8601`, not a numeric interval.
    #expect(json.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    // `.sortedKeys` keeps diffs reviewable.
    let baseCommitIndex = try #require(json.range(of: "\"baseCommit\"")).lowerBound
    let createdAtIndex = try #require(json.range(of: "\"createdAt\"")).lowerBound
    #expect(baseCommitIndex < createdAtIndex)
}

@Test("Decoding an unrecognized run step state throws instead of fabricating one")
func manifestRejectsUnknownStatus() throws {
    let data = try ConductorRunStore.makeEncoder().encode(manifestCoveringEveryStatus())
    let corrupted = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\"state\" : \"pending\"", with: "\"state\" : \"vibing\"")
    #expect(throws: DecodingError.self) {
        _ = try ConductorRunStore.makeDecoder().decode(
            ConductorRunManifest.self, from: Data(corrupted.utf8))
    }
}

// MARK: - .rafu/ seeding

@Test(".rafu/ seeding creates every directory and a gitignore covering runs/")
func seedingCreatesTheLayout() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let directory = RafuDotDirectory(workspaceRoot: root)
        let result = try await directory.seed()

        #expect(
            result.createdDirectories == [".rafu", ".rafu/agents", ".rafu/workflows", ".rafu/runs"]
        )
        #expect(result.gitignore == .created)
        let manager = FileManager.default
        for url in [
            directory.directoryURL, directory.agentsURL, directory.workflowsURL, directory.runsURL,
        ] {
            var isDirectory: ObjCBool = false
            #expect(manager.fileExists(atPath: url.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
        let ignore = try String(contentsOf: directory.gitignoreURL, encoding: .utf8)
        #expect(ignore.contains("runs/"))
    }
}

@Test("A second seed() changes nothing on disk and reports nothing created")
func seedingIsIdempotent() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let directory = RafuDotDirectory(workspaceRoot: root)
        _ = try await directory.seed()
        let firstBytes = try Data(contentsOf: directory.gitignoreURL)

        let second = try await directory.seed()
        #expect(second.createdDirectories.isEmpty)
        #expect(second.gitignore == .alreadyPresent)
        #expect(!second.didChangeAnything)
        #expect(try Data(contentsOf: directory.gitignoreURL) == firstBytes)
    }
}

@Test("Seeding never rewrites an existing .rafu/.gitignore or any agent file")
func seedingNeverOverwritesUserFiles() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let directory = RafuDotDirectory(workspaceRoot: root)
        let manager = FileManager.default
        try manager.createDirectory(at: directory.agentsURL, withIntermediateDirectories: true)

        let custom = Data("# my own rules\n!runs/keep-me\n".utf8)
        try custom.write(to: directory.gitignoreURL)
        let agentFile = directory.agentsURL.appending(path: "foo.md")
        let agentBytes = Data("---\nprovider: codex\n---\nmine\n".utf8)
        try agentBytes.write(to: agentFile)

        let result = try await directory.seed()
        #expect(result.gitignore == .alreadyPresent)
        #expect(try Data(contentsOf: directory.gitignoreURL) == custom)
        #expect(try Data(contentsOf: agentFile) == agentBytes)
        // The repository's OWN top-level .gitignore is never created.
        #expect(!manager.fileExists(atPath: root.appending(path: ".gitignore").path))
    }
}

@Test("Seeding never touches a pre-existing top-level .gitignore")
func seedingLeavesTheRepositoryGitignoreAlone() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let repositoryIgnore = root.appending(path: ".gitignore")
        let bytes = Data(".build/\n".utf8)
        try bytes.write(to: repositoryIgnore)

        _ = try await RafuDotDirectory(workspaceRoot: root).seed()
        #expect(try Data(contentsOf: repositoryIgnore) == bytes)
    }
}

@Test("Seeding throws rather than replacing a .rafu path that is a regular file")
func seedingRefusesToReplaceAFile() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let rafuPath = root.appending(path: ".rafu")
        try Data("not a directory".utf8).write(to: rafuPath)

        await #expect(throws: RafuDotDirectoryError.self) {
            _ = try await RafuDotDirectory(workspaceRoot: root).seed()
        }
        #expect(try Data(contentsOf: rafuPath) == Data("not a directory".utf8))
    }
}

// MARK: - Run store

@Test("Run store saves, reloads, and atomically re-saves a manifest")
func runStoreRoundTrips() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let store = ConductorRunStore(workspaceRoot: root)
        var manifest = manifestCoveringEveryStatus()
        try await store.save(manifest)
        #expect(try await store.load(runID: manifest.id) == manifest)

        manifest.steps[0].status = .completed
        manifest.updatedAt = Date(timeIntervalSince1970: 1_700_000_999)
        try await store.save(manifest)
        let reloaded = try await store.load(runID: manifest.id)
        #expect(reloaded?.steps[0].status == .completed)
        #expect(reloaded == manifest)
    }
}

@Test("Run store lists run ids sorted and returns nil for a run with no manifest")
func runStoreListsAndMisses() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let directory = RafuDotDirectory(workspaceRoot: root)
        let store = ConductorRunStore(directory: directory)
        _ = try await directory.seed()
        #expect(try await store.listRunIDs().isEmpty)

        var manifest = manifestCoveringEveryStatus()
        for id in ["20260724-3", "20260724-1", "20260724-2"] {
            manifest = ConductorRunManifest(
                id: id,
                workflowName: manifest.workflowName,
                baseCommit: manifest.baseCommit,
                worktreeBranch: manifest.worktreeBranch,
                createdAt: manifest.createdAt,
                updatedAt: manifest.updatedAt,
                steps: manifest.steps)
            try await store.save(manifest)
        }
        #expect(try await store.listRunIDs() == ["20260724-1", "20260724-2", "20260724-3"])
        #expect(try await store.load(runID: "never-ran") == nil)
    }
}

@Test("Run store surfaces a corrupt manifest as a typed error, never a trap")
func runStoreReportsCorruptManifests() async throws {
    try await withTemporaryWorkspaceAsync { root in
        let store = ConductorRunStore(workspaceRoot: root)
        let manifest = manifestCoveringEveryStatus()
        try await store.save(manifest)
        try Data("{ not json".utf8).write(to: store.manifestURL(for: manifest.id))

        await #expect(throws: ConductorRunStoreError.self) {
            _ = try await store.load(runID: manifest.id)
        }
    }
}

@Test("Run store rejects run ids that would escape .rafu/runs/ or hide inside it")
func runStoreRejectsTraversalRunIDs() async throws {
    #expect(!ConductorRunStore.isValidRunID("../escape"))
    #expect(!ConductorRunStore.isValidRunID("a/b"))
    #expect(!ConductorRunStore.isValidRunID(".."))
    #expect(!ConductorRunStore.isValidRunID("."))
    #expect(!ConductorRunStore.isValidRunID(""))
    // A dot-prefixed id would be writable but invisible: `listRunIDs()`
    // enumerates with `.skipsHiddenFiles`, so its evidence could never be
    // listed again.
    #expect(!ConductorRunStore.isValidRunID(".hidden-run"))
    #expect(ConductorRunStore.isValidRunID("20260724-101500"))

    try await withTemporaryWorkspaceAsync { root in
        let store = ConductorRunStore(workspaceRoot: root)
        await #expect(throws: ConductorRunStoreError.self) {
            _ = try await store.load(runID: "../escape")
        }
        await #expect(throws: ConductorRunStoreError.self) {
            _ = try await store.load(runID: ".hidden-run")
        }
    }
}
