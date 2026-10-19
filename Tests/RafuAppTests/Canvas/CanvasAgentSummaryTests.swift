import Testing

@testable import RafuApp

private func terminalCard(_ title: String) -> CanvasCard {
    CanvasCard(title: title, content: .terminal(groupID: TerminalGroupID()))
}

@Suite("Canvas agent summary")
struct CanvasAgentSummaryTests {
    @Test("Counts agents, working, and lists needsYou/failed cards in board order")
    func countsAndOrdering() {
        let working1 = terminalCard("Alpha")
        let working2 = terminalCard("Bravo")
        let needsApproval = terminalCard("Charlie")
        let needsInput = terminalCard("Delta")
        let failed = terminalCard("Echo")
        let done = terminalCard("Foxtrot")
        let shell = terminalCard("Golf")
        let cards = [working1, working2, needsApproval, needsInput, failed, done, shell]
        let statuses: [CanvasCardID: AgentCardStatus] = [
            working1.id: .working, working2.id: .working, needsApproval.id: .needsYou(.approval),
            needsInput.id: .needsYou(.input), failed.id: .failed, done.id: .done,
        ]

        let summary = CanvasAgentSummaryItem(cards: cards) { statuses[$0.id] }

        #expect(summary.agents == 6)
        #expect(summary.working == 2)
        #expect(summary.needsYou.map(\.title) == ["Charlie", "Delta"])
        #expect(summary.failed.map(\.title) == ["Echo"])
    }

    @Test("No agents at all means empty everywhere")
    func empty() {
        let cards = [terminalCard("Shell one"), terminalCard("Shell two")]
        let summary = CanvasAgentSummaryItem(cards: cards) { _ in nil }
        #expect(summary.agents == 0)
        #expect(summary.working == 0)
        #expect(summary.needsYou.isEmpty)
        #expect(summary.failed.isEmpty)
    }

    @Test("Inactive, done, doneUnread, and stopped count toward agents but neither list")
    func quietStatesDoNotListAnywhere() {
        let inactive = terminalCard("Inactive one")
        let stopped = terminalCard("Stopped one")
        let doneUnread = terminalCard("Unread one")
        let cards = [inactive, stopped, doneUnread]
        let statuses: [CanvasCardID: AgentCardStatus] = [
            inactive.id: .inactive, stopped.id: .stopped, doneUnread.id: .doneUnread,
        ]

        let summary = CanvasAgentSummaryItem(cards: cards) { statuses[$0.id] }

        #expect(summary.agents == 3)
        #expect(summary.working == 0)
        #expect(summary.needsYou.isEmpty)
        #expect(summary.failed.isEmpty)
    }
}
