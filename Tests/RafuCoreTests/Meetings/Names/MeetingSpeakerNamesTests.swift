import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting speaker names and edit list")
struct MeetingSpeakerNamesTests {
    private typealias Words = MeetingTestWords

    private func turns() -> [MeetingTurn] {
        [
            Words.turn(1, .me, .me, 0, "so what do you think"),
            Words.turn(2, .them, .speaker(2), 4, "the budget is due friday"),
            Words.turn(3, .them, .speaker(1), 9, "i will send it today"),
            Words.turn(4, .me, .me, 10, "i will send it today", isEcho: true),
            Words.turn(5, .them, .speaker(2), 12, "thanks"),
        ]
    }

    @Test("Rename: every turn of the speaker shows the name and the ids stay")
    func rename() {
        let names = MeetingSpeakerNames()
        let edit = names.rename(.speaker(2), to: "Priya")
        #expect(edit == .renameSpeaker(label: .speaker(2), name: "Priya", source: .user))

        let shown = MeetingSpeakerNames.apply([edit], to: turns())
        #expect(shown.map(\.speakerName) == ["Me", "Priya", "Speaker 1", "Me", "Priya"])
        #expect(shown.map(\.id.text) == ["t1", "t2", "t3", "t4", "t5"])
        #expect(shown.map(\.turn) == turns())
    }

    @Test("The newest rename of a label wins; an empty name takes it away")
    func replayOrder() {
        let first = MeetingSpeakerNames().rename(.speaker(2), to: "Priya")
        let second = MeetingSpeakerNames().rename(.speaker(2), to: "  Priya Rao ")
        #expect(
            MeetingSpeakerNames.replaying([first, second]).name(for: .speaker(2)) == "Priya Rao")
        let cleared = MeetingSpeakerNames().rename(.speaker(2), to: "   ")
        let none = MeetingSpeakerNames.replaying([first, second, cleared])
        #expect(none.name(for: .speaker(2)) == nil)
        #expect(none.displayName(for: .speaker(2)) == "Speaker 2")
        // The same edits always give the same result.
        #expect(
            MeetingSpeakerNames.replaying([first, second])
                == MeetingSpeakerNames.replaying([first, second]))
    }

    @Test("A long name is cut to the limit")
    func longName() {
        let name = String(repeating: "x", count: 300)
        let edit = MeetingSpeakerNames().rename(.them, to: name)
        #expect(
            MeetingSpeakerNames.replaying([edit]).name(for: .them)?.count
                == MeetingSpeakerNames.maximumNameLength)
    }

    @Test("An agent suggestion never changes a name")
    func agentNeverApplies() {
        let suggestions = MeetingSpeakerNames.agentSuggestions(
            [.speaker(1): "Sam", .speaker(2): "  ", .me: "Vatsal"],
            evidence: [.speaker(1): [MeetingTurnID(9), MeetingTurnID(3)]])
        #expect(
            suggestions == [
                MeetingSpeakerNameSuggestion(
                    label: .speaker(1), name: "Sam",
                    source: .agent(evidence: [MeetingTurnID(3), MeetingTurnID(9)]))
            ])
        // Nothing here applied it.
        #expect(MeetingSpeakerNames.replaying([]).names.isEmpty)

        // Even an agent-sourced edit in a stored list changes nothing.
        let agentEdit = MeetingEdit.renameSpeaker(
            label: .speaker(1), name: "Sam", source: .agent(evidence: [MeetingTurnID(3)]))
        var list = MeetingEditList()
        list.append(agentEdit)
        #expect(list.speakerNames.names.isEmpty)
        #expect(list.display(turns())[2].speakerName == "Speaker 1")
        #expect(MeetingSpeakerNames.apply([agentEdit], to: turns())[2].speakerName == "Speaker 1")

        // A user edit after it does.
        list.append(MeetingSpeakerNames().rename(.speaker(1), to: "Sam"))
        #expect(list.speakerNames.name(for: .speaker(1)) == "Sam")
    }

    @Test("Names to check: far labels with no confirmed name, in order of appearance")
    func namesToCheck() {
        let names = MeetingSpeakerNames.replaying([
            MeetingSpeakerNames().rename(.speaker(2), to: "Priya")
        ])
        #expect(names.namesToCheck(in: turns()) == [.speaker(1)])
        #expect(MeetingSpeakerNames().namesToCheck(in: turns()) == [.speaker(2), .speaker(1)])
        #expect(
            MeetingSpeakerNames().namesToCheck(in: [Words.turn(1, .them, .them, 0, "hello")]) == [
                .them
            ])
        #expect(MeetingSpeakerNames().namesToCheck(in: []).isEmpty)
        #expect(
            names.confirmedSuggestions == [
                MeetingSpeakerNameSuggestion(label: .speaker(2), name: "Priya", source: .user)
            ])
    }

    @Test("Names are stored as an object keyed by the label text")
    func codable() throws {
        let names = MeetingSpeakerNames(names: [.speaker(2): "Priya", .them: "Sam"])
        let data = try JSONEncoder().encode(names)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["speaker-2": "Priya", "them": "Sam"])
        #expect(try JSONDecoder().decode(MeetingSpeakerNames.self, from: data) == names)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MeetingSpeakerNames.self, from: Data(#"{"nobody":"x"}"#.utf8))
        }
    }

    // MARK: Edit list

    @Test("The edit list replays text corrections and echo visibility")
    func editListReplay() {
        var list = MeetingEditList()
        list.append(.correctText(turn: MeetingTurnID(2), text: " The budget is due on Friday "))
        list.append(.correctText(turn: MeetingTurnID(99), text: "no such turn"))
        list.append(.correctText(turn: MeetingTurnID(5), text: "   "))
        list.append(.setEchoShown(turn: MeetingTurnID(4), shown: true))
        list.append(.setEchoShown(turn: MeetingTurnID(1), shown: false))

        let shown = list.display(turns())
        #expect(shown[1].turn.text == "The budget is due on Friday")
        #expect(shown[4].turn.text == "thanks")
        #expect(shown.count == 5)
        #expect(!shown[3].isHidden)
        // A hide edit on a turn that is not echo has no effect.
        #expect(!shown[0].isHidden)
        // The stored text is not the input of the correction.
        #expect(turns()[1].text == "the budget is due friday")
    }

    @Test("An echo turn is hidden until it is shown, and hidden again by a later edit")
    func echoVisibility() {
        var list = MeetingEditList()
        #expect(list.display(turns())[3].isHidden)
        list.append(.setEchoShown(turn: MeetingTurnID(4), shown: true))
        #expect(!list.display(turns())[3].isHidden)
        list.append(.setEchoShown(turn: MeetingTurnID(4), shown: false))
        #expect(list.display(turns())[3].isHidden)
        #expect(list.display(turns())[3].turn.text == "i will send it today")
    }

    @Test("Undo removes the newest edit and returns it")
    func undo() {
        var list = MeetingEditList()
        #expect(list.undoLast() == nil)
        let rename = MeetingSpeakerNames().rename(.speaker(2), to: "Priya")
        let correction = MeetingEdit.correctText(turn: MeetingTurnID(2), text: "Fixed")
        list.append(rename)
        list.append(correction)
        #expect(list.undoLast() == correction)
        #expect(list.edits == [rename])
        #expect(list.display(turns())[1].turn.text == "the budget is due friday")
        #expect(list.display(turns())[1].speakerName == "Priya")
        #expect(list.undoLast() == rename)
        #expect(list.isEmpty)
        #expect(list.display(turns())[1].speakerName == "Speaker 2")
    }

    @Test("The edit list round-trips through JSON")
    func editListCodable() throws {
        var list = MeetingEditList()
        list.append(MeetingSpeakerNames().rename(.speaker(2), to: "Priya"))
        list.append(
            .renameSpeaker(
                label: .speaker(1), name: "Sam", source: .agent(evidence: [MeetingTurnID(3)])))
        list.append(.correctText(turn: MeetingTurnID(2), text: "Fixed"))
        list.append(.setEchoShown(turn: MeetingTurnID(4), shown: true))
        let data = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(MeetingEditList.self, from: data) == list)
    }

    @Test("Replaying the edits twice gives the same display")
    func displayIsPure() {
        var list = MeetingEditList()
        list.append(MeetingSpeakerNames().rename(.speaker(2), to: "Priya"))
        list.append(.setEchoShown(turn: MeetingTurnID(4), shown: true))
        #expect(list.display(turns()) == list.display(turns()))
        #expect(turns() == turns())
    }
}
