import Foundation
import Testing

@testable import RafuCore

@Suite("Hidden meeting agent: summary reply")
struct MeetingSummaryReplyParserTests {
    private static let known: Set<MeetingTurnID> = [MeetingTurnID(1), MeetingTurnID(2)]
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ text: String) throws(MeetingSummaryReplyParser.Problem)
        -> MeetingSummaryNotes
    {
        try MeetingSummaryReplyParser.parse(
            text, knownTurns: Self.known, cli: .codex, date: Self.date, textRevision: 4)
    }

    private static let valid =
        #"{"title": "Quokka launch plan", "summary": "The team ships on March 14 [t2]. Also [t9].", "decisions": [{"text": "Ship on March 14", "owner": null, "turns": ["t2", "t9"]}], "actionItems": [{"text": "Send the notes", "owner": "Priya", "turns": ["t1"]}]}"#

    @Test("A valid reply gives the notes; an unknown turn id is dropped")
    func valid() throws {
        let notes = try parse(Self.valid)
        #expect(notes.title == "Quokka launch plan")
        #expect(notes.summaryMarkdown == "The team ships on March 14 [t2]. Also [t9].")
        #expect(
            notes.decisions == [
                MeetingSummaryItem(text: "Ship on March 14", citations: [MeetingTurnID(2)])
            ])
        #expect(
            notes.actionItems == [
                MeetingSummaryItem(
                    text: "Send the notes", owner: "Priya", citations: [MeetingTurnID(1)])
            ])
        #expect(notes.citations == [MeetingTurnID(2), MeetingTurnID(1)])
        #expect(notes.cli == .codex)
        #expect(notes.textRevision == 4)
        #expect(notes.date == Self.date)
        #expect(notes.schema == MeetingSummaryNotes.currentSchema)
    }

    @Test("One code fence is allowed; missing lists are empty")
    func fenceAndMissingLists() throws {
        let notes = try parse("```json\n{\"title\": \"Sync\", \"summary\": \"Short.\"}\n```")
        #expect(notes.title == "Sync")
        #expect(notes.decisions.isEmpty)
        #expect(notes.actionItems.isEmpty)
        #expect(notes.citations.isEmpty)
    }

    @Test("Control characters are removed and the title is one line")
    func controlCharacters() throws {
        let notes = try parse(
            #"{"title": "Plan\u0007\nfor‮ Q3", "summary": "Line one\u0000\nLine two\tend", "decisions": [{"text": "A\nB", "owner": " Ann\u0001 "}]}"#
        )
        #expect(notes.title == "Plan for Q3")
        #expect(notes.summaryMarkdown == "Line one\nLine two end")
        #expect(notes.decisions.first?.text == "A B")
        #expect(notes.decisions.first?.owner == "Ann")
    }

    @Test("A reply that is not one JSON object, has wrong types or misses the title fails")
    func badShapes() {
        let bad = [
            "not json",
            "Here: " + Self.valid,
            "[]",
            #"{"summary": "x"}"#,
            #"{"title": "", "summary": "x"}"#,
            #"{"title": "T", "summary": ""}"#,
            #"{"title": 3, "summary": "x"}"#,
            #"{"title": "T", "summary": ["x"]}"#,
            #"{"title": "T", "summary": "x", "decisions": "none"}"#,
            #"{"title": "T", "summary": "x", "decisions": [{"owner": "A"}]}"#,
            #"{"title": "T", "summary": "x", "decisions": [{"text": "A", "owner": 3}]}"#,
            #"{"title": "T", "summary": "x", "decisions": [{"text": "A", "turns": "t1"}]}"#,
            #"{"title": "T", "summary": "x", "decisions": [{"text": "A", "turns": [1]}]}"#,
        ]
        for text in bad {
            #expect(throws: MeetingSummaryReplyParser.Problem.failed, "\(text)") {
                try parse(text)
            }
        }
    }

    @Test("Each bound is enforced")
    func bounds() throws {
        let longTitle = String(repeating: "a", count: 81)
        let longSummary = String(repeating: "a", count: 8 * 1_024 + 1)
        let longItem = String(repeating: "a", count: 401)
        let longOwner = String(repeating: "a", count: 81)
        let items = Array(repeating: #"{"text": "x"}"#, count: 21).joined(separator: ", ")
        let bad = [
            #"{"title": "\#(longTitle)", "summary": "x"}"#,
            #"{"title": "T", "summary": "\#(longSummary)"}"#,
            #"{"title": "T", "summary": "x", "decisions": [{"text": "\#(longItem)"}]}"#,
            #"{"title": "T", "summary": "x", "actionItems": [{"text": "x", "owner": "\#(longOwner)"}]}"#,
            #"{"title": "T", "summary": "x", "actionItems": [\#(items)]}"#,
        ]
        for text in bad {
            #expect(throws: MeetingSummaryReplyParser.Problem.failed) { try parse(text) }
        }
        let twenty = Array(repeating: #"{"text": "x"}"#, count: 20).joined(separator: ", ")
        let notes = try parse(
            #"{"title": "\#(String(repeating: "a", count: 80))", "summary": "x", "decisions": [\#(twenty)]}"#
        )
        #expect(notes.decisions.count == 20)
    }
}
