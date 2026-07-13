import Foundation
import Testing

@testable import RafuApp

@Test("AI provider configurations round-trip without containing secrets")
func aiProviderConfigurationRoundTrip() throws {
    let configuration = AIProviderConfiguration(
        id: UUID(uuidString: "7D50E0D0-BDE4-495E-B2A1-EE73D01780A1")!,
        name: "Local model",
        kind: .openAICompatible,
        baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
        model: "qwen3-coder",
        openAITransport: .chatCompletions,
        maxOutputTokens: 300
    )

    let data = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(AIProviderConfiguration.self, from: data)

    #expect(decoded == configuration)
    #expect(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("apiKey"))
}

@Test("OpenAI-compatible model aliases may contain provider namespaces")
func namespacedCompatibleModelIsValid() throws {
    let configuration = AIProviderConfiguration(
        name: "Gateway",
        kind: .openAICompatible,
        baseURL: URL(string: "https://gateway.example/v1")!,
        model: "anthropic/claude-sonnet"
    )

    #expect(try configuration.validated().model == "anthropic/claude-sonnet")
}

@Test("Only loopback custom providers may use plain HTTP")
func aiProviderConfigurationRejectsInsecureRemoteURL() throws {
    let remote = AIProviderConfiguration(
        name: "Remote",
        kind: .openAICompatible,
        baseURL: URL(string: "http://models.example/v1")!,
        model: "model"
    )
    #expect(throws: AIProviderError.self) { try remote.validated() }

    let loopback = AIProviderConfiguration(
        name: "Local",
        kind: .openAICompatible,
        baseURL: URL(string: "http://localhost:11434/v1")!,
        model: "model"
    )
    #expect(throws: Never.self) { try loopback.validated() }
}

@Test("Commit prompts include only explicitly selected, bounded diffs")
func aiCommitPromptUsesSelectedDiffs() throws {
    let prompt = try AICommitPromptBuilder().makePrompt(
        input: AICommitPromptInput(fullDiffs: [
            AISelectedDiff(path: "Sources/Chosen.swift", patch: "+chosen")
        ])
    )

    #expect(prompt.contains("Sources/Chosen.swift"))
    #expect(prompt.contains("+chosen"))
    #expect(!prompt.contains("Unselected.swift"))
    #expect(throws: AIProviderError.selectedDiffsRequired) {
        try AICommitPromptBuilder().makePrompt(input: AICommitPromptInput(fullDiffs: []))
    }
}

@Test("Large changesets summarize the remainder instead of throwing")
func aiCommitPromptSummarizesLargeChangesets() throws {
    let input = AICommitPromptInput(
        fullDiffs: [AISelectedDiff(path: "Sources/Chosen.swift", patch: "+chosen")],
        summaries: [
            AICommitDiffSummary(
                path: "Sources/Other.swift", statusLabel: "Modified", added: 3, deleted: 1),
            AICommitDiffSummary(path: "NewFile.txt", statusLabel: "New file"),
        ],
        overflowFileCount: 42
    )

    let prompt = try AICommitPromptBuilder().makePrompt(input: input)

    #expect(prompt.contains("<summarized-changes>"))
    #expect(prompt.contains("Sources/Other.swift — Modified, +3/-1"))
    #expect(prompt.contains("NewFile.txt — New file"))
    #expect(prompt.contains("…and 42 more files"))
}

@Test("Full patches truncate at the per-file byte cap with a literal marker")
func aiCommitPromptTruncatesOversizedPatches() throws {
    let bigLine = String(repeating: "+line\n", count: 20_000)
    let (truncated, isTruncated) = AICommitPromptBuilder.truncated(patch: bigLine)

    #expect(isTruncated)
    #expect(truncated.utf8.count <= AICommitPromptBuilder.maximumPatchBytesPerFile + 64)
    #expect(truncated.hasSuffix("[truncated: patch exceeds per-file limit]"))

    let (unchanged, notTruncated) = AICommitPromptBuilder.truncated(patch: "+small change\n")
    #expect(!notTruncated)
    #expect(unchanged == "+small change\n")
}

@Test("Diff ordering fetches the smallest estimated changes first")
func aiCommitDiffOrderingPrioritizesSmallestFirst() throws {
    let big = GitChange(path: "big.swift", indexStatus: " ", worktreeStatus: "M")
    let small = GitChange(path: "small.swift", indexStatus: " ", worktreeStatus: "M")
    let untracked = GitChange(path: "new.txt", indexStatus: "?", worktreeStatus: "?")
    let binary = GitChange(path: "image.png", indexStatus: " ", worktreeStatus: "M")
    let unknownSize = GitChange(path: "conflict.txt", indexStatus: "U", worktreeStatus: "U")

    let lineStats: [String: GitLineStats] = [
        "big.swift": GitLineStats(added: 500, deleted: 0),
        "small.swift": GitLineStats(added: 2, deleted: 1),
        "image.png": GitLineStats(isBinary: true),
    ]
    let untrackedSizes = ["new.txt": 400]

    let ordered = AICommitDiffOrdering.order(
        changes: [big, small, untracked, binary, unknownSize],
        lineStats: lineStats,
        untrackedFileSizes: untrackedSizes
    )

    #expect(
        ordered.map(\.path) == ["small.swift", "new.txt", "big.swift", "conflict.txt", "image.png"])
}

@Test("Partially staged files include both staged and working-tree diffs")
func aiCommitScopeIncludesBothSidesOfPartialStage() {
    let resolver = AICommitDiffScopeResolver()

    #expect(
        resolver.scopes(isStaged: true, hasUnstagedChanges: true)
            == [.staged, .workingTree]
    )
    #expect(
        resolver.scopes(isStaged: true, hasUnstagedChanges: false)
            == [.staged]
    )
    #expect(
        resolver.scopes(isStaged: false, hasUnstagedChanges: true)
            == [.workingTree]
    )
}

@Test("Provider store persists the explicitly selected configuration without secrets")
func aiProviderStorePersistsSelection() async throws {
    let suiteName = "RafuAIProviderTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsAIProviderConfigurationStore(suiteName: suiteName)
    let provider = AIProviderConfiguration(
        name: "Test Provider",
        kind: .openAI,
        model: "gpt-5.1"
    )

    try await store.save([provider])
    await store.setSelectedConfigurationID(provider.id)
    let loaded = try await store.load()
    let selectedID = await store.selectedConfigurationID()

    #expect(loaded == [provider])
    #expect(selectedID == provider.id)
}

@Test("Commit scope prefers staged changes; explicit selection overrides")
func commitScopePrecedence() {
    let staged = GitChange(path: "a.swift", indexStatus: "A", worktreeStatus: ".")
    let unstaged = GitChange(path: "b.swift", indexStatus: ".", worktreeStatus: "M")
    let all = [staged, unstaged]

    // Nothing selected, something staged → staged files, staged diffs only.
    let stagedOnly = AICommitScopeSelection.resolve(
        selectedIDs: [], allChanges: all, stagedChanges: [staged])
    #expect(stagedOnly.changes.map(\.path) == ["a.swift"])
    #expect(stagedOnly.stagedDiffsOnly)

    // Explicit row selection wins over staged state.
    let selected = AICommitScopeSelection.resolve(
        selectedIDs: [unstaged.id], allChanges: all, stagedChanges: [staged])
    #expect(selected.changes.map(\.path) == ["b.swift"])
    #expect(!selected.stagedDiffsOnly)

    // Nothing staged, nothing selected → whole working tree as a draft aid.
    let everything = AICommitScopeSelection.resolve(
        selectedIDs: [], allChanges: all, stagedChanges: [])
    #expect(everything.changes.count == 2)
    #expect(!everything.stagedDiffsOnly)
}

@Test("Merge context switches instruction and embeds a merge block")
func mergeContextPrompt() throws {
    let builder = AICommitPromptBuilder()
    var input = AICommitPromptInput(
        fullDiffs: [
            AISelectedDiff(path: "a.swift", patch: "+let a = 1", isTruncated: false)
        ]
    )
    #expect(!builder.instructions(for: input).contains("Merge"))

    input.mergeContext = "Merge branch 'staging' into main"
    let instructions = builder.instructions(for: input)
    #expect(instructions.contains("MUST begin with \"Merge\""))
    let prompt = try builder.makePrompt(input: input)
    #expect(prompt.contains("<merge-context>"))
    #expect(prompt.contains("Merge branch 'staging' into main"))

    let cleaned = GitMergeState.cleaned(
        message: "Merge branch 'staging'\n# comment line\n\nbody text\n")
    #expect(cleaned == "Merge branch 'staging'\n\nbody text")
}
