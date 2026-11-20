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
}
