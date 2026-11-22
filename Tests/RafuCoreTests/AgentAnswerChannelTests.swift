import Foundation
import Testing

@testable import RafuCore

private func temporaryChannel() throws -> (channel: AgentAnswerChannel, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "rafu-answers-\(UUID().uuidString)", directoryHint: .isDirectory)
    let spool = root.appending(path: "AgentTracking", directoryHint: .isDirectory)
        .appending(path: "spool", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
    return (AgentAnswerChannel(spool: spool), root)
}

private func permissions(at url: URL) throws -> Int {
    try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    ).intValue
}

private func output(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Agent answer channel")
struct AgentAnswerChannelTests {
    @Test("The channel folder is the spool's sibling")
    func location() throws {
        let paths = AgentTrackingPaths(root: URL(fileURLWithPath: "/x/AgentTracking"))
        #expect(AgentAnswerChannel(spool: paths.spool).directory == paths.answers)
        #expect(paths.answers.lastPathComponent == "answers")
        #expect(paths.answers.deletingLastPathComponent().path == paths.root.path)
    }

    @Test("An answer file is private: 0600 in a 0700 folder, written whole")
    func privateFiles() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try channel.write(AgentPermissionAnswer(eventID: id, verdict: .allow))
        #expect(try permissions(at: channel.directory) == 0o700)
        #expect(try permissions(at: channel.answerURL(eventID: id)) == 0o600)
        // No temporary file stays behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: channel.directory.path)
        #expect(names == [id.uuidString + ".json"])
        // The file holds the event id and the verdict, not text.
        let text = try String(contentsOf: channel.answerURL(eventID: id), encoding: .utf8)
        #expect(!text.contains(AgentPermissionAnswer.denyMessage))
    }

    @Test("An answer is read once and deleted")
    func takeOnce() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let answer = AgentPermissionAnswer(eventID: id, verdict: .deny, interrupt: true)
        try channel.write(answer)
        #expect(channel.take(eventID: id) == answer)
        #expect(channel.take(eventID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: channel.answerURL(eventID: id).path))
    }

    @Test("An answer for an unknown event id is ignored and left alone")
    func unknownEvent() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let waiting = UUID()
        let other = UUID()
        try channel.write(AgentPermissionAnswer(eventID: other, verdict: .allow))
        #expect(channel.take(eventID: waiting) == nil)
        // The other helper still gets its own answer.
        #expect(channel.take(eventID: other)?.verdict == .allow)
    }

    @Test("A file named for one event but holding another event's answer is refused")
    func mismatchedContent() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let waiting = UUID()
        try channel.write(AgentPermissionAnswer(eventID: UUID(), verdict: .allow))
        let source = try #require(
            try FileManager.default.contentsOfDirectory(
                at: channel.directory, includingPropertiesForKeys: nil
            ).first)
        let target = channel.answerURL(eventID: waiting)
        try FileManager.default.moveItem(at: source, to: target)
        #expect(channel.take(eventID: waiting) == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("A file that others can read, a link, a big file and bad JSON are refused")
    func refusedFiles() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: channel.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let good = try JSONEncoder().encode(
            AgentPermissionAnswer(eventID: UUID(), verdict: .allow))

        // Readable by others.
        let open = UUID()
        let openAnswer = AgentPermissionAnswer(eventID: open, verdict: .allow)
        fileManager.createFile(
            atPath: channel.answerURL(eventID: open).path,
            contents: try JSONEncoder().encode(openAnswer),
            attributes: [.posixPermissions: 0o644])
        #expect(channel.take(eventID: open) == nil)

        // A symbolic link, even to a good private file.
        let linked = UUID()
        let target = root.appending(path: "target.json")
        fileManager.createFile(
            atPath: target.path,
            contents: try JSONEncoder().encode(
                AgentPermissionAnswer(eventID: linked, verdict: .allow)),
            attributes: [.posixPermissions: 0o600])
        try fileManager.createSymbolicLink(
            at: channel.answerURL(eventID: linked), withDestinationURL: target)
        #expect(channel.take(eventID: linked) == nil)
        #expect(fileManager.fileExists(atPath: target.path))

        // Too big.
        let big = UUID()
        fileManager.createFile(
            atPath: channel.answerURL(eventID: big).path,
            contents: good + Data(repeating: 0x20, count: AgentAnswerChannel.maximumAnswerBytes),
            attributes: [.posixPermissions: 0o600])
        #expect(channel.take(eventID: big) == nil)

        // Not JSON.
        let bad = UUID()
        fileManager.createFile(
            atPath: channel.answerURL(eventID: bad).path, contents: Data("allow".utf8),
            attributes: [.posixPermissions: 0o600])
        #expect(channel.take(eventID: bad) == nil)
    }

    @Test("The first answer for an event wins")
    func firstWins() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try channel.write(AgentPermissionAnswer(eventID: id, verdict: .deny))
        #expect(throws: AgentAnswerChannelError.alreadyAnswered) {
            try channel.write(AgentPermissionAnswer(eventID: id, verdict: .allow))
        }
        #expect(channel.take(eventID: id)?.verdict == .deny)
    }

    @Test("The app writes at most a bounded number of answers")
    func bounded() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<AgentAnswerChannel.maximumFiles {
            try channel.write(AgentPermissionAnswer(eventID: UUID(), verdict: .dismiss))
        }
        #expect(throws: AgentAnswerChannelError.tooManyAnswers) {
            try channel.write(AgentPermissionAnswer(eventID: UUID(), verdict: .dismiss))
        }
    }

    @Test("A linked answer folder is refused")
    func linkedFolder() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: channel.directory, withDestinationURL: elsewhere)
        #expect(throws: AgentAnswerChannelError.symlinkedDirectory) {
            try channel.write(AgentPermissionAnswer(eventID: UUID(), verdict: .allow))
        }
        #expect(AgentAnswerWatchLock(channel: channel) == nil)
        #expect(channel.take(eventID: UUID()) == nil)
    }

    @Test("Prune removes old answer files and keeps new ones and the lock")
    func prune() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = try #require(AgentAnswerWatchLock(channel: channel))
        defer { lock.release() }
        let old = UUID()
        let fresh = UUID()
        try channel.write(AgentPermissionAnswer(eventID: old, verdict: .allow))
        try channel.write(AgentPermissionAnswer(eventID: fresh, verdict: .allow))
        let future = Date().addingTimeInterval(AgentAnswerChannel.staleAge + 60)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-AgentAnswerChannel.staleAge - 60)],
            ofItemAtPath: channel.answerURL(eventID: old).path)
        #expect(channel.prune(now: Date()) == 1)
        #expect(channel.take(eventID: old) == nil)
        #expect(channel.take(eventID: fresh) != nil)
        // Everything but the lock is stale far enough in the future.
        try channel.write(AgentPermissionAnswer(eventID: UUID(), verdict: .allow))
        #expect(channel.prune(now: future) == 1)
        #expect(FileManager.default.fileExists(atPath: channel.watchLockURL.path))
    }
}

@Suite("Agent answer watch lock")
struct AgentAnswerWatchLockTests {
    @Test("A held lock means Rafu is watching; releasing it ends that")
    func watching() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!channel.isWatched)
        let lock = try #require(AgentAnswerWatchLock(channel: channel))
        #expect(channel.isWatched)
        #expect(try permissions(at: channel.watchLockURL) == 0o600)
        // One holder at a time.
        #expect(AgentAnswerWatchLock(channel: channel) == nil)
        lock.release()
        lock.release()
        #expect(!channel.isWatched)
        // The lock can be taken again.
        let again = try #require(AgentAnswerWatchLock(channel: channel))
        #expect(channel.isWatched)
        again.release()
    }

    @Test("Dropping the lock releases it")
    func deinitReleases() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        var lock = AgentAnswerWatchLock(channel: channel)
        #expect(channel.isWatched)
        lock = nil
        #expect(lock == nil)
        #expect(!channel.isWatched)
    }

    @Test("Checking never creates the lock file")
    func checkDoesNotCreate() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!channel.isWatched)
        #expect(!FileManager.default.fileExists(atPath: channel.directory.path))
    }
}

@Suite("Agent answer wait")
struct AgentAnswerWaitTests {
    /// A clock the test moves with `sleep`, so no test waits in real time.
    private final class FakeClock {
        var time = Date(timeIntervalSince1970: 1_000)
        var sleeps = 0
    }

    private func wait(
        _ channel: AgentAnswerChannel, id: UUID, timeout: TimeInterval = 10,
        clock: FakeClock = FakeClock(), watched: @escaping () -> Bool = { true },
        beforeSleep: @escaping (Int) -> Void = { _ in }
    ) -> AgentAnswerOutcome {
        channel.wait(
            eventID: id, timeout: timeout, interval: 1, now: { clock.time },
            sleep: {
                clock.sleeps += 1
                beforeSleep(clock.sleeps)
                clock.time = clock.time.addingTimeInterval($0)
            }, isWatched: watched)
    }

    @Test("Waiting returns an answer that arrives later")
    func answerArrives() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let outcome = wait(
            channel, id: id,
            beforeSleep: { sleeps in
                if sleeps == 3 {
                    try? channel.write(AgentPermissionAnswer(eventID: id, verdict: .allow))
                }
            })
        #expect(outcome == .answered(AgentPermissionAnswer(eventID: id, verdict: .allow)))
        #expect(outcome.output != nil)
    }

    @Test("The timeout gives no output")
    func timeout() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let outcome = wait(channel, id: UUID(), timeout: 5, clock: clock)
        #expect(outcome == .timedOut)
        #expect(outcome.output == nil)
        #expect(clock.sleeps == 5)
    }

    @Test("A dismiss gives no output")
    func dismiss() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try channel.write(AgentPermissionAnswer(eventID: id, verdict: .dismiss))
        let outcome = wait(channel, id: id)
        #expect(outcome == .dismissed)
        #expect(outcome.output == nil)
    }

    @Test("When Rafu stops watching the wait ends with no output")
    func unwatched() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        let outcome = wait(
            channel, id: UUID(),
            watched: {
                checks += 1
                return checks < 3
            })
        #expect(outcome == .unwatched)
        #expect(outcome.output == nil)
    }

    @Test("An answer written just before Rafu stops watching still counts")
    func answerBeatsUnwatched() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try channel.write(AgentPermissionAnswer(eventID: id, verdict: .deny))
        let outcome = wait(channel, id: id, watched: { false })
        #expect(outcome == .answered(AgentPermissionAnswer(eventID: id, verdict: .deny)))
    }

    @Test("An answer for another event does not end the wait")
    func otherEvent() throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        try channel.write(AgentPermissionAnswer(eventID: UUID(), verdict: .allow))
        #expect(wait(channel, id: UUID(), timeout: 3) == .timedOut)
    }

    @Test("A real wait returns when another thread writes the answer")
    func realClock() async throws {
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = try #require(AgentAnswerWatchLock(channel: channel))
        defer { lock.release() }
        let id = UUID()
        let writer = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            try? channel.write(AgentPermissionAnswer(eventID: id, verdict: .allow))
        }
        let outcome = await Task.detached {
            channel.wait(eventID: id, timeout: 120, interval: 0.01)
        }.value
        await writer.value
        #expect(outcome == .answered(AgentPermissionAnswer(eventID: id, verdict: .allow)))
    }
}

@Suite("Agent permission answer output")
struct AgentPermissionAnswerOutputTests {
    @Test("Allow prints the allow decision")
    func allow() throws {
        let json = try output(AgentPermissionAnswer(eventID: UUID(), verdict: .allow).hookOutput)
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect(Set(decision.keys) == ["behavior"])
        #expect(json.count == 1)
    }

    @Test("Deny prints the deny decision with a fixed message")
    func deny() throws {
        let json = try output(AgentPermissionAnswer(eventID: UUID(), verdict: .deny).hookOutput)
        let specific = try #require(json["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == AgentPermissionAnswer.denyMessage)
        #expect(decision["interrupt"] == nil)
    }

    @Test("Deny and stop adds interrupt; allow never does")
    func interrupt() throws {
        let stop = AgentPermissionAnswer(eventID: UUID(), verdict: .deny, interrupt: true)
        let specific = try #require(
            try output(stop.hookOutput)["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["interrupt"] as? Bool == true)
        #expect(
            AgentPermissionAnswer(eventID: UUID(), verdict: .allow, interrupt: true).interrupt
                == false)
    }

    @Test("Dismiss prints nothing")
    func dismiss() {
        #expect(AgentPermissionAnswer(eventID: UUID(), verdict: .dismiss).hookOutput == nil)
    }

    @Test("The output is one line of JSON with stable key order")
    func stable() throws {
        let data = try #require(AgentPermissionAnswer(eventID: UUID(), verdict: .allow).hookOutput)
        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        )
    }

    @Test("An answer decodes without the interrupt key and drops a stray interrupt")
    func decoding() throws {
        let id = UUID()
        let decoded = try JSONDecoder().decode(
            AgentPermissionAnswer.self,
            from: Data(#"{"eventID":"\#(id.uuidString)","verdict":"allow","interrupt":true}"#.utf8))
        #expect(decoded == AgentPermissionAnswer(eventID: id, verdict: .allow))
        #expect(
            (try? JSONDecoder().decode(
                AgentPermissionAnswer.self,
                from: Data(#"{"eventID":"\#(id.uuidString)","verdict":"maybe"}"#.utf8))) == nil)
    }

    // MARK: Question sets

    /// An AskUserQuestion `tool_input` as Claude Code sends it (hooks
    /// reference). The helper keeps it in memory.
    private static var input: [String: Any] {
        [
            "questions": [
                [
                    "question": "Which framework?", "header": "Framework", "multiSelect": false,
                    "options": [["label": "React"], ["label": "Vue"]],
                ],
                [
                    "question": "Which parts?", "header": "Parts", "multiSelect": true,
                    "options": [["label": "Intro"], ["label": "End"]],
                ],
            ]
        ]
    }

    private static func updatedInput(
        _ answers: [AgentPermissionAnswer.QuestionAnswer], input: [String: Any] = input
    ) throws -> [String: Any]? {
        let answer = AgentPermissionAnswer(eventID: UUID(), verdict: .allow, answers: answers)
        guard let data = answer.hookOutput(originalInput: input, suggestion: nil) else {
            return nil
        }
        let specific = try #require(try output(data)["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        return decision["updatedInput"] as? [String: Any]
    }

    @Test("Answers print the original input with answers keyed by question text")
    func questionAnswers() throws {
        let updated = try #require(
            try Self.updatedInput([
                .init(index: 0, labels: ["Vue"]), .init(index: 1, labels: ["Intro", "End"]),
            ]))
        #expect(
            updated["answers"] as? [String: String] == [
                "Which framework?": "Vue", "Which parts?": "Intro, End",
            ])
        // The questions go back unchanged.
        #expect((updated["questions"] as? [Any])?.count == 2)
        // Free text is the value; on a multiple-choice question it follows the labels.
        let typed = try #require(
            try Self.updatedInput([
                .init(index: 0, labels: [], text: "Svelte"),
                .init(index: 1, labels: ["End"], text: "Appendix"),
            ]))
        #expect(
            typed["answers"] as? [String: String] == [
                "Which framework?": "Svelte", "Which parts?": "End, Appendix",
            ])
    }

    @Test("Any answer that does not match the kept questions prints nothing")
    func questionMismatch() throws {
        for answers: [AgentPermissionAnswer.QuestionAnswer] in [
            [.init(index: 0, labels: ["Vue"])],  // one question unanswered
            [.init(index: 0, labels: ["Angular"]), .init(index: 1, labels: ["End"])],
            [.init(index: 0, labels: ["Vue", "React"]), .init(index: 1, labels: ["End"])],
            [.init(index: 0, labels: ["Vue"], text: "x"), .init(index: 1, labels: ["End"])],
            [.init(index: 0, labels: []), .init(index: 1, labels: ["End"])],
            [.init(index: 0, labels: ["Vue"]), .init(index: 1, labels: ["End", "End"])],
            [.init(index: 0, labels: ["Vue"]), .init(index: 0, labels: ["React"])],
            [.init(index: 0, labels: ["Vue"]), .init(index: 5, labels: ["End"])],
            [.init(index: 0, labels: [], text: "a\nb"), .init(index: 1, labels: ["End"])],
            [.init(index: 0, labels: [], text: " "), .init(index: 1, labels: ["End"])],
        ] {
            #expect(try Self.updatedInput(answers) == nil)
        }
        // No kept input, or two questions with one text.
        let answer = AgentPermissionAnswer(
            eventID: UUID(), verdict: .allow, answers: [.init(index: 0, labels: ["Vue"])])
        #expect(answer.hookOutput == nil)
        let question: [String: Any] = ["question": "Q?", "options": [["label": "A"]]]
        #expect(
            try Self.updatedInput(
                [.init(index: 0, labels: ["A"]), .init(index: 1, labels: ["A"])],
                input: ["questions": [question, question]]) == nil)
    }

    @Test("Answers and remember travel only with allow and survive the answer file")
    func answerFields() throws {
        let deny = AgentPermissionAnswer(
            eventID: UUID(), verdict: .deny, answers: [.init(index: 0, labels: ["A"])],
            remember: true)
        #expect(deny.answers == nil)
        #expect(!deny.remember)
        let allow = AgentPermissionAnswer(
            eventID: UUID(), verdict: .allow,
            answers: [.init(index: 0, labels: ["A", "B"], text: "typed")], remember: true)
        let data = try JSONEncoder().encode(allow)
        #expect(try JSONDecoder().decode(AgentPermissionAnswer.self, from: data) == allow)
        // A plain verdict writes no new keys, so an older helper reads it as before.
        let plain = try JSONEncoder().encode(
            AgentPermissionAnswer(eventID: UUID(), verdict: .allow))
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(Set(object.keys) == ["eventID", "verdict", "interrupt"])
    }

    @Test("The largest answer file fits the answer bound")
    func largestAnswerFile() throws {
        let limits = CanvasAgentRequest.Limits.self
        let label = String(repeating: "\"", count: limits.labelBytes)
        let text = String(repeating: "\"", count: limits.freeTextBytes)
        let answers = (0..<limits.questions).map { index in
            AgentPermissionAnswer.QuestionAnswer(
                index: index, labels: Array(repeating: label, count: limits.choices), text: text)
        }
        // 4 answers × (6 labels × 128 bytes + 1 KiB of text), every
        // character a JSON escape: about 14.5 KiB, inside the 16 KiB bound.
        let data = try JSONEncoder().encode(
            AgentPermissionAnswer(eventID: UUID(), verdict: .allow, answers: answers))
        #expect(data.count <= AgentAnswerChannel.maximumAnswerBytes)
        #expect(data.count > 8 * 1_024)
        // The helper takes it whole from the private file.
        let (channel, root) = try temporaryChannel()
        defer { try? FileManager.default.removeItem(at: root) }
        let largest = AgentPermissionAnswer(eventID: UUID(), verdict: .allow, answers: answers)
        try channel.write(largest)
        #expect(channel.take(eventID: largest.eventID) == largest)
        // A decoded file with too many answers is refused.
        let five = (0..<5).map { #"{"index":\#($0),"labels":["a"]}"# }.joined(separator: ",")
        let json = #"{"eventID":"\#(UUID().uuidString)","verdict":"allow","answers":[\#(five)]}"#
        #expect(
            (try? JSONDecoder().decode(AgentPermissionAnswer.self, from: Data(json.utf8))) == nil)
    }

    // MARK: Remember

    private static var suggestion: [String: Any] {
        [
            "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]],
            "behavior": "allow", "destination": "localSettings",
        ]
    }

    @Test("Remember echoes the one suggestion only when lasting grants are allowed")
    func remember() throws {
        let answer = AgentPermissionAnswer(eventID: UUID(), verdict: .allow, remember: true)
        // Off by default: nothing prints, so the terminal dialog stays.
        #expect(answer.hookOutput(originalInput: nil, suggestion: Self.suggestion) == nil)
        let data = try #require(
            answer.hookOutput(originalInput: nil, suggestion: Self.suggestion, policy: .all))
        let specific = try #require(try output(data)["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        let echoed = try #require(decision["updatedPermissions"] as? [[String: Any]])
        #expect(echoed.count == 1)
        #expect(echoed[0]["destination"] as? String == "localSettings")
        // A suggestion Rafu does not understand is never echoed.
        var other = Self.suggestion
        other["type"] = "setMode"
        #expect(answer.hookOutput(originalInput: nil, suggestion: other, policy: .all) == nil)
        #expect(answer.hookOutput(originalInput: nil, suggestion: nil, policy: .all) == nil)
        // Without remember, a plain allow never carries updatedPermissions.
        let plain = try #require(
            AgentPermissionAnswer(eventID: UUID(), verdict: .allow)
                .hookOutput(originalInput: nil, suggestion: Self.suggestion, policy: .all))
        #expect(!String(decoding: plain, as: UTF8.self).contains("updatedPermissions"))
    }
}
