import Foundation
import Testing

@testable import RafuCore

private func summary(
    _ id: String, _ provider: AgentHistoryProvider, _ path: String?, _ time: Double
) -> AgentHistorySessionSummary {
    AgentHistorySessionSummary(
        key: AgentHistorySessionKey(provider: provider, sessionID: id), title: id,
        projectPath: path, startedAt: nil, updatedAt: Date(timeIntervalSince1970: time),
        gitBranch: nil, messageCount: 1, isMessageCountEstimated: false,
        fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"), fileSize: 1,
        modificationDate: Date(timeIntervalSince1970: time))
}

@Test func handoffFindsTheNewestSessionForAFolderAndAgent() {
    let index = AgentHistoryIndex(sessions: [
        summary("old-claude", .claudeCode, "/work/alpha", 10),
        summary("new-claude", .claudeCode, "/work/alpha/", 30),
        summary("codex", .codex, "/work/alpha", 40),
        summary("sub", .claudeCode, "/work/alpha/app", 50),
        summary("other", .claudeCode, "/work/beta", 60),
        summary("nopath", .claudeCode, nil, 70),
    ])
    #expect(
        index.newestSession(provider: .claudeCode, inFolders: ["/work/alpha"])?.title
            == "new-claude")
    #expect(index.newestSession(provider: .codex, inFolders: ["/work/alpha"])?.title == "codex")
    #expect(
        index.newestSession(provider: .claudeCode, inFolders: ["/nope", "/work/beta"])?.title
            == "other")
    #expect(index.newestSession(provider: .codex, inFolders: ["/work/beta"]) == nil)
    #expect(index.newestSession(provider: .codex, inFolders: []) == nil)
}
