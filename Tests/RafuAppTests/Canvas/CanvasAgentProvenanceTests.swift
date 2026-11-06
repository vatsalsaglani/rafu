import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Canvas agent provenance")
struct CanvasAgentProvenanceTests {
    private func record(
        card: CanvasCardID = CanvasCardID(), date: Date, stamp: UInt64 = 4
    ) -> CanvasAgentProvenanceRecord {
        CanvasAgentProvenanceRecord(
            boardID: CanvasID(), cardID: card, agentName: "Claude", provider: "claude",
            action: CanvasAgentTool.noteCreate.actionTitle, verb: "added", date: date,
            changeStamp: stamp)
    }

    private func call(_ tool: CanvasAgentTool, _ arguments: [String: Any] = [:]) throws
        -> CanvasAgentToolCall
    {
        try CanvasAgentToolCall.parse(tool: tool.rawValue, arguments: arguments)
    }

    @Test("A record shows for 8 s, the notice's own lifetime")
    func lifetime() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let mark = record(date: start)
        #expect(CanvasAgentProvenanceRecord.lifetime == 8)
        #expect(mark.isVisible(now: start))
        #expect(mark.isVisible(now: start.addingTimeInterval(7.9)))
        #expect(!mark.isVisible(now: start.addingTimeInterval(8)))
        #expect(mark.byline == "Added by Claude")
        #expect(mark.cli == .claudeCode)
    }

    @Test("Undo is honest only while the stamp has not moved")
    func undoStamp() {
        let mark = record(date: Date(), stamp: 7)
        #expect(mark.canUndo(currentStamp: 7))
        #expect(!mark.canUndo(currentStamp: 8))
    }

    @Test("Each tool that changes one card has its verb; the others have none")
    func verbs() throws {
        #expect(CanvasAgentNoticeText.verb(for: try call(.noteCreate, ["title": "A"])) == "added")
        var created = try call(.noteCreate, ["title": "A"])
        created.tool = .nodeCreate
        #expect(CanvasAgentNoticeText.verb(for: created) == "added")
        created.tool = .edgeCreate
        #expect(CanvasAgentNoticeText.verb(for: created) == nil)
        let node = UUID().uuidString
        #expect(
            CanvasAgentNoticeText.verb(for: try call(.nodeUpdate, ["node_id": node, "x": 10.0]))
                == "moved")
        #expect(
            CanvasAgentNoticeText.verb(
                for: try call(.nodeUpdate, ["node_id": node, "width": 300.0, "x": 4.0]))
                == "resized")
        #expect(
            CanvasAgentNoticeText.verb(for: try call(.nodeUpdate, ["node_id": node, "title": "B"]))
                == "renamed")
        #expect(
            CanvasAgentNoticeText.verb(
                for: try call(.noteWrite, ["node_id": node, "text": "x", "mode": "append"]))
                == "wrote")
        #expect(CanvasAgentNoticeText.verb(for: try call(.nodeRemove, ["node_id": node])) == nil)
        #expect(CanvasAgentNoticeText.verb(for: try call(.ensembleDescribe)) == nil)
    }

    @Test("The notice line names the agent, the verb and the card only")
    func noticeLine() {
        #expect(
            CanvasAgentNoticeText.line(agent: "Claude", verb: "added", cardTitle: "Note 3")
                == "Claude added Note 3")
        #expect(
            CanvasAgentNoticeText.line(agent: "Codex", verb: "moved", cardTitle: "Terminal\n2")
                == "Codex moved Terminal 2")
        #expect(CanvasAgentNoticeText.vendor(provider: "codex") == "Codex")
        #expect(CanvasAgentNoticeText.vendor(provider: "claude") == "Claude")
    }

    @Test("The store keeps 200 records and returns the newest for a card")
    func storeCap() {
        let store = CanvasAgentProvenanceStore()
        let card = CanvasCardID()
        let now = Date()
        for index in 0..<210 {
            store.record(record(date: now.addingTimeInterval(Double(index) / 1_000)))
        }
        #expect(store.records.count == CanvasAgentProvenanceStore.cap)
        store.record(record(card: card, date: now, stamp: 1))
        store.record(record(card: card, date: now.addingTimeInterval(0.5), stamp: 2))
        #expect(store.record(for: card, now: now.addingTimeInterval(1))?.changeStamp == 2)
        #expect(store.record(for: card, now: now.addingTimeInterval(9)) == nil)
        store.prune(now: now.addingTimeInterval(9))
        #expect(store.records.isEmpty)
    }

    @Test("The Undo gate holds while the cards and links are unchanged")
    func undoGate() {
        let card = CanvasCard(title: "A", content: .note(snapshot: ""))
        let gate = CanvasAgentUndoGate(boardID: CanvasID(), cards: [card], connections: [])
        #expect(gate.allows(cards: [card], connections: []))
        var moved = card
        moved.rect.x += 10
        #expect(!gate.allows(cards: [moved], connections: []))
    }
}
