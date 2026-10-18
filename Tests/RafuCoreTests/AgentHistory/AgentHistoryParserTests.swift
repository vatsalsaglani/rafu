import Foundation
import Testing

@testable import RafuCore

private func date(_ text: String) -> Date? {
    AgentHistoryJSON.date(text)
}

private func summary(
    claude text: String, name: String = "\(AgentHistoryFixtures.claudeSessionID).jsonl"
) throws -> AgentHistorySessionSummary? {
    let url = try AgentHistoryFixtures.temporaryFile(text, name: name)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return try ClaudeCodeHistoryParser.summary(
        fileURL: url, size: Int64(text.utf8.count), modificationDate: Date(timeIntervalSince1970: 0)
    )
}

private func summary(codex text: String) throws -> AgentHistorySessionSummary? {
    let url = try AgentHistoryFixtures.temporaryFile(
        text, name: "rollout-2026-02-03T08-00-00-\(AgentHistoryFixtures.codexSessionID).jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return try CodexHistoryParser.summary(
        fileURL: url, size: Int64(text.utf8.count), modificationDate: Date(timeIntervalSince1970: 0)
    )
}

private func transcript(
    _ text: String, provider: AgentHistoryProvider, limits: AgentTranscriptLimits = .standard
) throws -> AgentTranscript {
    let url = try AgentHistoryFixtures.temporaryFile(text)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return try AgentTranscriptLoader.load(
        fileURL: url, key: AgentHistorySessionKey(provider: provider, sessionID: "s"),
        limits: limits)
}

// MARK: Claude Code

@Test func claudeSummaryUsesTitleCwdBranchAndTimes() throws {
    let value = try #require(try summary(claude: AgentHistoryFixtures.claudeSession))
    #expect(
        value.key
            == AgentHistorySessionKey(
                provider: .claudeCode, sessionID: AgentHistoryFixtures.claudeSessionID))
    #expect(value.title == "Add a login form")
    #expect(value.projectPath == "/work/alpha")
    #expect(value.fallbackProjectLabel == nil)
    #expect(value.gitBranch == "feature/login")
    #expect(value.startedAt == date("2026-01-02T10:00:00.000Z"))
    #expect(value.updatedAt == date("2026-01-02T10:05:00.000Z"))
    // One command, one prompt, two assistant replies. Meta, tool results,
    // thinking, and the sidechain entry do not count.
    #expect(value.messageCount == 4)
    #expect(!value.isMessageCountEstimated)
    #expect(value.cliVersion == "2.1.0")
}

@Test func claudeTitleFallsBackToFirstRealPrompt() throws {
    let value = try #require(
        try summary(
            claude: AgentHistoryFixtures.claudeImageSession,
            name: "\(AgentHistoryFixtures.claudeImageSessionID).jsonl"))
    #expect(value.title == "[Image] What does this screenshot show?")
    #expect(value.projectPath == "/work/alpha/app")
    #expect(value.messageCount == 2)
}

@Test func claudeCustomTitleWinsOverGeneratedTitle() throws {
    let text =
        AgentHistoryFixtures.claudeSession
        + #"{"type":"custom-title","customTitle":"My renamed\nsession","sessionId":"x"}"# + "\n"
    let value = try #require(try summary(claude: text))
    #expect(value.title == "My renamed session")
}

@Test func claudeBookkeepingOnlyFileIsNotASession() throws {
    #expect(try summary(claude: AgentHistoryFixtures.claudeEmptySession) == nil)
    #expect(try summary(claude: "not json\n{\"type\":\"user\"\n") == nil)
}

@Test func claudeMissingCwdUsesFolderLabelOnly() throws {
    let text =
        #"{"type":"user","message":{"role":"user","content":"Hello"},"sessionId":"s"}"# + "\n"
    let url = try AgentHistoryFixtures.temporaryFile(text, name: "-Users-me-app/s.jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let value = try #require(
        try ClaudeCodeHistoryParser.summary(
            fileURL: url, size: Int64(text.utf8.count), modificationDate: Date()))
    #expect(value.projectPath == nil)
    #expect(value.fallbackProjectLabel == "/Users/me/app")
    #expect(value.title == "Hello")
}

@Test func claudeTranscriptKeepsConversationAndCollapsesTools() throws {
    let value = try transcript(AgentHistoryFixtures.claudeSession, provider: .claudeCode)
    #expect(value.truncation == nil)
    #expect(value.skippedLineCount == 1)
    let kinds = value.items.map(\.kind)
    #expect(kinds == [.command, .message, .thinking, .message, .toolCall, .toolResult, .message])
    #expect(value.items[0].text == "/init")
    #expect(value.items[1].role == .user)
    #expect(value.items[1].text.contains("**email**"))
    #expect(value.items[3].text.contains("```swift"))
    let call = value.items[4]
    #expect(call.toolName == "Edit")
    #expect(call.text == "/work/alpha/Login.swift")
    #expect(call.detail?.contains("\"new_string\"") == true)
    let result = value.items[5]
    #expect(result.toolName == "Edit")
    #expect(result.text == "File updated.")
    #expect(!result.isError)
    #expect(value.items.map(\.id) == Array(0..<7))
    #expect(!value.items.contains { $0.text.contains("sidechain") })
}

@Test func transcriptStopsAtTheItemLimit() throws {
    var limits = AgentTranscriptLimits.standard
    limits.maximumItems = 2
    let value = try transcript(
        AgentHistoryFixtures.claudeSession, provider: .claudeCode, limits: limits)
    #expect(value.items.count == 2)
    #expect(value.truncation == .itemLimit)
}

@Test func transcriptStopsAtTheByteLimit() throws {
    var limits = AgentTranscriptLimits.standard
    limits.maximumBytes = 900
    let value = try transcript(
        AgentHistoryFixtures.claudeSession, provider: .claudeCode, limits: limits)
    #expect(value.truncation == .byteLimit)
    #expect(value.items.count < 7)
}

@Test func transcriptCutsLongMessages() throws {
    let long = String(repeating: "word ", count: 400)
    let text =
        #"{"type":"user","message":{"role":"user","content":"\#(long)"},"sessionId":"s","cwd":"/w"}"#
        + "\n"
    var limits = AgentTranscriptLimits.standard
    limits.maximumMessageCharacters = 100
    let value = try transcript(text, provider: .claudeCode, limits: limits)
    #expect(value.items.first?.text.count == 100)
    #expect(value.items.first?.isTruncated == true)
}

@Test func largeFileSummaryEstimatesTheMessageCount() throws {
    var lines: [String] = []
    for index in 0..<3_000 {
        lines.append(
            #"{"type":"user","message":{"role":"user","content":"Prompt number \#(index)"},"timestamp":"2026-01-02T10:00:00.000Z","cwd":"/work/big","sessionId":"big"}"#
        )
    }
    let text = lines.joined(separator: "\n") + "\n"
    #expect(text.utf8.count > 2 * ClaudeCodeHistoryParser.headBytes)
    let value = try #require(try summary(claude: text, name: "big.jsonl"))
    #expect(value.isMessageCountEstimated)
    #expect(value.title == "Prompt number 0")
    #expect(value.messageCount > 2_000 && value.messageCount < 4_000)
}

// MARK: Codex

@Test func codexSummarySkipsInjectedContext() throws {
    let value = try #require(try summary(codex: AgentHistoryFixtures.codexRollout))
    #expect(
        value.key
            == AgentHistorySessionKey(
                provider: .codex, sessionID: AgentHistoryFixtures.codexSessionID))
    #expect(value.title == "Fix the failing test in parser.rs")
    #expect(value.projectPath == "/work/beta")
    #expect(value.gitBranch == "develop")
    #expect(value.cliVersion == "0.50.0")
    #expect(value.startedAt == date("2026-02-03T08:00:00.000Z"))
    #expect(value.updatedAt == date("2026-02-03T08:10:00.000Z"))
    #expect(value.messageCount == 2)
}

@Test func codexSubagentThreadsAreHidden() throws {
    #expect(try summary(codex: AgentHistoryFixtures.codexSubagentRollout) == nil)
}

@Test func codexSessionIDFallsBackToTheFileName() {
    let url = URL(
        fileURLWithPath:
            "/x/rollout-2026-02-03T08-00-00-\(AgentHistoryFixtures.codexSessionID).jsonl")
    #expect(CodexHistoryParser.sessionID(fromFileName: url) == AgentHistoryFixtures.codexSessionID)
    #expect(
        CodexHistoryParser.sessionID(fromFileName: URL(fileURLWithPath: "/x/other.jsonl")) == nil)
}

@Test func codexTranscriptMapsResponseItems() throws {
    let value = try transcript(AgentHistoryFixtures.codexRollout, provider: .codex)
    #expect(value.skippedLineCount == 1)
    #expect(value.items.map(\.kind) == [.message, .thinking, .toolCall, .toolResult, .message])
    #expect(value.items[0].text == "Fix the failing test in parser.rs")
    #expect(value.items[1].text == "Read the test first.")
    #expect(value.items[2].toolName == "shell")
    #expect(value.items[2].text == "cargo test")
    #expect(value.items[3].toolName == "shell")
    #expect(value.items[3].isError)
    #expect(value.items[3].text == "1 test failed")
    #expect(value.items[4].role == .assistant)
}

@Test func codexEventOnlyRolloutFallsBackToEventMessages() throws {
    let value = try transcript(AgentHistoryFixtures.codexEventOnlyRollout, provider: .codex)
    #expect(value.items.map(\.text) == ["List the files", "Here are the files."])
    let url = try AgentHistoryFixtures.temporaryFile(AgentHistoryFixtures.codexEventOnlyRollout)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let head = try #require(
        try CodexHistoryParser.summary(fileURL: url, size: 1_000, modificationDate: Date()))
    #expect(head.title == "List the files")
    #expect(head.messageCount == 2)
}

@Test func codexSessionIndexKeepsTheLastCompleteName() throws {
    let url = try AgentHistoryFixtures.temporaryFile(
        AgentHistoryFixtures.codexSessionIndex, name: "session_index.jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let titles = try CodexSessionIndex.load(index: url)
    #expect(titles[AgentHistoryFixtures.codexSessionID] == "Parser test fix")
    #expect(titles["other"] == "Unrelated")
    let bounded = try CodexSessionIndex.load(index: url, byteLimit: 160)
    #expect(bounded["other"] == nil)
    #expect(bounded[AgentHistoryFixtures.codexSessionID] == "Parser test fix")
}

@Test func codexSessionIndexRefusesSymlinks() throws {
    let url = try AgentHistoryFixtures.temporaryFile(
        AgentHistoryFixtures.codexSessionIndex, name: "session_index.jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let link = url.deletingLastPathComponent().appendingPathComponent("link.jsonl")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    #expect(try CodexSessionIndex.load(index: link).isEmpty)
}

// MARK: Shared text rules

@Test func tagWrappedTextIsRecognised() {
    #expect(AgentHistoryEntryText.isTagWrapped("<environment_context>\n</environment_context>"))
    #expect(AgentHistoryEntryText.isTagWrapped("  <permissions instructions>x"))
    #expect(AgentHistoryEntryText.isTagWrapped("<system-reminder>x</system-reminder>"))
    #expect(!AgentHistoryEntryText.isTagWrapped("<div>Why is this HTML wrong?</div>"))
    #expect(!AgentHistoryEntryText.isTagWrapped("a < b > c"))
    #expect(!AgentHistoryEntryText.isTagWrapped("<>"))
}

@Test func singleLineCollapsesAndBounds() {
    #expect(AgentHistoryText.singleLine("  a\n\tb   c ", limit: 20) == "a b c")
    #expect(AgentHistoryText.singleLine(String(repeating: "x", count: 50), limit: 10).count == 10)
    #expect(
        AgentHistoryText.singleLine(String(repeating: "x", count: 50), limit: 10).hasSuffix("…"))
}

@Test func transcriptFindMatchesTextAndDetail() throws {
    let value = try transcript(AgentHistoryFixtures.claudeSession, provider: .claudeCode)
    #expect(value.matchingItemIDs("login", includeThinking: false) == [1, 3, 4])
    #expect(value.matchingItemIDs("PLAN", includeThinking: false).isEmpty)
    #expect(value.matchingItemIDs("plan", includeThinking: true) == [2])
    #expect(value.conversationContains("finished"))
    #expect(!value.conversationContains("File updated"))
}
