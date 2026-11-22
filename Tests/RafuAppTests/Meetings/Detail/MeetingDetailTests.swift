import Foundation
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Meeting detail presentation")
struct MeetingDetailPresentationTests {
    @Test("The overview sums talk time for each speaker and leaves echo turns out")
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
                id: MeetingTurnID(4), track: .them, speaker: .speaker(1), start: 100, end: 105,
                text: "d"),
            MeetingTurn(
                id: MeetingTurnID(5), track: .me, speaker: .me, start: 105, end: 125, text: "e"),
        ]
        let overview = MeetingDetailPresentation.overview(
            document: MeetingDocument(summary: summary, turns: turns))
        #expect(overview.speakerLabels == [.me, .speaker(2), .speaker(1)])
        #expect(overview.speakers.map(\.talkSeconds) == [30, 30, 5])
        #expect(overview.turnCount == 4)
        #expect(overview.echoCount == 1)
        #expect(overview.hasNumberedSpeakers)
        #expect(overview.duration == 1_860)
        #expect(MeetingDetailPresentation.lengthText(1_860) == "31 min")
        #expect(MeetingDetailPresentation.lengthText(45) == "45 s")
        #expect(MeetingDetailPresentation.lengthText(3_900) == "1 h 5 min")
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
        let marks = MeetingDetailPresentation.citationMarks(
            in: MeetingDetailPresentation.answerSegments(
                text: "[t7] and [t7][t99]", verified: verified))
        #expect(marks.map(\.turn) == [t7, MeetingTurnID(99)])
        #expect(marks.map(\.isVerified) == [true, false])
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

    @Test("Banner, echo toggle and engine line texts")
    func texts() {
        #expect(MeetingDetailPresentation.namesBanner(count: 1) == "1 name to check")
        #expect(MeetingDetailPresentation.namesBanner(count: 3) == "3 names to check")
        #expect(
            MeetingDetailPresentation.echoToggleTitle(count: 4, shown: false) == "Show 4 echo lines"
        )
        #expect(
            MeetingDetailPresentation.echoToggleTitle(count: 4, shown: true) == "Hide 4 echo lines")
        #expect(
            MeetingDetailPresentation.engineLine(
                MeetingEngineUse(textEngine: .nemotronEnglish, speakerEngine: .nemotron3))
                == "Text: Nemotron English · Speakers: Nemotron 3")
        #expect(
            MeetingDetailPresentation.engineLine(MeetingEngineUse(textEngine: .appleSpeech))
                == "Text: Apple speech · Speakers: not told apart")
        #expect(
            MeetingDetailPresentation.availabilityText(.unsupportedVersion(found: "1"), cli: .codex)
                == "Not available with this Codex version")
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
        #expect(model.overview?.echoCount == 2)
        #expect(model.namesToCheck == [.speaker(1), .speaker(2)])
        // Echo turns are hidden until the toggle shows them.
        #expect(model.shownTurns.count == 6)
        model.showsEcho = true
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
        #expect(model.revealRequest == 1)
        #expect(!(await model.reveal(MeetingTurnID(9_999))))
    }

    @Test("Consent: the first question waits; Not now starts no run; Send runs it")
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

    @Test("A successful run reloads the conversation and clears the question")
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
        await model.runTask?.value
        #expect(model.askState == .idle)
        #expect(model.draft.isEmpty)
        #expect(model.conversation.map(\.role) == [.question, .answer])
        #expect(model.conversation.last?.citations == [citation])
    }

    @Test("An agent error shows its message and keeps the question")
    func askError() async throws {
        let fixture = try await MeetingDetailFixture.make()
        defer { fixture.remove() }
        let runner = FakeMeetingAgentRunner(
            store: fixture.store, behaviour: .fail(.notSignedIn(.codex)))
        let model = fixture.makeModel(runner: runner)
        await model.reload()
        model.agent = .codex
        model.draft = "When?"
        model.requestAsk(model.draft)
        model.confirmConsent()
        await model.runTask?.value
        #expect(model.askState == .failed(MeetingAgentError.notSignedIn(.codex).message))
        #expect(model.draft == "When?")
        #expect(model.conversation.isEmpty)
    }

    @Test("Cancel cancels the run and shows no error")
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
        await task.value
        #expect(model.askState == .idle)
        #expect(task.isCancelled)
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
        #expect(try await fixture.store.speakerNames(of: fixture.meeting).isEmpty)

        let priya = try #require(model.suggestions.last)
        await model.accept(priya)
        #expect(try await fixture.store.speakerNames(of: fixture.meeting) == [.speaker(2): "Priya"])
        #expect(model.suggestions.map(\.label) == [.speaker(1)])
        model.dismiss(try #require(model.suggestions.first))
        #expect(model.suggestions.isEmpty)
        #expect(try await fixture.store.speakerNames(of: fixture.meeting).count == 1)
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

    @Test("Agent and engine availability come from the runner and the engines")
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
        await model.refreshAvailability()
        #expect(model.agentAvailability[.claudeCode] == .ready)
        #expect(model.agentAvailability[.codex] == .notInstalled)
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

    @Test("Registration gives the detail view hook")
    func registration() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.meetingDetailView == nil)
        feature.registerDetailParts()
        #expect(feature.meetingDetailView != nil)
        #expect(feature.registeredKinds == [.meetingDetailView])
    }
}
