import Foundation
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Meeting detail presentation")
struct MeetingDetailPresentationTests {
    @Test("The overview uses the talk stats, leaves repeated lines out, and keeps turn refs")
    func overviewValues() {
        let summary = MeetingSummaryRecord(
            id: MeetingID(), title: "Weekly sync", startDate: Date(timeIntervalSince1970: 0),
            duration: 1_860, state: .ready)
        let turns = [
            MeetingTurn(
                id: MeetingTurnID(1), track: .me, speaker: .me, start: 0, end: 10, text: "a"),
            MeetingTurn(
                id: MeetingTurnID(2), track: .them, speaker: .speaker(2), start: 10, end: 40,
                text: "b"),
            MeetingTurn(
                id: MeetingTurnID(3), track: .me, speaker: .me, start: 40, end: 100, text: "c",
                isEcho: true),
            MeetingTurn(
                id: MeetingTurnID(4), track: .them, speaker: .speaker(1), start: 100, end: 101,
                text: "d"),
            MeetingTurn(
                id: MeetingTurnID(5), track: .me, speaker: .me, start: 105, end: 125, text: "e"),
        ]
        let overview = MeetingDetailPresentation.overview(
            document: MeetingDocument(summary: summary, turns: turns))
        #expect(overview.speakerLabels == [.me, .speaker(2), .speaker(1)])
        #expect(overview.stats.speakers.map(\.speechSeconds) == [30, 30, 1])
        // A speaker with less than 2 seconds is hidden; shares are of the
        // shown speakers only.
        #expect(overview.shownSpeakers.map(\.speaker) == [.me, .speaker(2)])
        #expect(overview.shownSpeakers.map(\.share) == [0.5, 0.5])
        #expect(overview.turnCount == 4)
        #expect(overview.repeatedCount == 1)
        #expect(overview.hasNumberedSpeakers)
        #expect(
            overview.turnRefs[MeetingTurnID(4)]
                == MeetingTurnRef(start: 100, speaker: .speaker(1)))
        #expect(overview.turnRefs.count == 5)
    }

    @Test("Answer segments: each citation form, and a mark outside the verified list")
    func answerSegments() {
        let t7 = MeetingTurnID(7)
        let t11 = MeetingTurnID(11)
        let t12 = MeetingTurnID(12)
        let verified: Set = [t7, t11, t12]
        #expect(
            MeetingDetailPresentation.answerSegments(text: "Ship Friday [t7].", verified: verified)
                == [.text("Ship Friday "), .citation(t7, isVerified: true), .text(".")])
        #expect(
            MeetingDetailPresentation.answerSegments(text: "[t11][t12]", verified: verified)
                == [.citation(t11, isVerified: true), .citation(t12, isVerified: true)])
        #expect(
            MeetingDetailPresentation.answerSegments(text: "[t7] [t11]", verified: verified)
                == [.citation(t7, isVerified: true), .text(" "), .citation(t11, isVerified: true)])
        for range in ["[t11–t12]", "[t11-t12]", "[t11 – t12]"] {
            #expect(
                MeetingDetailPresentation.answerSegments(text: range, verified: verified)
                    == [.citation(t11, isVerified: true), .citation(t12, isVerified: true)])
        }
        #expect(
            MeetingDetailPresentation.answerSegments(text: "See [t99]", verified: verified)
                == [.text("See "), .citation(MeetingTurnID(99), isVerified: false)])
        // Other bracket text stays text.
        #expect(
            MeetingDetailPresentation.answerSegments(text: "[note] [t] [x1]", verified: verified)
                == [.text("[note] [t] [x1]")])
    }

    @Test("Citations become labelled links; unverified marks are dropped; chips are distinct")
    func citationRewrite() {
        let refs: [MeetingTurnID: MeetingTurnRef] = [
            MeetingTurnID(2): MeetingTurnRef(start: 133, speaker: .speaker(1)),
            MeetingTurnID(5): MeetingTurnRef(start: 3_725, speaker: .me),
        ]
        let names = MeetingSpeakerNames(names: [.speaker(1): "Shilpa"])
        let verified: Set = [MeetingTurnID(2), MeetingTurnID(5)]
        let markdown = MeetingDetailPresentation.answerMarkdown(
            "**Friday** [t2]. Not [t9]. Owner [t5][t2].", verified: verified, refs: refs,
            names: names)
        #expect(
            markdown
                == "**Friday** [02:13](rafu-meeting-turn:t2). Not . Owner [1:02:05](rafu-meeting-turn:t5), [02:13](rafu-meeting-turn:t2)."
        )
        #expect(!markdown.contains("[t"))
        let chips = MeetingDetailPresentation.citationChips(
            in: "[t2] [t9] [t5] [t2]", verified: verified, refs: refs, names: names)
        #expect(chips.map(\.label) == ["02:13 Shilpa", "1:02:05 Me"])
        #expect(
            chips.first?.accessibilityLabel == "Show the line at 2 minutes 13 seconds, Shilpa")
        // A verified mark whose turn is not in the meeting gives nothing.
        #expect(
            MeetingDetailPresentation.answerMarkdown(
                "[t2]", verified: [MeetingTurnID(2)], refs: [:], names: names) == "")
        // Streamed text drops every mark until the answer is checked.
        #expect(MeetingDetailPresentation.streamingMarkdown("Yes [t2].") == "Yes .")
    }

    @Test("Side-by-side citations get a space and a comma, never run together")
    func citationSpacing() {
        let refs: [MeetingTurnID: MeetingTurnRef] = [
            MeetingTurnID(3): MeetingTurnRef(start: 6, speaker: .me),
            MeetingTurnID(4): MeetingTurnRef(start: 10, speaker: .me),
        ]
        let verified: Set = [MeetingTurnID(3), MeetingTurnID(4)]
        func render(_ text: String) -> String {
            MeetingDetailPresentation.answerMarkdown(
                text, verified: verified, refs: refs, names: MeetingSpeakerNames())
        }
        let both = "[00:06](rafu-meeting-turn:t3), [00:10](rafu-meeting-turn:t4)"
        #expect(render("up to[t3][t4]. So") == "up to \(both). So")
        #expect(render("up to [t3] [t4]. So") == "up to \(both). So")
        #expect(render("(see [t3])") == "(see [00:06](rafu-meeting-turn:t3))")
        #expect(render("[t3] then") == "[00:06](rafu-meeting-turn:t3) then")
    }

    @Test("A speaker name cannot make a link or formatting in a citation label")
    func citationLabelEscaping() {
        let refs = [MeetingTurnID(1): MeetingTurnRef(start: 0, speaker: .speaker(1))]
        let names = MeetingSpeakerNames(names: [.speaker(1): "Eve](https://evil.example) [x"])
        let markdown = MeetingDetailPresentation.answerMarkdown(
            "[t1]", verified: [MeetingTurnID(1)], refs: refs, names: names)
        // The inline link carries the time only; the name is not in it.
        #expect(markdown == "[00:00](rafu-meeting-turn:t1)")
        #expect(
            MeetingDetailPresentation.escapedLinkLabel(#"a\*b_`<>"#) == #"a\\\*b\_\`\<\>"#)
    }

    @Test("Model Markdown: web links and images open and load nothing; citations open")
    @MainActor
    func markdownSecurity() async throws {
        let citation = try #require(URL(string: "rafu-meeting-turn:t3"))
        #expect(MeetingDetailPresentation.turn(fromLink: citation) == MeetingTurnID(3))
        for link in [
            "https://example.com/t3", "http://example.com", "file:///etc/passwd",
            "rafu-meeting-turn:t3/../x", "mailto:a@b.c",
        ] {
            let url = try #require(URL(string: link))
            #expect(MeetingDetailPresentation.turn(fromLink: url) == nil)
        }
        var cited: [MeetingTurnID] = []
        let action = MeetingAnswerMarkdown.openAction { cited.append($0) }
        action(try #require(URL(string: "https://example.com/image.png")))
        action(try #require(URL(string: "rafu-meeting-turn:t4")))
        #expect(cited == [MeetingTurnID(4)])

        // The block image provider draws nothing and the inline provider
        // loads nothing, so an image in model text never reads a URL.
        let image = MeetingNoImageProvider().makeImage(
            url: URL(string: "https://example.com/tracker.png"))
        #expect(type(of: image) == EmptyView.self)
        let imageURL = try #require(URL(string: "https://example.com/i.png"))
        await #expect(throws: MeetingNoInlineImageProvider.NoImage.self) {
            _ = try await MeetingNoInlineImageProvider().image(with: imageURL, label: "i")
        }
        // Long text skips Markdown.
        #expect(MeetingDetailPresentation.usesMarkdown("short"))
        #expect(!MeetingDetailPresentation.usesMarkdown(String(repeating: "a", count: 24_001)))
    }

    @Test("Lines of one speaker group while the gap is below 30 seconds")
    func grouping() {
        func turn(_ number: Int, _ speaker: MeetingSpeakerLabel, _ start: Double, _ end: Double)
            -> MeetingTurn
        {
            MeetingTurn(
                id: MeetingTurnID(number), track: speaker == .me ? .me : .them,
                speaker: speaker, start: start, end: end, text: "x")
        }
        let groups = MeetingDetailPresentation.groups([
            turn(1, .me, 0, 5), turn(2, .me, 10, 20), turn(3, .me, 50, 55),
            turn(4, .speaker(1), 56, 60), turn(5, .me, 61, 62),
        ])
        #expect(groups.map { $0.turns.map(\.id.number) } == [[1, 2], [3], [4], [5]])
        #expect(groups.map(\.speaker) == [.me, .me, .speaker(1), .me])
        #expect(groups[1].start == 50)
    }

    @Test("Search matches ignore case and accents; the count text")
    func search() {
        let turns = [
            MeetingTurn(
                id: MeetingTurnID(1), track: .me, speaker: .me, start: 0, end: 1,
                text: "Café plan"),
            MeetingTurn(
                id: MeetingTurnID(2), track: .me, speaker: .me, start: 1, end: 2, text: "nothing"),
            MeetingTurn(
                id: MeetingTurnID(3), track: .me, speaker: .me, start: 2, end: 3,
                text: "CAFE cafe"),
        ]
        #expect(
            MeetingDetailPresentation.searchMatches("cafe", in: turns)
                == [MeetingTurnID(1), MeetingTurnID(3)])
        #expect(MeetingDetailPresentation.searchMatches("  ", in: turns).isEmpty)
        #expect(MeetingDetailPresentation.matchRanges(of: "cafe", in: "CAFE cafe").count == 2)
        #expect(MeetingDetailPresentation.searchCountText(current: 2, total: 12) == "3 of 12")
        #expect(MeetingDetailPresentation.searchCountText(current: nil, total: 0) == "No results")
        #expect(MeetingDetailPresentation.searchLimitNote == "Search covers the first 4,000 lines.")
    }

    @Test("Header meta: day, time, length and the speakers with most talk first")
    func headerMeta() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            MeetingDetailPresentation.headerMeta(
                start: start, duration: 360, speakers: ["Shilpa", "Me"], now: start,
                calendar: calendar, locale: locale) == "Today 22:13 · 6 min · Shilpa, Me")
        #expect(
            MeetingDetailPresentation.headerMeta(
                start: start, duration: 0, speakers: ["A", "B", "C", "D", "E", "F"], now: start,
                calendar: calendar, locale: locale) == "Today 22:13 · A, B, C, D +2")
        #expect(
            MeetingDetailPresentation.exportedText(at: start, calendar: calendar, locale: locale)
                == "Exported 22:13")
    }

    @Test("Answers for an older text: the divider goes after the last old line")
    func staleDivider() {
        let old = MeetingConversationEntry(
            date: Date(), role: .answer, text: "a", textRevision: 1)
        let legacy = MeetingConversationEntry(date: Date(), role: .question, text: "q")
        let fresh = MeetingConversationEntry(
            date: Date(), role: .answer, text: "b", textRevision: 2)
        #expect(
            MeetingDetailPresentation.staleDividerAfter(
                [legacy, old, fresh], currentRevision: 2) == old.id)
        #expect(MeetingDetailPresentation.isStale(legacy, currentRevision: 2))
        #expect(!MeetingDetailPresentation.isStale(fresh, currentRevision: 2))
        #expect(
            MeetingDetailPresentation.staleDividerAfter([legacy, old], currentRevision: nil)
                == nil)
        #expect(!MeetingDetailPresentation.isStale(legacy, currentRevision: 0))
    }

    @Test("The stream shows text at most every 100 ms")
    func streamThrottle() {
        var throttle = MeetingStreamThrottle()
        let start = ContinuousClock.now
        let first = throttle.shouldPublish(at: start)
        let tooSoon = throttle.shouldPublish(at: start + .milliseconds(40))
        #expect(first)
        #expect(!tooSoon)
        #expect(throttle.delay(at: start + .milliseconds(40)) == .milliseconds(60))
        let later = throttle.shouldPublish(at: start + .milliseconds(100))
        #expect(later)
        throttle.reset()
        let afterReset = throttle.shouldPublish(at: start + .milliseconds(101))
        #expect(afterReset)
    }

    @Test("Consent is needed until an answer from that agent exists or the user agreed")
    func consentRule() {
        let question = MeetingConversationEntry(date: Date(), role: .question, text: "q")
        let codexAnswer = MeetingConversationEntry(
            date: Date(), role: .answer, text: "a", cli: .codex)
        #expect(
            MeetingDetailPresentation.needsConsent(
                cli: .claudeCode, conversation: [], askedThisSession: []))
        #expect(
            MeetingDetailPresentation.needsConsent(
                cli: .claudeCode, conversation: [question, codexAnswer], askedThisSession: []))
        #expect(
            !MeetingDetailPresentation.needsConsent(
                cli: .codex, conversation: [question, codexAnswer], askedThisSession: []))
        #expect(
            !MeetingDetailPresentation.needsConsent(
                cli: .claudeCode, conversation: [], askedThisSession: [.claudeCode]))
        #expect(
            MeetingDetailPresentation.consentTitle(cli: .codex) == "Send this transcript to OpenAI?"
        )
        #expect(
            MeetingDetailPresentation.consentText(cli: .claudeCode).contains(
                "Claude Code uses your own login. Anthropic's terms apply."))
    }

    @Test("Speaker, repeated-line, agent menu and engine line texts")
    func texts() {
        #expect(MeetingDetailPresentation.shareText(0.567) == "57%")
        #expect(
            MeetingDetailPresentation.speakerAccessibilityLabel(name: "Shilpa", share: 0.57)
                == "Shilpa, 57 percent of the talk. Rename")
        #expect(MeetingDetailPresentation.repeatedToggleTitle(count: 6) == "Show 6 repeated lines")
        #expect(MeetingDetailPresentation.repeatedToggleTitle(count: 1) == "Show 1 repeated line")
        #expect(
            MeetingDetailPresentation.noNamesText(cli: .claudeCode)
                == "Claude Code found no names in this meeting.")
        #expect(
            MeetingDetailPresentation.engineLine(
                MeetingEngineUse(textEngine: .whisperKit, speakerEngine: .nemotron3))
                == "Text: WhisperKit · Speakers: Nemotron 3")
        #expect(
            MeetingDetailPresentation.engineLine(MeetingEngineUse(textEngine: .appleSpeech))
                == "Text: Apple speech · Speakers: not told apart")
        #expect(
            MeetingDetailPresentation.agentMenuTitle(cli: .claudeCode, result: .ready)
                == "Claude Code")
        #expect(
            MeetingDetailPresentation.agentMenuTitle(cli: .codex, result: .notInstalled)
                == "Codex — not installed")
        #expect(
            MeetingDetailPresentation.agentMenuTitle(cli: .codex, result: .notSignedIn)
                == "Codex — not signed in")
        #expect(
            MeetingDetailPresentation.agentMenuTitle(
                cli: .codex, result: .unsupportedVersion(found: "0.1"))
                == "Codex — this version is too old")
        #expect(
            MeetingDetailPresentation.accessLine(.off) == "Other agents cannot read your meetings")
        #expect(
            MeetingDetailPresentation.summaryWritingText(cli: .claudeCode)
                == "Claude Code writes the summary…")
        #expect(MeetingViewLayout.layout(width: 860) == .wide)
        #expect(MeetingViewLayout.layout(width: 859) == .narrow)
    }

    @Test("Remake choices leave out the engine in use and each engine that is not ready")
    func remakeChoices() {
        let choices = MeetingDetailPresentation.remakeChoices(
            used: .appleSpeech,
            available: [
                .appleSpeech: .ready, .whisperKit: .ready,
                .nemotronEnglish: .needsModel([.nemotronEnglish1120]),
            ])
        #expect(choices == [.whisperKit])
        #expect(MeetingDetailPresentation.remakeChoices(used: .appleSpeech, available: [:]).isEmpty)
    }
}

@Suite("Meeting detail model")
@MainActor
struct MeetingDetailModelTests {
    @Test("Loading reads the summary, the overview, the first page, and the names to check")
    func loading() async throws {
        let fixture = try await MeetingDetailFixture.make(turnCount: 8)
        defer { fixture.remove() }
        let model = fixture.makeModel(runner: nil)
        await model.reload()
        #expect(model.summary?.title == "Weekly sync")
        #expect(model.turns.count == 8)
        #expect(model.overview?.repeatedCount == 2)
        #expect(model.namesToCheck == [.speaker(1), .speaker(2)])
        // Repeated lines are hidden until the toggle shows them.
        #expect(model.shownTurns.count == 6)
        model.showsRepeated = true
        #expect(model.shownTurns.count == 8)
    }

    @Test("Pages load 200 turns at a time; a citation loads pages until its turn is there")
    func pagingAndReveal() async throws {
        let fixture = try await MeetingDetailFixture.make(turnCount: 650)
        defer { fixture.remove() }
        let model = fixture.makeModel(runner: nil)
        await model.reload()
        #expect(model.turns.count == 200)
        #expect(model.hasMoreTurns)
        #expect(await model.reveal(MeetingTurnID(605)))
        #expect(model.turns.count == 650)
        #expect(model.highlightedTurn == MeetingTurnID(605))
        #expect(model.revealTarget == MeetingTurnID(605))
        #expect(model.revealRequest == 1)
        #expect(model.groupID(containing: MeetingTurnID(605)) == MeetingTurnID(605))
        #expect(!(await model.reveal(MeetingTurnID(9_999))))
    }

    @Test("Search loads more pages, counts matches, and steps through them")
    func searchFlow() async throws {
        let fixture = try await MeetingDetailFixture.make(turnCount: 450)
        defer { fixture.remove() }
        let model = fixture.makeModel(runner: nil)
        await model.reload()
        #expect(model.turns.count == 200)
        model.searchQuery = "line 44"
        await model.runSearch()
        // "Line 44" and "Line 440"…"Line 449", less the hidden repeated
        // lines (443 and 447).
        #expect(model.turns.count == 450)
        #expect(!model.searchHitLimit)
        #expect(model.searchMatches.first == MeetingTurnID(44))
        #expect(model.searchMatches.count == 9)
        #expect(model.searchIndex == 0)
        let total = model.searchMatches.count
        model.previousMatch()
        #expect(model.searchIndex == total - 1)
        model.nextMatch()
        #expect(model.searchIndex == 0)
        #expect(model.currentSearchMatch == MeetingTurnID(44))
        model.searchQuery = ""
        await model.runSearch()
        #expect(model.searchMatches.isEmpty)
        #expect(model.searchIndex == nil)
    }

    @Test("Consent: the first question waits; Cancel starts no run; Send runs it")
    func consentFlow() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .answer("Friday [t2].", citations: []))
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.draft = "When do we ship?"
        model.requestAsk(model.draft)
        #expect(model.pendingConsent == .ask(question: "When do we ship?", cli: .claudeCode))
        model.declineConsent()
        #expect(model.pendingConsent == nil)
        #expect(await runner.askCount == 0)
        #expect(model.askState == .idle)
        #expect(model.draft == "When do we ship?")

        model.requestAsk(model.draft)
        model.confirmConsent()
        await model.runTask?.value
        #expect(await runner.askCount == 1)
        // A second question needs no consent: an answer from that agent exists.
        model.requestAsk("And who owns it?")
        #expect(model.pendingConsent == nil)
        await model.runTask?.value
        #expect(await runner.askCount == 2)
    }

    @Test("Consent is not asked when the stored conversation has an answer from that agent")
    func noConsentAfterStoredAnswer() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        try await fixture.store.appendConversation(
            MeetingConversationEntry(date: Date(), role: .answer, text: "Old", cli: .claudeCode),
            to: fixture.meeting)
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .answer("New", citations: []))
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.requestAsk("Again?")
        #expect(model.pendingConsent == nil)
        await model.runTask?.value
        #expect(await runner.askCount == 1)
    }

    @Test("Send shows the question at once and clears the field; the answer replaces it")
    func askSuccess() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let citation = MeetingCitation(turn: MeetingTurnID(2), quote: "Line 2")
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .answer("Friday [t2].", citations: [citation]))
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.draft = "When do we ship?"
        model.requestAsk(model.draft)
        model.confirmConsent()
        #expect(model.askState == .running(.claudeCode))
        #expect(model.pendingQuestion?.text == "When do we ship?")
        #expect(model.draft.isEmpty)
        await model.runTask?.value
        #expect(model.askState == .idle)
        #expect(model.pendingQuestion == nil)
        #expect(model.conversation.map(\.role) == [.question, .answer])
        #expect(model.conversation.last?.citations == [citation])
    }

    @Test("A streamed answer ends with the stored conversation and no streamed text")
    func askStreaming() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeStreamingMeetingAgentRunner(
            store: fixture.store,
            events: [.textDelta("Fri"), .textReset, .textDelta("Friday "), .textDelta("[t2].")],
            answer: "Friday [t2].")
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        await model.refreshAgents()
        model.requestAsk("When?")
        model.confirmConsent()
        #expect(model.pendingQuestion?.text == "When?")
        await model.runTask?.value
        #expect(model.askState == .idle)
        #expect(model.pendingQuestion == nil)
        #expect(model.streamingText.isEmpty)
        #expect(model.conversation.map(\.text) == ["When?", "Friday [t2]."])
    }

    @Test("An agent error keeps the question bubble; Try Again puts it back in the field")
    func askError() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .fail(.notSignedIn(.claudeCode)))
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.draft = "When?"
        model.requestAsk(model.draft)
        model.confirmConsent()
        await model.runTask?.value
        #expect(model.askState == .failed(MeetingAgentError.notSignedIn(.claudeCode).message))
        #expect(model.pendingQuestion?.text == "When?")
        #expect(model.draft.isEmpty)
        #expect(model.conversation.isEmpty)
        model.retryFailedQuestion()
        #expect(model.draft == "When?")
        #expect(model.pendingQuestion == nil)
        #expect(model.askState == .idle)
    }

    @Test("Busy is not an error: the question goes back into the field")
    func askBusy() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeStreamingMeetingAgentRunner(store: fixture.store, failure: .busy)
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.requestAsk("When?")
        model.confirmConsent()
        await model.runTask?.value
        #expect(model.askState == .busy)
        #expect(model.draft == "When?")
        #expect(model.pendingQuestion == nil)
    }

    @Test("Stop cancels the run, shows no error, and puts the question back")
    func askCancel() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(store: fixture.store, behaviour: .waitForCancel)
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.requestAsk("When?")
        model.confirmConsent()
        let task = try #require(model.runTask)
        model.cancelAsk()
        #expect(model.askState == .idle)
        #expect(model.draft == "When?")
        #expect(model.pendingQuestion == nil)
        await task.value
        #expect(model.askState == .idle)
        #expect(task.isCancelled)
    }

    @Test("Stop for a run of another view asks the runner to cancel it")
    func stopOtherRun() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeStreamingMeetingAgentRunner(store: fixture.store)
        let model = fixture.makeModel(runner: runner)
        await model.stopOtherRun()
        #expect(await runner.cancelledRuns == [.question])
    }

    @Test("Rename saves through the store and the rows show the new name")
    func rename() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        var changes = 0
        let model = MeetingDetailModel(
            meeting: fixture.meeting, store: fixture.store, runner: nil,
            defaults: UserDefaults(suiteName: TestDefaultsSuite.name("MeetingDetailRename"))
                ?? .standard,
            onLibraryChanged: { changes += 1 })
        await model.reload()
        #expect(await model.rename(.speaker(2), to: "Priya"))
        #expect(model.displayName(for: .speaker(2)) == "Priya")
        #expect(try await fixture.store.speakerNames(of: fixture.meeting)[.speaker(2)] == "Priya")
        #expect(model.namesToCheck == [.speaker(1)])
        #expect(changes == 1)
    }

    @Test("Rename Meeting saves the title and tells the library")
    func renameMeeting() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        var changes = 0
        let model = MeetingDetailModel(
            meeting: fixture.meeting, store: fixture.store, runner: nil,
            defaults: UserDefaults(suiteName: TestDefaultsSuite.name("MeetingDetailTitle"))
                ?? .standard,
            onLibraryChanged: { changes += 1 })
        await model.reload()
        #expect(!(await model.renameMeeting(to: "   ")))
        #expect(await model.renameMeeting(to: " Launch plan "))
        #expect(model.summary?.title == "Launch plan")
        #expect(try await fixture.store.summary(of: fixture.meeting)?.title == "Launch plan")
        #expect(changes == 1)
    }

    @Test("A version conflict on rename is tried one more time")
    func renameConflict() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let stale = StaleOnceStore(base: fixture.store)
        let model = fixture.makeModel(runner: nil, store: stale)
        #expect(await model.rename(.speaker(1), to: "Sam"))
        #expect(await stale.renameCalls == 2)
        #expect(model.renameError == nil)
        #expect(model.displayName(for: .speaker(1)) == "Sam")
    }

    @Test("Suggestions rename nothing until Accept; an unknown label is dropped")
    func suggestions() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .answer("", citations: []),
            names: [.speaker(1): "Sam", .speaker(2): "Priya", .speaker(7): "Ghost", .me: "Me"])
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.requestNameSuggestions()
        #expect(model.pendingConsent == .suggestNames(cli: .claudeCode))
        model.confirmConsent()
        await model.suggestTask?.value
        #expect(model.suggestions.map(\.label) == [.speaker(1), .speaker(2)])
        #expect(model.suggestOutcome == nil)
        #expect(try await fixture.store.speakerNames(of: fixture.meeting).isEmpty)

        let priya = try #require(model.suggestions.last)
        await model.accept(priya)
        #expect(try await fixture.store.speakerNames(of: fixture.meeting) == [.speaker(2): "Priya"])
        #expect(model.suggestions.map(\.label) == [.speaker(1)])
        model.dismiss(try #require(model.suggestions.first))
        #expect(model.suggestions.isEmpty)
        #expect(try await fixture.store.speakerNames(of: fixture.meeting).count == 1)
    }

    @Test("No names found is told apart from a run that found names")
    func noNamesFound() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeStreamingMeetingAgentRunner(
            store: fixture.store, nameResult: .noNamesFound)
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.requestNameSuggestions()
        model.confirmConsent()
        await model.suggestTask?.value
        #expect(model.suggestions.isEmpty)
        #expect(model.suggestOutcome == .noNamesFound(.claudeCode))
        model.dismissSuggestOutcome()
        #expect(model.suggestOutcome == nil)
    }

    @Test("No ask box when the runner is nil or the meeting is not ready")
    func noAskBox() async throws {
        let ready = try await MeetingDetailFixture.make()
        defer { ready.remove() }
        let noRunner = ready.makeModel(runner: nil)
        await noRunner.reload()
        #expect(noRunner.isReady)
        #expect(!noRunner.canAsk)

        let processing = try await MeetingDetailFixture.make(state: .processing)
        defer { processing.remove() }
        let runner = FakeMeetingAgentRunner(
            store: processing.store, behaviour: .answer("", citations: []))
        let notReady = processing.makeModel(runner: runner)
        await notReady.reload()
        #expect(!notReady.isReady)
        #expect(!notReady.canAsk)
        notReady.requestAsk("When?")
        #expect(notReady.pendingConsent == nil)
        #expect(await runner.askCount == 0)
    }

    @Test("The probe picks a ready agent; with none ready the ask box is inactive")
    func agentsFromProbe() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let codexOnly = FakeStreamingMeetingAgentRunner(
            store: fixture.store, probes: [.claudeCode: .notSignedIn, .codex: .ready])
        let model = fixture.makeModel(runner: codexOnly)
        await model.reload()
        #expect(model.agent == .claudeCode)
        await model.refreshAgents()
        #expect(model.probeResults[.claudeCode] == .notSignedIn)
        #expect(model.agent == .codex)
        #expect(model.canAsk)

        let none = FakeStreamingMeetingAgentRunner(store: fixture.store, probes: [:])
        let blocked = fixture.makeModel(runner: none)
        await blocked.reload()
        await blocked.refreshAgents()
        #expect(blocked.hasNoReadyAgent)
        #expect(!blocked.canAsk)
        blocked.requestAsk("When?")
        #expect(blocked.pendingConsent == nil)
    }

    @Test("Agent and engine state come from the older checker and the engines")
    func availability() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .answer("", citations: []))
        let model = fixture.makeModel(
            runner: runner,
            textEngines: [
                .appleSpeech: FakeDetailTextEngine(id: .appleSpeech, state: .ready),
                .whisperKit: FakeDetailTextEngine(id: .whisperKit, state: .ready),
            ])
        await model.refreshAgents()
        await model.refreshEngines()
        #expect(model.probeResults[.claudeCode] == .ready)
        #expect(model.probeResults[.codex] == .notInstalled)
        #expect(
            MeetingDetailPresentation.remakeChoices(
                used: .appleSpeech, available: model.textEngineAvailability) == [.whisperKit])
    }

    @Test("The last used agent is kept in the package's own defaults key")
    func lastAgent() {
        let suite = TestDefaultsSuite.name("MeetingDetailAgent")
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { TestDefaultsSuite.remove(suite) }
        let first = MeetingDetailModel(
            meeting: MeetingID(), store: MeetingStore(rootDirectory: URL(filePath: "/nonexistent")),
            runner: nil, defaults: defaults)
        #expect(first.agent == .claudeCode)
        first.agent = .codex
        #expect(defaults.string(forKey: MeetingDetailModel.lastAgentKey) == "codex")
        let second = MeetingDetailModel(
            meeting: MeetingID(), store: MeetingStore(rootDirectory: URL(filePath: "/nonexistent")),
            runner: nil, defaults: defaults)
        #expect(second.agent == .codex)
    }

    @Test("Registration gives the meeting view hook")
    func registration() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.meetingDetailView == nil)
        feature.registerDetailParts()
        #expect(feature.meetingDetailView != nil)
        #expect(feature.registeredKinds == [.meetingDetailView])
    }
}
