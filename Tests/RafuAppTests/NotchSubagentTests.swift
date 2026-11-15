import Foundation
import RafuCore
import Testing

@testable import RafuApp

// Sub-agents on agent rows (ADR 0029 amendment): the entries the notch and
// the menu bar card show, their chip and spoken text, and the store path
// from hook events to rows.

@Test("NotchSubagentEntry: line skips missing parts; chip and spoken text count")
func subagentEntryText() {
    let full = NotchSubagentEntry(
        id: "a1", type: "implementor", model: "opus", taskDescription: "Build the menu card")
    let bare = NotchSubagentEntry(id: "a2")
    #expect(full.line == "implementor · opus · Build the menu card")
    #expect(bare.line == "Sub-agent")
    #expect(NotchSubagentEntry(id: "a3", type: "Explore").line == "Explore")
    #expect(NotchSubagentEntry.chipText(count: 1) == "1 sub-agent")
    #expect(NotchSubagentEntry.chipText(count: 3) == "3 sub-agents")
    #expect(
        NotchSubagentEntry.spokenSummary([full, bare])
            == "2 sub-agents running: implementor, Sub-agent")
    #expect(NotchSubagentEntry.needsReconnectNote([full, bare]))
    #expect(!NotchSubagentEntry.needsReconnectNote([full]))
}

@Test("NotchAgentRow.rows carries a terminal's sub-agents onto its row")
func rowsCarrySubagents() {
    let entry = NotchSubagentEntry(id: "a1", type: "Explore")
    let rows = NotchAgentRow.rows(from: [
        NotchTerminalInput(
            id: UUID(), title: "claude", cli: .claudeCode, status: .running,
            subagents: [entry]),
        NotchTerminalInput(id: UUID(), title: "zsh", cli: nil, status: .running),
    ])
    #expect(rows.count == 1)
    #expect(rows.first?.subagents == [entry])
}

@Test("AgentTrackedPhase.subagentEntries maps the ledger's sub-agents in start order")
func subagentEntriesFromLedger() throws {
    var ledger = AgentSessionLedger()
    ledger.apply(
        AgentHookEvent(
            provider: .claude, sessionID: "s", hookEventName: "PreToolUse", toolName: "Agent",
            time: Date(timeIntervalSince1970: 1), subagentType: "implementor",
            subagentModel: "sonnet", subagentDescription: "Write tests"))
    for (index, id) in ["a1", "a2"].enumerated() {
        ledger.apply(
            AgentHookEvent(
                provider: .claude, sessionID: "s", subagentID: id, hookEventName: "SubagentStart",
                time: Date(timeIntervalSince1970: TimeInterval(2 + index)),
                subagentType: "implementor"))
    }
    let session = try #require(ledger.sessions.first)
    let entries = AgentTrackedPhase.subagentEntries(session)
    #expect(entries.map(\.id) == ["a1", "a2"])
    #expect(entries.first?.line == "implementor · sonnet · Write tests")
    #expect(entries.last?.line == "implementor")
    #expect(AgentTrackedPhase.subagentEntries(nil).isEmpty)
}

@MainActor
@Test("AgentActivityStore: sub-agent events reach outside rows and expire after silence")
func storeSubagentsReachRows() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.subagent-store")
    defer { TestDefaultsSuite.remove(suite) }
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-subagents-\(UUID().uuidString)/AgentTracking")
    let store = AgentActivityStore(
        paths: AgentTrackingPaths(root: root),
        defaults: UserDefaults(suiteName: suite) ?? .standard)
    let start = Date(timeIntervalSince1970: 1_000)
    store.apply(
        [
            AgentHookEvent(
                provider: .claude, sessionID: "s", hookEventName: "UserPromptSubmit",
                cwd: "/repo/app", time: start),
            AgentHookEvent(
                provider: .claude, sessionID: "s", subagentID: "a1",
                hookEventName: "SubagentStart", cwd: "/repo/app", time: start,
                subagentType: "Explore"),
        ], at: start)
    let rows = store.externalNotchRows(excluding: [])
    #expect(rows.first?.subagents.map(\.line) == ["Explore"])

    store.apply([], at: start.addingTimeInterval(TrackedAgentSession.subagentStaleInterval + 1))
    #expect(store.sessions.first?.subagents.isEmpty == true)
}
