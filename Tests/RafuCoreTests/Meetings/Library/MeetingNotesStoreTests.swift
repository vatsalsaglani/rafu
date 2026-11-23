import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting library: summary notes, text revision and title origin")
struct MeetingNotesStoreTests {
    private static let defaultTitle = MeetingDefaultTitle.text(
        for: LibrarySample.startDate, timeZone: TimeZone(identifier: "UTC")!)

    private func notes(revision: Int, title: String = "Launch plan") -> MeetingSummaryNotes {
        MeetingSummaryNotes(
            title: title, summaryMarkdown: "Ship on March 14 [t1].",
            decisions: [MeetingSummaryItem(text: "Ship", citations: [MeetingTurnID(1)])],
            citations: [MeetingTurnID(1)], cli: .claudeCode,
            date: Date(timeIntervalSince1970: 1_800_000_000), textRevision: revision)
    }

    @Test("Notes round trip in notes.json with mode 0600 and count in the text size")
    func notesRoundTrip() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        #expect(try await store.summaryNotes(of: created.id) == nil)
        let before = try await store.sizeOnDisk(of: created.id).transcriptBytes

        let saved = notes(revision: 0)
        #expect(try await store.saveSummaryNotes(saved, for: created.id))
        #expect(try await store.summaryNotes(of: created.id) == saved)
        let file = fixture.file("notes.json", of: created.id)
        #expect(LibraryFixture.mode(of: file) == 0o600)
        #expect(try await store.sizeOnDisk(of: created.id).transcriptBytes > before)
        // The meeting version does not change.
        #expect(try await store.summary(of: created.id)?.version == created.version)
    }

    @Test("A notes file with another schema or damaged content reads as no notes")
    func wrongSchema() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        #expect(try await store.saveSummaryNotes(notes(revision: 0), for: created.id))
        let file = fixture.file("notes.json", of: created.id)
        let text = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#)
        try Data(text.utf8).write(to: file)
        #expect(try await store.summaryNotes(of: created.id) == nil)
        try Data("not json".utf8).write(to: file)
        #expect(try await store.summaryNotes(of: created.id) == nil)
    }

    @Test("A meeting.json from before the revision decodes as revision 0 with no title origin")
    func oldRecordDecodes() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let file = fixture.file("meeting.json", of: created.id)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("textRevision"))
        #expect(!text.contains("titleOrigin"))
        #expect(try await store.textRevision(of: created.id) == 0)
        #expect(try await store.summary(of: created.id)?.title == "A")
    }

    @Test("Replacing the turns raises the text revision; old notes cannot be saved")
    func revision() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        var version = try await store.appendTurns(
            [LibrarySample.turn(1)], to: created.id, expectedVersion: created.version)
        // Appending live turns does not change the revision.
        #expect(try await store.textRevision(of: created.id) == 0)
        version = try await store.replaceTurns(
            [LibrarySample.turn(1, text: "new")], in: created.id, expectedVersion: version)
        #expect(try await store.textRevision(of: created.id) == 1)
        _ = try await store.replaceTurns(
            [LibrarySample.turn(1, text: "newer")], in: created.id, expectedVersion: version)
        #expect(try await store.textRevision(of: created.id) == 2)

        #expect(try await !store.saveSummaryNotes(notes(revision: 1), for: created.id))
        #expect(try await store.summaryNotes(of: created.id) == nil)
        #expect(try await store.saveSummaryNotes(notes(revision: 2), for: created.id))
    }

    @Test("Each conversation line records the text revision")
    func conversationRevision() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let version = try await store.appendTurns(
            [LibrarySample.turn(1)], to: created.id, expectedVersion: created.version)
        try await store.appendConversation(
            MeetingConversationEntry(date: LibrarySample.startDate, role: .question, text: "q"),
            to: created.id)
        _ = try await store.replaceTurns(
            [LibrarySample.turn(1)], in: created.id, expectedVersion: version)
        try await store.appendConversation(
            MeetingConversationEntry(date: LibrarySample.startDate, role: .answer, text: "a"),
            to: created.id)
        let lines = try await store.conversation(of: created.id)
        #expect(lines.map(\.textRevision) == [0, 1])
    }

    @Test("The agent title replaces a default title, an empty title and its own title only")
    func titleRules() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()

        let byDefault = try await store.create(
            title: Self.defaultTitle, startDate: LibrarySample.startDate)
        #expect(try await store.applyGeneratedTitle("Launch plan", to: byDefault.id))
        #expect(try await store.summary(of: byDefault.id)?.title == "Launch plan")
        #expect(try await store.search("launch", limit: 10).map(\.meeting) == [byDefault.id])
        // A second summary may replace the agent's own title.
        #expect(try await store.applyGeneratedTitle("Launch plan v2", to: byDefault.id))
        #expect(try await store.summary(of: byDefault.id)?.title == "Launch plan v2")

        let untitled = try await store.create(title: "  ", startDate: LibrarySample.startDate)
        #expect(try await store.applyGeneratedTitle("Budget", to: untitled.id))
        #expect(try await store.summary(of: untitled.id)?.title == "Budget")

        let typed = try await store.create(
            title: "Weekly sync", startDate: LibrarySample.startDate)
        #expect(try await !store.applyGeneratedTitle("Budget", to: typed.id))
        #expect(try await store.summary(of: typed.id)?.title == "Weekly sync")

        // A rename by the user wins over each later agent title.
        let renamed = try await store.create(
            title: Self.defaultTitle, startDate: LibrarySample.startDate)
        _ = try await store.rename(
            renamed.id, title: Self.defaultTitle, expectedVersion: renamed.version)
        #expect(try await !store.applyGeneratedTitle("Budget", to: renamed.id))
        #expect(try await store.summary(of: renamed.id)?.title == Self.defaultTitle)

        // An agent title with a line break is cleaned to one line.
        let other = try await store.create(
            title: Self.defaultTitle, startDate: LibrarySample.startDate)
        #expect(try await store.applyGeneratedTitle("Plan\nfor Q3", to: other.id))
        #expect(try await store.summary(of: other.id)?.title == "Plan for Q3")
    }

    @Test("The default title form is known in each time zone and nothing else is")
    func defaultForm() {
        for zone in ["UTC", "Asia/Kolkata", "America/Los_Angeles"] {
            let title = MeetingDefaultTitle.text(
                for: LibrarySample.startDate, timeZone: TimeZone(identifier: zone)!)
            #expect(MeetingSummaryTitleRule.isDefaultForm(title), "\(title)")
        }
        for title in [
            "Meeting", "Meeting 23 Nov 2026", "Meeting 23 Nov 2026, 10:30 extra",
            "Meeting 23 Foo 2026, 10:30", "Meeting 123 Nov 2026, 10:30", "Weekly sync",
            "Meeting 23 Nov 2026 10:30",
        ] {
            #expect(!MeetingSummaryTitleRule.isDefaultForm(title), "\(title)")
        }
    }
}
