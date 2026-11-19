import Foundation
import Testing

@testable import RafuApp

@Suite("Ensembles navigator rows")
struct CanvasNavigatorModelTests {
    @Test("Saved and open Ensembles merge by ID and sort by natural title")
    func boardUnion() throws {
        let firstID = CanvasID(
            rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let secondID = CanvasID(
            rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        let ten = CanvasID()
        let file = CanvasID()
        let now = Date(timeIntervalSince1970: 7_200)
        let library = [
            CanvasSummary(id: ten, title: "Plan 10", revision: 1, cardCount: 2),
            CanvasSummary(
                id: secondID, title: "Old title", revision: 2, cardCount: 1, modified: now - 3_600),
            CanvasSummary(id: firstID, title: "Plan 2", revision: 1, cardCount: 2),
        ]
        let rows = CanvasNavigatorModel.boardRows(
            library: library,
            open: [
                secondID: .init(id: secondID, title: "Plan 2", cardCount: 6),
                file: .init(
                    id: file, title: "design", cardCount: 3, filePath: "docs/design.rafuensemble"),
            ],
            current: secondID, openElsewhere: [ten], now: now)
        #expect(rows.map(\.id) == [file, firstID, secondID, ten])

        let fileRow = try #require(rows.first)
        #expect(fileRow.isOpen && fileRow.isFileBound && !fileRow.isCurrent)
        #expect(fileRow.caption == "docs/design.rafuensemble")
        #expect(fileRow.summary == nil)
        #expect(CanvasNavigatorModel.boardAccessibilityValue(fileRow) == "Open, 3 cards")

        let saved = rows[1]
        #expect(!saved.isOpen && !saved.isCurrent && !saved.isOpenElsewhere)
        #expect(saved.trailing == nil)
        #expect(CanvasNavigatorModel.boardAccessibilityValue(saved) == "Saved, 2 cards")

        let current = rows[2]
        #expect(current.isOpen && current.isCurrent && !current.isOpenElsewhere)
        #expect(current.caption == "6 cards · edited 1 h ago")
        #expect(current.trailing == "Open")
        #expect(CanvasNavigatorModel.boardAccessibilityValue(current) == "Current, open, 6 cards")

        let elsewhere = rows[3]
        #expect(!elsewhere.isOpen && !elsewhere.isCurrent && elsewhere.isOpenElsewhere)
        #expect(elsewhere.trailing == "In another window")
        #expect(CanvasNavigatorModel.boardAccessibilityValue(elsewhere) == "Open in another window")
    }

    @Test("Node rows keep board order, omit drawings, and describe live status")
    func nodes() throws {
        let group = TerminalGroupID()
        let terminal = CanvasCard(title: "Runner", content: .terminal(groupID: group))
        let text = CanvasCard(title: "Drawing", content: .text(CanvasText(text: "Label")))
        let note = CanvasCard(title: "Agenda", content: .note(snapshot: ""))
        let index = CanvasBoardSearchIndex(
            cards: [terminal, text, note], connections: [.init(from: terminal.id, to: note.id)]
        ) { _ in CanvasSearchTerminalInfo(providerName: "Claude Code") }
        let rows = CanvasNavigatorModel.nodeRows(
            items: index.items, terminalGroups: [terminal.id: group])
        #expect(rows.map(\.id) == [terminal.id, note.id])
        let agent = try #require(rows.first)
        #expect(agent.terminalGroupID == group)
        #expect(agent.symbol == terminal.content.symbol)
        #expect(agent.caption == "Terminal · Claude Code · 1 link")
        #expect(
            CanvasNavigatorModel.nodeAccessibilityValue(agent, status: .needsYou(.input))
                == "Terminal, Claude Code, Needs input")
        #expect(CanvasNavigatorModel.nodeAccessibilityValue(rows[1], status: nil) == "Note")
    }

    @Test("Only an agent status that needs attention has a visible word")
    func statusWords() {
        #expect(CanvasNavigatorModel.statusWord(.needsYou(.input)) == "Needs input")
        #expect(CanvasNavigatorModel.statusWord(.needsYou(.approval)) == "Needs approval")
        #expect(CanvasNavigatorModel.statusWord(.failed) == "Failed")
        #expect(CanvasNavigatorModel.statusWord(.stopped) == "Stopped")
        let quiet: [AgentCardStatus?] = [nil, .working, .doneUnread, .done, .inactive]
        #expect(quiet.allSatisfy { CanvasNavigatorModel.statusWord($0) == nil })
    }

    @Test("A board and a node with the same UUID have distinct selection tags")
    func selectionTags() {
        let uuid = UUID()
        let board = CanvasNavigatorModel.selectionID(board: CanvasID(rawValue: uuid))
        let node = CanvasNavigatorModel.selectionID(node: CanvasCardID(rawValue: uuid))
        #expect(board == "board:\(uuid.uuidString)")
        #expect(node == "node:\(uuid.uuidString)")
    }
}
