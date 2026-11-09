import Foundation
import Testing

@testable import RafuCore

@Suite("Voice agent updates")
struct VoiceAgentUpdatePolicyTests {
    private func update(
        _ card: String = "card-1", _ kind: VoiceAgentUpdate.Kind = .done,
        agent: String = "Claude Code", title: String = "Build", excerpt: String? = nil,
        at queued: Duration = .zero
    ) -> VoiceAgentUpdate {
        VoiceAgentUpdate(
            cardID: card, kind: kind, agent: agent, title: title, excerpt: excerpt,
            queuedAt: queued)
    }

    private func signal(
        state: AgentSessionState, reply: UUID? = nil, row: UUID = UUID(), preview: String? = nil
    ) -> VoiceAgentSignal {
        VoiceAgentSignal(
            cardID: "c", title: "Build", agent: "Codex", sessionRowID: row, state: state,
            replyEventID: reply, preview: preview)
    }

    // MARK: Sentences

    @Test("Done, approval and waiting have their own sentence")
    func forms() {
        #expect(
            VoiceAgentUpdatePolicy.sentence(for: [update()]) == "Claude Code in “Build” is done.")
        #expect(
            VoiceAgentUpdatePolicy.sentence(for: [update("a", .needsApproval)])
                == "Claude Code in “Build” needs your approval.")
        #expect(
            VoiceAgentUpdatePolicy.sentence(for: [update("a", .waiting)])
                == "Claude Code in “Build” is waiting for you.")
        #expect(
            VoiceAgentUpdatePolicy.sentence(for: [update(excerpt: "Tests pass")])
                == "Claude Code in “Build” is done. It says: Tests pass.")
    }

    @Test("Two agents that finish together share one sentence, with no excerpt")
    func coalescedSentence() {
        let sentence = VoiceAgentUpdatePolicy.sentence(for: [
            update("a", excerpt: "Fixed"),
            update("b", agent: "Codex", title: "Tests", excerpt: "Passes"),
        ])
        #expect(sentence == "Claude Code in “Build” and Codex in “Tests” are done.")
        let mixed = VoiceAgentUpdatePolicy.sentence(for: [
            update("a"), update("b", .needsApproval, agent: "Codex", title: "Tests"),
        ])
        #expect(mixed == "Claude Code in “Build” is done. Codex in “Tests” needs your approval.")
    }

    @Test("A card title is cut to 40 scalars and loses quotes and control characters")
    func titles() {
        let long = String(repeating: "x", count: 80)
        let sentence = VoiceAgentUpdatePolicy.sentence(for: [
            update(title: "\"Say\u{7}” \(long)")
        ])
        #expect(sentence.contains("“Say"))
        #expect(!sentence.contains(long))
        #expect(!sentence.contains("\u{7}"))
        #expect(VoiceAgentUpdatePolicy.cleanTitle("  ") == "terminal")
    }

    // MARK: Excerpt

    @Test("The excerpt is the first sentence of the first prose line")
    func excerpt() {
        #expect(
            VoiceAgentUpdatePolicy.spokenExcerpt("Fixed the login bug. Added a test.\nMore.")
                == "Fixed the login bug")
        #expect(
            VoiceAgentUpdatePolicy.spokenExcerpt("## **Done** with the work")
                == "Done with the work")
        #expect(
            VoiceAgentUpdatePolicy.spokenExcerpt("```\nlet a = 1\n```\nAll set here.")
                == "All set here")
        #expect(VoiceAgentUpdatePolicy.spokenExcerpt(nil) == nil)
        #expect(VoiceAgentUpdatePolicy.spokenExcerpt("   \n") == nil)
    }

    @Test("Code, paths and secrets are not read aloud")
    func excerptDrops() {
        #expect(VoiceAgentUpdatePolicy.spokenExcerpt("Edited Sources/App/Main.swift now") == nil)
        #expect(VoiceAgentUpdatePolicy.spokenExcerpt("Ran `swift test` and it passed") == nil)
        #expect(VoiceAgentUpdatePolicy.spokenExcerpt("The key is sk-abcdefgh12345678 ok") == nil)
        #expect(VoiceAgentUpdatePolicy.spokenExcerpt("let x = foo(a, b)") == nil)
    }

    @Test("A long excerpt is cut at a word to at most 120 scalars")
    func excerptLength() throws {
        let text = Array(repeating: "word", count: 60).joined(separator: " ")
        let excerpt = try #require(VoiceAgentUpdatePolicy.spokenExcerpt(text))
        #expect(excerpt.unicodeScalars.count <= VoiceAgentUpdatePolicy.maximumExcerptScalars)
        #expect(excerpt.hasSuffix("word"))
    }

    // MARK: Queue, coalescing and rate limit

    @Test("Nothing is due with an empty queue")
    func empty() {
        var policy = VoiceAgentUpdatePolicy()
        #expect(policy.nextSentence(at: .seconds(100)) == nil)
    }

    @Test("One sentence per 10 seconds; updates in between wait and merge")
    func coalesce() throws {
        var policy = VoiceAgentUpdatePolicy()
        policy.enqueue(update("a", at: .seconds(1)))
        #expect(policy.nextSentence(at: .seconds(1)) == "Claude Code in “Build” is done.")
        policy.enqueue(update("b", agent: "Codex", title: "Tests", at: .seconds(3)))
        #expect(policy.nextSentence(at: .seconds(10)) == nil)
        policy.enqueue(update("c", title: "Docs", at: .seconds(5)))
        let next = policy.nextSentence(at: .seconds(11))
        let merged = try #require(next)
        #expect(merged == "Codex in “Tests” and Claude Code in “Docs” are done.")
        #expect(policy.queue.isEmpty)
    }

    @Test("The queue holds 3; the oldest goes; a newer update replaces the same card")
    func queueDepth() {
        var policy = VoiceAgentUpdatePolicy()
        for index in 1...4 { policy.enqueue(update("c\(index)", title: "T\(index)")) }
        #expect(policy.queue.map(\.cardID) == ["c2", "c3", "c4"])
        policy.enqueue(update("c3", .needsApproval, title: "T3"))
        #expect(policy.queue.map(\.cardID) == ["c2", "c4", "c3"])
        #expect(policy.queue.last?.kind == .needsApproval)
    }

    @Test("At most 6 spoken updates in any minute")
    func perMinute() {
        var policy = VoiceAgentUpdatePolicy()
        var spokenAt: [Int] = []
        // One update every 5 s; one sentence is due at most every 10 s.
        for second in stride(from: 0, through: 70, by: 5) {
            let now = Duration.seconds(second)
            policy.enqueue(update("c", at: now))
            if policy.nextSentence(at: now) != nil { spokenAt.append(second) }
        }
        #expect(spokenAt == [0, 10, 20, 30, 40, 50, 60, 70])
        #expect(spokenAt.filter { $0 < 60 }.count == VoiceAgentUpdatePolicy.maximumPerMinute)
    }

    @Test("An update older than two minutes is dropped, not spoken")
    func stale() {
        var policy = VoiceAgentUpdatePolicy()
        policy.enqueue(update(at: .seconds(1)))
        #expect(policy.nextSentence(at: .seconds(200)) == nil)
        #expect(policy.queue.isEmpty)
    }

    // MARK: Gate

    @Test("Quiet needs 1.5 s without speech and 0.6 s without a reply")
    func quiet() {
        #expect(
            !VoiceAgentUpdatePolicy.isQuiet(
                now: .seconds(10), lastSpeech: .milliseconds(8_600), lastAudibleAt: nil))
        #expect(
            VoiceAgentUpdatePolicy.isQuiet(
                now: .seconds(10), lastSpeech: .milliseconds(8_500), lastAudibleAt: nil))
        #expect(
            !VoiceAgentUpdatePolicy.isQuiet(
                now: .seconds(10), lastSpeech: .zero, lastAudibleAt: .milliseconds(9_500)))
        #expect(
            VoiceAgentUpdatePolicy.isQuiet(
                now: .seconds(10), lastSpeech: .zero, lastAudibleAt: .milliseconds(9_400)))
    }

    // MARK: Signals

    @Test("A signal has news only for a reply or a waiting state")
    func signalKinds() {
        let reply = UUID()
        #expect(signal(state: .working).kind == nil)
        #expect(signal(state: .ended, reply: reply).kind == nil)
        #expect(signal(state: .finished).kind == nil)
        #expect(signal(state: .finished, reply: reply).kind == .done)
        #expect(signal(state: .waitingForPermission).kind == .needsApproval)
        #expect(signal(state: .needsInput).kind == .waiting)
        #expect(
            signal(state: .finished, reply: reply, row: UUID()).announcementKey
                == signal(state: .finished, reply: reply, row: UUID()).announcementKey)
        #expect(
            signal(state: .finished, reply: UUID()).announcementKey
                != signal(state: .finished, reply: reply).announcementKey)
        #expect(signal(state: .working).announcementKey == nil)
    }
}
