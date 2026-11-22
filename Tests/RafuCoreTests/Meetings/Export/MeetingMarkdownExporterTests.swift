import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting export: Markdown")
struct MeetingMarkdownExporterTests {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt
    private static let options = MeetingExportOptions(timeZone: utc)

    private static func summary(title: String = "Planning") -> MeetingSummaryRecord {
        MeetingSummaryRecord(
            id: MeetingID(uuidString: "11111111-2222-3333-4444-555555555555") ?? MeetingID(),
            title: title, startDate: LibrarySample.startDate, duration: 900, state: .ready)
    }

    private static let turns: [MeetingTurn] = [
        LibrarySample.turn(1, .me, start: 3, text: "Hello everyone"),
        LibrarySample.turn(2, .speaker(2), start: 747, text: "Hi, I am here"),
        LibrarySample.turn(3, .me, start: 750, text: "Hi I am here", echo: true),
        LibrarySample.turn(4, .me, start: 3_725, text: "Line one\nline two"),
    ]

    @Test("A meeting with no conversation: header, then the transcript, with echo turns left out")
    func goldenTranscriptOnly() {
        let document = MeetingDocument(summary: Self.summary(), turns: Self.turns)
        let expected = """
            # Planning

            - **Date:** 2026-11-23 10:15 +00:00
            - **Length:** 15:00
            - **Speakers:** Me, Speaker 2

            ## Transcript

            **[t1 00:03] Me:** Hello everyone

            **[t2 12:27] Speaker 2:** Hi, I am here

            **[t4 1:02:05] Me:** Line one line two

            """
        #expect(MeetingMarkdownExporter.export(document, options: Self.options) == expected)
    }

    @Test("A renamed speaker shows by name in the header and on each line")
    func goldenRenamedSpeaker() {
        let document = MeetingDocument(
            summary: Self.summary(), turns: Array(Self.turns.prefix(2)),
            speakerNames: [.speaker(2): "Priya", .me: "Vatsal"])
        let expected = """
            # Planning

            - **Date:** 2026-11-23 10:15 +00:00
            - **Length:** 15:00
            - **Speakers:** Vatsal, Priya

            ## Transcript

            **[t1 00:03] Vatsal:** Hello everyone

            **[t2 12:27] Priya:** Hi, I am here

            """
        #expect(MeetingMarkdownExporter.export(document, options: Self.options) == expected)
    }

    @Test("A conversation shows the questions, the answers and the citations as t9 12:27")
    func goldenWithConversation() {
        let conversation = [
            MeetingConversationEntry(
                date: LibrarySample.startDate, role: .question, text: "What did Priya say?"),
            MeetingConversationEntry(
                date: LibrarySample.startDate, role: .answer,
                text: "Priya said she is here.\n\nNothing else.", cli: .claudeCode,
                citations: [MeetingCitation(turn: MeetingTurnID(2), quote: "I am here")]),
            MeetingConversationEntry(
                date: LibrarySample.startDate, role: .question, text: "Anything else?"),
            MeetingConversationEntry(
                date: LibrarySample.startDate, role: .answer, text: "No.", cli: .codex),
        ]
        let document = MeetingDocument(
            summary: Self.summary(), turns: Array(Self.turns.prefix(2)),
            speakerNames: [.speaker(2): "Priya"], conversation: conversation)
        let expected = """
            # Planning

            - **Date:** 2026-11-23 10:15 +00:00
            - **Length:** 15:00
            - **Speakers:** Me, Priya

            ## Conversation

            **Question:** What did Priya say?

            **Answer (Claude Code):**

            > Priya said she is here.
            >
            > Nothing else.
            >
            > Sources:
            > - t2 12:27 "I am here"

            **Question:** Anything else?

            **Answer (Codex):**

            > No.

            ## Transcript

            **[t1 00:03] Me:** Hello everyone

            **[t2 12:27] Priya:** Hi, I am here

            """
        #expect(MeetingMarkdownExporter.export(document, options: Self.options) == expected)
    }

    @Test("Echo turns show, marked, only when the option is set")
    func goldenWithEchoTurns() {
        let document = MeetingDocument(summary: Self.summary(), turns: Array(Self.turns.prefix(3)))
        var options = Self.options
        options.includeEchoTurns = true
        let expected = """
            # Planning

            - **Date:** 2026-11-23 10:15 +00:00
            - **Length:** 15:00
            - **Speakers:** Me, Speaker 2

            ## Transcript

            **[t1 00:03] Me:** Hello everyone

            **[t2 12:27] Speaker 2:** Hi, I am here

            **[t3 12:30] Me (echo):** Hi I am here

            """
        #expect(MeetingMarkdownExporter.export(document, options: options) == expected)
        let without = MeetingMarkdownExporter.export(document, options: Self.options)
        #expect(!without.contains("t3"))
        #expect(!without.contains("echo"))
    }

    @Test("An empty meeting says so")
    func goldenEmpty() {
        let document = MeetingDocument(summary: Self.summary(title: "Empty"), turns: [])
        let expected = """
            # Empty

            - **Date:** 2026-11-23 10:15 +00:00
            - **Length:** 15:00

            ## Transcript

            _No transcript._

            """
        #expect(MeetingMarkdownExporter.export(document, options: Self.options) == expected)
    }

    @Test("Titles and names cannot add Markdown structure")
    func escaping() {
        let document = MeetingDocument(
            summary: Self.summary(title: "# Plan *now*\n## Second"),
            turns: [LibrarySample.turn(1, .speaker(2), start: 3, text: "ok")],
            speakerNames: [.speaker(2): "A_B [x]"])
        let text = MeetingMarkdownExporter.export(document, options: Self.options)
        #expect(text.hasPrefix("# # Plan \\*now\\* ## Second\n"))
        #expect(text.contains("**[t1 00:03] A\\_B \\[x\\]:** ok"))
        // The title is one line, so no extra heading starts a line.
        #expect(text.split(separator: "\n").filter { $0.hasPrefix("# ") }.count == 1)
    }

    @Test("A citation to a turn that is not there keeps its id and has no time")
    func citationWithoutTurn() {
        let document = MeetingDocument(summary: Self.summary(), turns: [])
        let text = MeetingMarkdownExporter.citationText(
            MeetingCitation(turn: MeetingTurnID(9), quote: "x\ny"), document: document)
        #expect(text == "t9 \"x y\"")
    }

    @Test("The clock text counts minutes, then hours")
    func clockText() {
        #expect(MeetingClockText.text(0) == "00:00")
        #expect(MeetingClockText.text(747.9) == "12:27")
        #expect(MeetingClockText.text(3_599) == "59:59")
        #expect(MeetingClockText.text(3_600) == "1:00:00")
        #expect(MeetingClockText.text(-5) == "00:00")
        #expect(MeetingClockText.text(.infinity) == "00:00")
        #expect(MeetingClockText.text(1e30) == "277777:46:40")
    }

    @Test("The suggested file name is safe and has the date")
    func fileName() {
        #expect(
            MeetingMarkdownExporter.suggestedFileName(
                title: "Q4 plan / review: v2?", startDate: LibrarySample.startDate,
                timeZone: Self.utc) == "Q4 plan  review v2 2026-11-23.md")
        #expect(
            MeetingMarkdownExporter.suggestedFileName(
                title: "///", startDate: LibrarySample.startDate, timeZone: Self.utc)
                == "Meeting 2026-11-23.md")
        let long = MeetingMarkdownExporter.suggestedFileName(
            title: String(repeating: "a", count: 200), startDate: LibrarySample.startDate,
            timeZone: Self.utc)
        #expect(long.count == 60 + 1 + 10 + 3)
    }

    @Test("The store exports the same text the pure exporter makes, with edits applied")
    func storeExport() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "Planning", startDate: LibrarySample.startDate)
        var version = try await store.appendTurns(
            [
                LibrarySample.turn(1, .me, start: 3, text: "helo"),
                LibrarySample.turn(2, .speaker(2), start: 747, text: "Hi"),
                LibrarySample.turn(3, .me, start: 750, text: "Hi", echo: true),
            ], to: created.id, expectedVersion: 1)
        version = try await store.editTurnText(
            MeetingTurnID(1), to: "hello", in: created.id, expectedVersion: version)
        version = try await store.renameSpeaker(
            .speaker(2), to: "Priya", in: created.id, expectedVersion: version)
        version = try await store.setDuration(900, of: created.id, expectedVersion: version)
        _ = try await store.appendConversation(
            MeetingConversationEntry(
                date: LibrarySample.startDate, role: .answer, text: "Hi.", cli: .codex,
                citations: [MeetingCitation(turn: MeetingTurnID(2), quote: "Hi")]),
            to: created.id)

        let text = try await store.exportMarkdown(of: created.id, options: Self.options)
        let expected = """
            # Planning

            - **Date:** 2026-11-23 10:15 +00:00
            - **Length:** 15:00
            - **Speakers:** Me, Priya

            ## Conversation

            **Answer (Codex):**

            > Hi.
            >
            > Sources:
            > - t2 12:27 "Hi"

            ## Transcript

            **[t1 00:03] Me:** hello

            **[t2 12:27] Priya:** Hi

            """
        #expect(text == expected)
        // The contract method uses the defaults and returns Markdown too.
        let defaults = try await store.exportMarkdown(of: created.id)
        #expect(defaults.hasPrefix("# Planning\n"))
        #expect(!defaults.contains("(echo)"))
    }
}
