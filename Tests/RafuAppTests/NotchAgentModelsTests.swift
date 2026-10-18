import Foundation
import Testing

@testable import RafuApp

/// The notch's agent aggregation and the mascot state machine: pure value
/// logic, no windows, no terminals.

private func row(_ phase: NotchAgentPhase, id: UUID = UUID(), board: UUID? = nil) -> NotchAgentRow {
    NotchAgentRow(id: id, title: "agent", cli: .claudeCode, phase: phase, boardID: board)
}

// MARK: - Phase

@Test("NotchAgentPhase.resolve: status, output, and attention cause map to the five phases")
func agentPhaseResolution() {
    #expect(
        NotchAgentPhase.resolve(status: .idle, isProducingOutput: false, cause: nil) == .stopped)
    #expect(
        NotchAgentPhase.resolve(status: .exited(code: 0), isProducingOutput: true, cause: nil)
            == .stopped)
    #expect(
        NotchAgentPhase.resolve(status: .running, isProducingOutput: true, cause: nil) == .working)
    #expect(
        NotchAgentPhase.resolve(status: .running, isProducingOutput: false, cause: nil) == .idle)
    #expect(
        NotchAgentPhase.resolve(status: .bell, isProducingOutput: false, cause: .signal)
            == .needsYou)
    #expect(
        NotchAgentPhase.resolve(status: .bell, isProducingOutput: false, cause: nil) == .needsYou)
    #expect(
        NotchAgentPhase.resolve(status: .bell, isProducingOutput: true, cause: .completion)
            == .replyReady)
}

@Test("NotchAgentPhase: only needsYou and replyReady ask for attention; stopped is not live")
func agentPhaseFlags() {
    #expect(NotchAgentPhase.needsYou.needsAttention)
    #expect(NotchAgentPhase.replyReady.needsAttention)
    #expect(!NotchAgentPhase.working.needsAttention)
    #expect(!NotchAgentPhase.idle.needsAttention)
    #expect(!NotchAgentPhase.stopped.isLive)
    #expect(NotchAgentPhase.idle.isLive)
    // Every phase has a label and a glyph, so state never rests on colour.
    for phase in [NotchAgentPhase.working, .needsYou, .replyReady, .idle, .stopped] {
        #expect(!phase.label.isEmpty)
        #expect(!phase.symbol.isEmpty)
    }
}

// MARK: - Rows and summary

@Test("NotchAgentRow.rows: ordinary shells are dropped, agents keep their input order")
func agentRowsDropShells() {
    let first = UUID()
    let second = UUID()
    let rows = NotchAgentRow.rows(from: [
        NotchTerminalInput(id: first, title: "claude", cli: .claudeCode, status: .running),
        NotchTerminalInput(id: UUID(), title: "zsh 1", cli: nil, status: .running),
        NotchTerminalInput(id: second, title: "codex", cli: .codex, status: .bell, cause: .signal),
    ])
    #expect(rows.map(\.id) == [first, second])
    #expect(rows.map(\.phase) == [.idle, .needsYou])
}

@Test("NotchAgentRow.byUrgency: needs you, reply ready, running, waiting, stopped; ties keep order")
func agentRowsSortByUrgency() {
    let a = row(.idle)
    let b = row(.needsYou)
    let c = row(.working)
    let d = row(.needsYou)
    let e = row(.replyReady)
    let f = row(.stopped)
    let sorted = NotchAgentRow.byUrgency([a, b, c, d, e, f])
    #expect(sorted.map(\.id) == [b.id, d.id, e.id, c.id, a.id, f.id])
}

@Test("NotchAgentSummary: counts live, running, needs you, and reply ready; stopped is excluded")
func agentSummaryCounts() {
    let summary = NotchAgentSummary.summarize([
        row(.working), row(.working), row(.needsYou), row(.replyReady), row(.idle), row(.stopped),
    ])
    #expect(summary.live == 5)
    #expect(summary.working == 2)
    #expect(summary.needsYou == 1)
    #expect(summary.replyReady == 1)
    #expect(summary.attention == 2)
    #expect(summary.spokenSummary == "5 agents, 1 needs you, 1 reply ready, 2 running")
    #expect(NotchAgentSummary.summarize([]).spokenSummary == "No agents running")
    #expect(NotchAgentSummary.summarize([row(.idle)]).spokenSummary == "1 agent")
}

// MARK: - Window grouping

@Test("NotchWindowAgents.build: agents group under their open Ensemble; the rest are loose")
func windowAgentsGroupByBoard() {
    let boardA = UUID()
    let boardB = UUID()
    let closedBoard = UUID()
    let inA = UUID()
    let loose = UUID()
    let orphan = UUID()
    let groups = NotchWindowAgents.build(
        boards: [
            NotchBoardInput(id: boardA, title: "Alpha", cardCount: 4),
            NotchBoardInput(id: boardB, title: "Beta", cardCount: 1),
        ],
        terminals: [
            NotchTerminalInput(
                id: inA, title: "claude", cli: .claudeCode, status: .running,
                isProducingOutput: true, boardID: boardA, cardID: UUID()),
            NotchTerminalInput(id: loose, title: "codex", cli: .codex, status: .running),
            // Claims a board that is not open: it is listed as loose, never lost.
            NotchTerminalInput(
                id: orphan, title: "gemini", cli: .geminiCLI, status: .running,
                boardID: closedBoard),
            NotchTerminalInput(id: UUID(), title: "zsh", cli: nil, status: .running),
        ])
    #expect(groups.ensembles.map(\.title) == ["Alpha", "Beta"])
    #expect(groups.ensembles[0].agents.map(\.id) == [inA])
    #expect(groups.ensembles[0].summary.working == 1)
    #expect(groups.ensembles[1].agents.isEmpty)
    #expect(groups.ensembles[0].cardCount == 4)
    #expect(Set(groups.looseAgents.map(\.id)) == [loose, orphan])
    #expect(groups.allAgents.count == 3)
    #expect(!groups.isEmpty)
    #expect(NotchWindowAgents.empty.isEmpty)
}

// MARK: - Mascot

@Test("RafuMascotState: needs you outranks reply ready, which outranks running, then idle")
func mascotPriority() {
    #expect(RafuMascotState.resolve(agents: []).mood == .idle)
    #expect(RafuMascotState.resolve(agents: [row(.idle)]).label == "Agents are waiting")
    #expect(RafuMascotState.resolve(agents: []).label == "No agents running")
    #expect(RafuMascotState.resolve(agents: [row(.stopped)]).label == "No agents running")
    #expect(RafuMascotState.resolve(agents: [row(.working), row(.idle)]).mood == .working)
    let reply = row(.replyReady)
    let replyState = RafuMascotState.resolve(agents: [row(.working), reply])
    #expect(replyState.mood == .replyReady)
    #expect(replyState.replyID == reply.id)
    let needs = RafuMascotState.resolve(agents: [row(.working), reply, row(.needsYou)])
    #expect(needs.mood == .needsYou)
    #expect(needs.replyID == nil)
}

@Test("RafuMascotMood: every mood has distinct animated and still asset names")
func mascotAssetNames() {
    var names: Set<String> = []
    for mood in RafuMascotMood.allCases {
        names.insert(mood.assetName(still: false))
        names.insert(mood.assetName(still: true))
        #expect(mood.assetName(still: true).hasSuffix("-still"))
    }
    #expect(names.count == RafuMascotMood.allCases.count * 2)
}

@Test("MascotBounceLedger: a reply bounces once; the ledger stays bounded")
func bounceLedgerClaimsOnce() {
    var ledger = MascotBounceLedger()
    let id = UUID()
    let first = ledger.claim(id)
    let second = ledger.claim(id)
    #expect(first)
    #expect(!second)
    for _ in 0..<(MascotBounceLedger.capacity * 2) { _ = ledger.claim(UUID()) }
    #expect(ledger.claimed.count == MascotBounceLedger.capacity)
    // Evicted long ago, so the same id would bounce again; acceptable.
    let evicted = ledger.claim(id)
    #expect(evicted)
}

@Test("Resources/Mascot: an animated and a still SVG exists for every mood")
func mascotSVGAssetsExist() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/Mascot")
    for mood in RafuMascotMood.allCases {
        for still in [false, true] {
            let file = root.appending(path: mood.assetName(still: still) + ".svg")
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("<svg"))
            // The still variants carry no animation: Reduce Motion safe.
            if still { #expect(!text.contains("@keyframes")) }
        }
    }
}
