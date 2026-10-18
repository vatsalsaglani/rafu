import Foundation
import Testing

@testable import RafuCore

private func options(_ homes: AgentHistoryFixtures.Homes) -> AgentHistoryScanner.Options {
    AgentHistoryScanner.Options(
        locations: AgentHistoryLocations(
            claudeProjectsDirectory: homes.locations.claudeProjects,
            codexHomeDirectory: homes.locations.codexHome))
}

@Test func scannerFindsBothProvidersAndAppliesCodexNames() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    let scanner = AgentHistoryScanner()
    let result = try await scanner.scan(options(homes))
    let keys = Set(result.index.sessions.map(\.key))
    #expect(
        keys == [
            AgentHistorySessionKey(
                provider: .claudeCode, sessionID: AgentHistoryFixtures.claudeSessionID),
            AgentHistorySessionKey(
                provider: .claudeCode, sessionID: AgentHistoryFixtures.claudeImageSessionID),
            AgentHistorySessionKey(
                provider: .codex, sessionID: AgentHistoryFixtures.codexSessionID),
        ])
    let codex = try #require(
        result.index.sessions.first { $0.provider == .codex })
    #expect(codex.title == "Parser test fix")
    // Newest first: the Codex session ran a month after the Claude ones.
    #expect(result.index.sessions.first?.provider == .codex)
    #expect(result.index.projects.map(\.displayName) == ["beta", "app", "alpha"])
}

@Test func rescansReuseUnchangedFilesAndReparseChangedOnes() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    let scanner = AgentHistoryScanner()
    let first = try await scanner.scan(options(homes))
    #expect(first.reusedFileCount == 0)
    let second = try await scanner.scan(options(homes))
    #expect(second.parsedFileCount == 0)
    #expect(second.reusedFileCount == first.parsedFileCount)
    #expect(second.index == first.index)

    let handle = try FileHandle(forWritingTo: homes.claudeFile)
    try handle.seekToEnd()
    try handle.write(
        contentsOf: Data(
            (#"{"type":"custom-title","customTitle":"Renamed","sessionId":"x"}"# + "\n").utf8))
    try handle.close()
    let third = try await scanner.scan(options(homes))
    #expect(third.parsedFileCount == 1)
    #expect(
        third.index.sessions.first { $0.key.sessionID == AgentHistoryFixtures.claudeSessionID }?
            .title == "Renamed")

    try FileManager.default.removeItem(at: homes.codexFile)
    let fourth = try await scanner.scan(options(homes))
    #expect(!fourth.index.sessions.contains { $0.provider == .codex })
}

@Test func scannerHonoursProviderToggles() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    var only = options(homes)
    only.includesClaudeCode = false
    let result = try await AgentHistoryScanner().scan(only)
    #expect(result.index.sessions.allSatisfy { $0.provider == .codex })
    #expect(result.index.sessions.count == 1)
}

@Test func scannerToleratesMissingFolders() async throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("rafu-missing-\(UUID().uuidString)")
    let result = try await AgentHistoryScanner().scan(
        AgentHistoryScanner.Options(
            locations: AgentHistoryLocations(
                claudeProjectsDirectory: missing, codexHomeDirectory: missing)))
    #expect(result.index == .empty)
}

@Test func scanStopsWhenCancelled() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    let scanner = AgentHistoryScanner()
    let opts = options(homes)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await scanner.scan(opts)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func messageSearchLooksAtPromptsAndRepliesOnly() async throws {
    let homes = try AgentHistoryFixtures.makeHomes()
    defer { homes.remove() }
    let index = try await AgentHistoryScanner().scan(options(homes)).index
    let replies = try await AgentHistoryMessageSearch.sessions(
        matching: "settings window", in: index.sessions)
    #expect(replies.map(\.sessionID) == [AgentHistoryFixtures.claudeImageSessionID])
    let toolOutput = try await AgentHistoryMessageSearch.sessions(
        matching: "1 test failed", in: index.sessions)
    #expect(toolOutput.isEmpty)
}

// MARK: Index

private func session(
    _ id: String, provider: AgentHistoryProvider = .claudeCode, title: String = "Title",
    path: String?, branch: String? = nil, day: Int
) -> AgentHistorySessionSummary {
    AgentHistorySessionSummary(
        key: AgentHistorySessionKey(provider: provider, sessionID: id), title: title,
        projectPath: path, startedAt: nil,
        updatedAt: Date(timeIntervalSince1970: TimeInterval(day * 86_400)), gitBranch: branch,
        messageCount: 1, isMessageCountEstimated: false,
        fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"), fileSize: 1,
        modificationDate: Date(timeIntervalSince1970: 0))
}

@Test func indexGroupsByNormalizedPathNewestFirst() {
    let index = AgentHistoryIndex(sessions: [
        session("a", path: "/work/alpha/", day: 1),
        session("b", path: "/work/alpha", day: 3),
        session("c", path: "/work/beta", day: 2),
        session("d", path: nil, day: 4),
    ])
    #expect(index.sessions.map(\.key.sessionID) == ["d", "b", "c", "a"])
    #expect(index.projects.map(\.id) == ["unknown", "/work/alpha", "/work/beta"])
    #expect(index.projects[1].sessions.map(\.key.sessionID) == ["b", "a"])
    #expect(index.projects[0].path == nil)
}

@Test func filterMatchesTitleFolderBranchAndProvider() {
    let index = AgentHistoryIndex(sessions: [
        session("a", title: "Fix Café menu", path: "/work/alpha", day: 1),
        session(
            "b", provider: .codex, title: "Other", path: "/work/beta", branch: "cafe-x", day: 2),
        session("c", title: "Unrelated", path: "/work/gamma", day: 3),
    ])
    #expect(
        index.filtered(provider: .all, query: "cafe").sessions.map(\.key.sessionID) == ["b", "a"])
    #expect(index.filtered(provider: .codex, query: "cafe").sessions.map(\.key.sessionID) == ["b"])
    #expect(index.filtered(provider: .claudeCode, query: "").sessions.count == 2)
    #expect(index.filtered(provider: .all, query: "gamma").sessions.map(\.key.sessionID) == ["c"])
    let byMessage = index.filtered(
        provider: .all, query: "zzz",
        messageMatches: [AgentHistorySessionKey(provider: .claudeCode, sessionID: "c")])
    #expect(byMessage.sessions.map(\.key.sessionID) == ["c"])
}

@Test func partitionPutsWorkspaceFoldersFirst() {
    let index = AgentHistoryIndex(sessions: [
        session("a", path: "/work/alpha", day: 1),
        session("b", path: "/work/alpha/app", day: 2),
        session("c", path: "/work/alphabet", day: 3),
        session("d", path: nil, day: 4),
    ])
    let parts = index.partition(workspaceRoots: ["/work/alpha/"])
    #expect(parts.workspace.map(\.id) == ["/work/alpha/app", "/work/alpha"])
    #expect(parts.others.map(\.id) == ["unknown", "/work/alphabet"])
    #expect(index.partition(workspaceRoots: []).workspace.isEmpty)
}

@Test func pathHelpers() {
    #expect(AgentHistoryPath.normalized("/a/b/../c/./") == "/a/c")
    #expect(AgentHistoryPath.isPath("/a/b", inside: "/a"))
    #expect(!AgentHistoryPath.isPath("/ab", inside: "/a"))
    #expect(AgentHistoryPath.displayName(of: "/a/project/") == "project")
    #expect(AgentHistoryPath.abbreviated("/Users/me/code", home: "/Users/me") == "~/code")
    #expect(AgentHistoryPath.abbreviated("/opt/code", home: "/Users/me") == "/opt/code")
}

// MARK: Locations and resume command

@Test func locationsHonourEnvironmentOverrides() {
    let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    let defaults = AgentHistoryLocations.resolve(environment: [:], homeDirectory: home)
    #expect(defaults.claudeProjectsDirectory.path == "/Users/me/.claude/projects")
    #expect(defaults.codexSessionsDirectory.path == "/Users/me/.codex/sessions")
    #expect(defaults.codexSessionIndexFile.path == "/Users/me/.codex/session_index.jsonl")
    let custom = AgentHistoryLocations.resolve(
        environment: ["CLAUDE_CONFIG_DIR": "/data/claude/", "CODEX_HOME": "~/cx"],
        homeDirectory: home)
    #expect(custom.claudeProjectsDirectory.path == "/data/claude/projects")
    #expect(custom.codexHomeDirectory.path == "/Users/me/cx")
    let relative = AgentHistoryLocations.resolve(
        environment: ["CLAUDE_CONFIG_DIR": "relative", "CODEX_HOME": ""], homeDirectory: home)
    #expect(relative == defaults)
}

@Test func resumeCommandIsQuotedAndValidated() {
    let claude = AgentHistorySessionKey(provider: .claudeCode, sessionID: "abc-123")
    #expect(AgentHistoryResumeCommand.arguments(for: claude) == ["claude", "--resume", "abc-123"])
    let codex = AgentHistorySessionKey(provider: .codex, sessionID: "abc_123")
    #expect(AgentHistoryResumeCommand.arguments(for: codex) == ["codex", "resume", "abc_123"])
    for bad in ["", "-rf", "a b", "a;rm", "a'b", "$(x)", "a\nb"] {
        #expect(
            AgentHistoryResumeCommand.arguments(
                for: AgentHistorySessionKey(provider: .codex, sessionID: bad)) == nil)
    }
    #expect(AgentHistoryResumeCommand.shellLine(["codex", "resume", "x1"]) == "codex resume x1")
    #expect(AgentHistoryResumeCommand.quoted("it's") == #"'it'\''s'"#)
    #expect(AgentHistoryResumeCommand.quoted("") == "''")
    #expect(AgentHistoryResumeCommand.quoted("a b;c") == "'a b;c'")
}
