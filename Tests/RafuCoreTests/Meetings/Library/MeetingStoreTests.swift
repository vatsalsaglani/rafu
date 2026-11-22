import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting library: store")
struct MeetingStoreTests {
    // MARK: Create, modes, layout

    @Test("A new meeting has the layout on disk, folders 0700 and files 0600")
    func layoutAndModes() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        // Making a store touches no file.
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        let created = try await store.create(
            title: "Weekly sync", startDate: LibrarySample.startDate)
        #expect(created.version == 1)
        #expect(created.state == .recording)
        try await store.appendTurns([LibrarySample.turn(1)], to: created.id, expectedVersion: 1)
        _ = try await store.renameSpeaker(
            .me, to: "Vatsal", in: created.id, expectedVersion: 2)
        _ = try await store.appendConversation(
            MeetingConversationEntry(
                date: LibrarySample.startDate, role: .question, text: "Q?"), to: created.id)
        let audio = try await store.audioFolder(for: created.id)

        let folder = fixture.folder(of: created.id)
        #expect(audio.standardizedFileURL == folder.appending(path: "audio").standardizedFileURL)
        for directory in [fixture.root, folder, audio] {
            #expect(LibraryFixture.mode(of: directory) == 0o700, "\(directory.lastPathComponent)")
        }
        for name in ["meeting.json", "turns.jsonl", "edits.jsonl", "conversation.jsonl"] {
            #expect(LibraryFixture.mode(of: fixture.file(name, of: created.id)) == 0o600, "\(name)")
        }
        // No temporary file is left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(
            names == ["audio", "conversation.jsonl", "edits.jsonl", "meeting.json", "turns.jsonl"])
    }

    @Test("meeting.json holds a version, the engines and no workspace field")
    func recordFileShape() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.setEngines(
            MeetingEngineUse(
                textEngine: .appleSpeech, textModel: nil, textModelRevision: "r1",
                speakerEngine: .speakerKit, speakerModel: .speakerKit, speakerModelRevision: "r2"),
            of: created.id, expectedVersion: 1)
        let data = try Data(contentsOf: fixture.file("meeting.json", of: created.id))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        #expect(object["schema"] as? Int == 1)
        #expect(object.keys.allSatisfy { !$0.lowercased().contains("workspace") })
        let summary = try #require(try await store.summary(of: created.id))
        #expect(summary.engines.textEngine == .appleSpeech)
        #expect(summary.engines.speakerModelRevision == "r2")
        #expect(abs(summary.startDate.timeIntervalSince(LibrarySample.startDate)) < 0.001)
    }

    @Test("list is newest first and unknown or invalid folders are ignored")
    func listing() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        #expect(try await store.list().isEmpty)
        let older = try await store.create(
            title: "Older", startDate: Date(timeIntervalSince1970: 100))
        let newer = try await store.create(
            title: "Newer", startDate: Date(timeIntervalSince1970: 200))
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "not-a-meeting"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fixture.root.appending(path: ".DS_Store"))
        let list = try await store.list()
        #expect(list.map(\.id) == [newer.id, older.id])
        #expect(try await store.summary(of: MeetingID()) == nil)
    }

    @Test("Titles are cleaned: no line break, a limit, a default when empty")
    func titles() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(
            title: "  Line one\nline two\u{0}  ", startDate: LibrarySample.startDate)
        #expect(created.title == "Line one line two")
        let empty = try await store.create(title: "   ", startDate: LibrarySample.startDate)
        #expect(empty.title == "Untitled meeting")
        let long = try await store.create(
            title: String(repeating: "x", count: 500), startDate: LibrarySample.startDate)
        #expect(long.title.count == 200)
    }

    // MARK: Versions

    @Test("A write with an old version throws a conflict and changes nothing")
    func expectedVersionConflict() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let diagnostics = RecordingMeetingDiagnostics()
        let store = fixture.makeStore(diagnostics: diagnostics)
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let second = try await store.rename(created.id, title: "B", expectedVersion: 1)
        #expect(second == 2)

        let before = try Data(contentsOf: fixture.file("meeting.json", of: created.id))
        await #expect(
            throws: MeetingVersionConflict(meeting: created.id, expected: 1, found: 2)
        ) {
            _ = try await store.rename(created.id, title: "C", expectedVersion: 1)
        }
        await #expect(throws: MeetingVersionConflict.self) {
            _ = try await store.appendTurns(
                [LibrarySample.turn(1)], to: created.id, expectedVersion: 5)
        }
        await #expect(throws: MeetingVersionConflict.self) {
            _ = try await store.setState(.ready, of: created.id, expectedVersion: 0)
        }
        await #expect(throws: MeetingVersionConflict.self) {
            _ = try await store.renameSpeaker(
                .me, to: "X", in: created.id, expectedVersion: 1)
        }
        let after = try Data(contentsOf: fixture.file("meeting.json", of: created.id))
        #expect(before == after)
        // A refused append wrote no turn, and a refused rename wrote no edit.
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.file("turns.jsonl", of: created.id).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.file("edits.jsonl", of: created.id).path))
        let conflicts = diagnostics.events.filter {
            if case .libraryWrite(.conflict, _) = $0 { return true }
            return false
        }
        #expect(conflicts.count == 4)
    }

    @Test("Each write returns the next version and the summary shows it")
    func versionsCount() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        var version = created.version
        version = try await store.appendTurns(
            [LibrarySample.turn(1)], to: created.id, expectedVersion: version)
        version = try await store.setState(.processing, of: created.id, expectedVersion: version)
        version = try await store.setDuration(61, of: created.id, expectedVersion: version)
        #expect(version == 4)
        let summary = try #require(try await store.summary(of: created.id))
        #expect(summary.version == 4)
        #expect(summary.state == .processing)
        #expect(summary.duration == 61)
        // An empty batch changes nothing.
        let same = try await store.appendTurns([], to: created.id, expectedVersion: 4)
        #expect(same == 4)
    }

    @Test("Appended turns raise the recorded length")
    func appendRaisesDuration() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.appendTurns(
            [LibrarySample.turn(1, start: 100)], to: created.id, expectedVersion: 1)
        #expect(try await store.summary(of: created.id)?.duration == 105)
    }

    // MARK: Damaged files

    @Test("A damaged line, a long line and a partial last line are skipped and counted")
    func damagedLinesSkipped() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        var version = try await store.appendTurns(
            [LibrarySample.turn(1), LibrarySample.turn(2)], to: created.id, expectedVersion: 1)
        let turnsURL = fixture.file("turns.jsonl", of: created.id)
        let handle = try FileHandle(forWritingTo: turnsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{this is not json}\n".utf8))
        try handle.write(
            contentsOf: Data((String(repeating: "x", count: 70_000) + "\n").utf8))
        // A crash in the middle of a line: no closing brace, no newline.
        try handle.write(contentsOf: Data(#"{"id":"t9","track":"me"#.utf8))
        try handle.close()

        let page = try await store.turns(of: created.id, after: nil, limit: 50)
        #expect(page.turns.map(\.id.number) == [1, 2])
        #expect(try await store.readReport(of: created.id).skippedTurnLines == 3)

        // The next append starts on a new line and is readable.
        version = try await store.appendTurns(
            [LibrarySample.turn(3)], to: created.id, expectedVersion: version)
        let again = try await store.turns(of: created.id, after: nil, limit: 50)
        #expect(again.turns.map(\.id.number) == [1, 2, 3])
        #expect(version == 3)
    }

    @Test("A turn over the line limit is refused and writes nothing")
    func oversizedTurnRefused() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let huge = LibrarySample.turn(4, text: String(repeating: "w", count: 70_000))
        await #expect(throws: MeetingStoreError.turnTooLarge(MeetingTurnID(4))) {
            _ = try await store.appendTurns(
                [LibrarySample.turn(3), huge], to: created.id, expectedVersion: 1)
        }
        #expect(try await store.turns(of: created.id, after: nil, limit: 10).turns.isEmpty)
        #expect(try await store.summary(of: created.id)?.version == 1)
    }

    @Test("A damaged meeting.json is a typed error and is left out of the list")
    func damagedRecord() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let good = try await store.create(title: "Good", startDate: LibrarySample.startDate)
        let bad = try await store.create(title: "Bad", startDate: LibrarySample.startDate)
        try Data("{".utf8).write(to: fixture.file("meeting.json", of: bad.id))
        await #expect(throws: MeetingStoreError.corruptRecord(bad.id)) {
            _ = try await store.summary(of: bad.id)
        }
        #expect(try await store.list().map(\.id) == [good.id])
    }

    @Test("A file over its limit is refused")
    func fileOverLimit() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let big = Data(count: MeetingStore.recordFileLimit + 1)
        try big.write(to: fixture.file("meeting.json", of: created.id))
        await #expect(throws: MeetingStoreError.fileTooLarge(limit: MeetingStore.recordFileLimit)) {
            _ = try await store.summary(of: created.id)
        }
    }

    // MARK: Atomic write

    @Test("A failure between the write and the rename keeps the old file and removes the temp file")
    func atomicWriteKeepsOldFile() throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        try MeetingFileIO.ensurePrivateDirectory(fixture.root)
        let target = fixture.root.appending(path: "meeting.json")
        try MeetingFileIO.atomicWrite(Data("old".utf8), to: target)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try MeetingFileIO.atomicWrite(Data("new".utf8), to: target) { throw Boom() }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(names == ["meeting.json"])
        // A normal write replaces it and keeps mode 0600.
        try MeetingFileIO.atomicWrite(Data("new".utf8), to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        #expect(LibraryFixture.mode(of: target) == 0o600)
    }

    // MARK: Turns, paging, edits

    @Test("Turns come in pages and the page tells where the next one starts")
    func paging() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let turns = (1...7).map { LibrarySample.turn($0) }
        let version = try await store.appendTurns(turns, to: created.id, expectedVersion: 1)

        let first = try await store.turns(of: created.id, after: nil, limit: 3)
        #expect(first.turns.map(\.id.number) == [1, 2, 3])
        #expect(first.nextAfter == MeetingTurnID(3))
        #expect(first.version == version)
        let second = try await store.turns(of: created.id, after: first.nextAfter, limit: 3)
        #expect(second.turns.map(\.id.number) == [4, 5, 6])
        let third = try await store.turns(of: created.id, after: second.nextAfter, limit: 3)
        #expect(third.turns.map(\.id.number) == [7])
        #expect(third.nextAfter == nil)
        // An exact fit has no next page.
        let exact = try await store.turns(of: created.id, after: MeetingTurnID(4), limit: 3)
        #expect(exact.turns.map(\.id.number) == [5, 6, 7])
        #expect(exact.nextAfter == nil)
        // An id that does not exist continues after the greater ids.
        let gap = try await store.turns(of: created.id, after: MeetingTurnID(100), limit: 3)
        #expect(gap.turns.isEmpty)
    }

    @Test("A speaker rename keeps each turn id and does not rewrite the turns file")
    func renameKeepsTurnIds() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        let turns = [
            LibrarySample.turn(1, .me), LibrarySample.turn(2, .speaker(2)),
            LibrarySample.turn(3, .speaker(2)),
        ]
        var version = try await store.appendTurns(turns, to: created.id, expectedVersion: 1)
        let turnsBefore = try Data(contentsOf: fixture.file("turns.jsonl", of: created.id))

        version = try await store.renameSpeaker(
            .speaker(2), to: "  Priya\n", in: created.id, expectedVersion: version)
        let turnsAfter = try Data(contentsOf: fixture.file("turns.jsonl", of: created.id))
        #expect(turnsBefore == turnsAfter)
        let page = try await store.turns(of: created.id, after: nil, limit: 10)
        #expect(page.turns.map(\.id) == turns.map(\.id))
        #expect(page.turns.map(\.speaker) == turns.map(\.speaker))
        #expect(try await store.speakerNames(of: created.id) == [.speaker(2): "Priya"])

        // The latest rename wins and an empty name clears it.
        version = try await store.renameSpeaker(
            .speaker(2), to: "Priyanka", in: created.id, expectedVersion: version)
        #expect(try await store.speakerNames(of: created.id) == [.speaker(2): "Priyanka"])
        version = try await store.renameSpeaker(
            .speaker(2), to: "", in: created.id, expectedVersion: version)
        #expect(try await store.speakerNames(of: created.id).isEmpty)
        #expect(version == 5)
    }

    @Test("A text edit keeps the turn id, shows in the page and leaves the turns file alone")
    func textEdit() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        var version = try await store.appendTurns(
            [LibrarySample.turn(1, text: "helo wrld")], to: created.id, expectedVersion: 1)
        let before = try Data(contentsOf: fixture.file("turns.jsonl", of: created.id))
        version = try await store.editTurnText(
            MeetingTurnID(1), to: "hello world", in: created.id, expectedVersion: version)
        #expect(try Data(contentsOf: fixture.file("turns.jsonl", of: created.id)) == before)
        let page = try await store.turns(of: created.id, after: nil, limit: 10)
        #expect(page.turns.first?.text == "hello world")
        #expect(page.turns.first?.id == MeetingTurnID(1))
        await #expect(throws: MeetingStoreError.turnNotFound(MeetingTurnID(9))) {
            _ = try await store.editTurnText(
                MeetingTurnID(9), to: "x", in: created.id, expectedVersion: version)
        }
    }

    @Test("Replacing the turns writes one new file, drops text edits and keeps speaker names")
    func replaceTurns() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        var version = try await store.appendTurns(
            [LibrarySample.turn(1, text: "old")], to: created.id, expectedVersion: 1)
        version = try await store.editTurnText(
            MeetingTurnID(1), to: "old fixed", in: created.id, expectedVersion: version)
        version = try await store.renameSpeaker(
            .them, to: "Priya", in: created.id, expectedVersion: version)
        version = try await store.replaceTurns(
            [LibrarySample.turn(1, .them, text: "new text")], in: created.id,
            expectedVersion: version)
        let page = try await store.turns(of: created.id, after: nil, limit: 10)
        #expect(page.turns.map(\.text) == ["new text"])
        #expect(try await store.speakerNames(of: created.id) == [.them: "Priya"])
        #expect(try await store.search("old", limit: 10).isEmpty)
        #expect(try await store.search("new", limit: 10).count == 1)
    }

    // MARK: Conversation

    @Test("Conversation entries are kept in order and a citation to a missing turn is dropped")
    func conversation() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.appendTurns(
            [LibrarySample.turn(9)], to: created.id, expectedVersion: 1)
        let question = MeetingConversationEntry(
            date: LibrarySample.startDate, role: .question, text: "What was decided?")
        #expect(try await store.appendConversation(question, to: created.id) == 0)
        let answer = MeetingConversationEntry(
            date: LibrarySample.startDate, role: .answer, text: "Ship it.", cli: .claudeCode,
            citations: [
                MeetingCitation(turn: MeetingTurnID(9), quote: "turn 9"),
                MeetingCitation(turn: MeetingTurnID(77), quote: "invented"),
            ])
        let failed = try await store.appendConversation(answer, to: created.id)
        #expect(failed == 1)
        let stored = try await store.conversation(of: created.id)
        #expect(stored.map(\.role) == [.question, .answer])
        #expect(stored[1].cli == .claudeCode)
        #expect(stored[1].citations.map(\.turn) == [MeetingTurnID(9)])
        // The conversation does not change the meeting version.
        #expect(try await store.summary(of: created.id)?.version == 2)

        let check = try await store.verifyCitations(
            [
                MeetingCitation(turn: MeetingTurnID(9), quote: "a"),
                MeetingCitation(turn: MeetingTurnID(1), quote: "b"),
            ], in: created.id)
        #expect(check.verified.count == 1)
        #expect(check.failedCount == 1)
    }

    // MARK: Delete

    @Test("Delete removes the folder, the index rows and the diagnostics files")
    func deleteLeavesNothing() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let kept = try await store.create(title: "Kept zebra", startDate: LibrarySample.startDate)
        let gone = try await store.create(title: "Gone zebra", startDate: LibrarySample.startDate)
        _ = try await store.appendTurns(
            [LibrarySample.turn(1, text: "zebra crossing")], to: gone.id, expectedVersion: 1)
        _ = try await store.audioFolder(for: gone.id)
        try Data("audio".utf8).write(to: fixture.file("audio/me.caf", of: gone.id))
        try FileManager.default.createDirectory(
            at: fixture.diagnosticsDirectory, withIntermediateDirectories: true)
        let diagnosticsFiles = [
            fixture.diagnosticsDirectory.appending(path: "\(gone.id.uuidString).jsonl"),
            fixture.diagnosticsDirectory.appending(path: "\(gone.id.uuidString).1.jsonl"),
        ]
        for url in diagnosticsFiles { try Data("{}".utf8).write(to: url) }
        let keptDiagnostics = fixture.diagnosticsDirectory.appending(
            path: "\(kept.id.uuidString).jsonl")
        try Data("{}".utf8).write(to: keptDiagnostics)

        // The index is built before the delete, so the delete must update it.
        #expect(try await store.search("zebra", limit: 10).count == 3)
        try await store.delete(gone.id)

        #expect(!FileManager.default.fileExists(atPath: fixture.folder(of: gone.id).path))
        for url in diagnosticsFiles {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(FileManager.default.fileExists(atPath: keptDiagnostics.path))
        let hits = try await store.search("zebra", limit: 10)
        #expect(hits.map(\.meeting) == [kept.id])
        #expect(try await store.list().map(\.id) == [kept.id])
        #expect(try await store.summary(of: gone.id) == nil)
        // A second delete is harmless.
        try await store.delete(gone.id)
        // The index made again from the files has no row for the meeting.
        try await store.rebuildSearchIndex()
        #expect(try await store.search("crossing", limit: 10).isEmpty)
    }

    // MARK: Retention

    @Test("Retention deletes audio older than the policy and never text")
    func retention() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let diagnostics = RecordingMeetingDiagnostics()
        let store = fixture.makeStore(diagnostics: diagnostics)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400

        func meeting(
            _ title: String, ageDays: Double, state: MeetingState
        ) async throws -> MeetingID {
            let created = try await store.create(title: title, startDate: now)
            _ = try await store.appendTurns(
                [LibrarySample.turn(1, text: "kept words")], to: created.id, expectedVersion: 1)
            _ = try await store.setState(state, of: created.id, expectedVersion: 2)
            _ = try await store.audioFolder(for: created.id)
            for name in ["me.caf", "them.caf"] {
                let url = fixture.file("audio/\(name)", of: created.id)
                try Data(count: 100).write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-ageDays * day)],
                    ofItemAtPath: url.path)
            }
            return created.id
        }
        let old = try await meeting("old", ageDays: 10, state: .ready)
        let fresh = try await meeting("fresh", ageDays: 3, state: .ready)
        let oldFailed = try await meeting(
            "old failed", ageDays: 40, state: .failed(reasonCode: "x"))
        let oldProcessing = try await meeting("processing", ageDays: 40, state: .processing)

        func audioCount(_ id: MeetingID) -> Int {
            (try? FileManager.default.contentsOfDirectory(
                atPath: fixture.file("audio", of: id).path
            ).count) ?? -1
        }

        // The default policy does nothing.
        try await store.applyAudioRetention(.untilDeleted, now: now)
        #expect([old, fresh, oldFailed, oldProcessing].map(audioCount) == [2, 2, 2, 2])

        try await store.applyAudioRetention(.days30, now: now)
        #expect([old, fresh, oldFailed, oldProcessing].map(audioCount) == [2, 2, 0, 2])

        try await store.applyAudioRetention(.days7, now: now)
        #expect([old, fresh, oldFailed, oldProcessing].map(audioCount) == [0, 2, 0, 2])

        // Text stays.
        for id in [old, oldFailed] {
            #expect(try await store.turns(of: id, after: nil, limit: 5).turns.count == 1)
            #expect(
                FileManager.default.fileExists(atPath: fixture.file("meeting.json", of: id).path))
        }
        // One event for each policy that ran, with the count of files.
        let counts = diagnostics.events.compactMap { event -> Int? in
            if case .libraryWrite(.written, let code) = event, let code { return code }
            return nil
        }
        #expect(counts == [2, 2])
    }

    // MARK: Sizes

    @Test("Sizes count audio and text separately")
    func sizes() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.audioFolder(for: created.id)
        try Data(count: 1_000).write(to: fixture.file("audio/me.caf", of: created.id))
        try Data(count: 500).write(to: fixture.file("audio/them.caf", of: created.id))
        _ = try await store.appendTurns(
            [LibrarySample.turn(1)], to: created.id, expectedVersion: 1)
        let sizes = try await store.sizeOnDisk(of: created.id)
        #expect(sizes.audioBytes == 1_500)
        #expect(sizes.transcriptBytes > 100)
        #expect(sizes.totalBytes == sizes.audioBytes + sizes.transcriptBytes)
        #expect(try await store.summary(of: created.id)?.sizes == sizes)
        await #expect(throws: MeetingStoreError.self) {
            _ = try await store.sizeOnDisk(of: MeetingID())
        }
    }

    // MARK: Symbolic links

    @Test("A symbolic link in a meeting folder is refused and never followed")
    func symbolicLinks() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "A", startDate: LibrarySample.startDate)
        _ = try await store.appendTurns(
            [LibrarySample.turn(1)], to: created.id, expectedVersion: 1)

        let outside = fixture.base.appending(path: "outside.txt")
        try Data(
            #"{"id":"t1","track":"me","speaker":"me","start":0,"end":1,"text":"secret","isEcho":false}"#
                .utf8
        )
        .write(to: outside)

        // turns.jsonl becomes a link to a file outside the library.
        let turnsURL = fixture.file("turns.jsonl", of: created.id)
        try FileManager.default.removeItem(at: turnsURL)
        try FileManager.default.createSymbolicLink(at: turnsURL, withDestinationURL: outside)
        await #expect(throws: MeetingStoreError.symbolicLinkRefused) {
            _ = try await store.turns(of: created.id, after: nil, limit: 10)
        }
        await #expect(throws: MeetingStoreError.symbolicLinkRefused) {
            _ = try await store.appendTurns(
                [LibrarySample.turn(2)], to: created.id, expectedVersion: 2)
        }
        await #expect(throws: MeetingStoreError.symbolicLinkRefused) {
            _ = try await store.makeAgentSnapshot(of: created.id)
        }
        #expect(try String(contentsOf: outside, encoding: .utf8).contains("secret"))
        #expect(!(try String(contentsOf: outside, encoding: .utf8)).contains("t2"))

        // meeting.json as a link.
        let second = try await store.create(title: "B", startDate: LibrarySample.startDate)
        let recordURL = fixture.file("meeting.json", of: second.id)
        try FileManager.default.removeItem(at: recordURL)
        try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: outside)
        await #expect(throws: MeetingStoreError.symbolicLinkRefused) {
            _ = try await store.summary(of: second.id)
        }

        // The whole meeting folder as a link: refused, and delete removes only the link.
        let target = fixture.base.appending(path: "other-folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appending(path: "keep.txt"))
        let third = MeetingID()
        try FileManager.default.createSymbolicLink(
            at: fixture.folder(of: third), withDestinationURL: target)
        await #expect(throws: MeetingStoreError.symbolicLinkRefused) {
            _ = try await store.summary(of: third)
        }
        #expect(!(try await store.list().map(\.id)).contains(third))
        try await store.delete(third)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "keep.txt").path))
    }

    @Test("Audio links are not counted and retention never deletes through them")
    func audioSymbolicLinks() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let created = try await store.create(title: "A", startDate: now)
        _ = try await store.setState(.ready, of: created.id, expectedVersion: 1)
        let outside = fixture.base.appending(path: "precious.caf")
        try Data(count: 4_000).write(to: outside)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: outside.path)
        let audio = try await store.audioFolder(for: created.id)
        try FileManager.default.createSymbolicLink(
            at: audio.appending(path: "me.caf"), withDestinationURL: outside)
        #expect(try await store.sizeOnDisk(of: created.id).audioBytes == 0)
        try await store.applyAudioRetention(.days7, now: now)
        #expect(FileManager.default.fileExists(atPath: outside.path))

        // An audio folder that is a link is refused.
        let bad = try await store.create(title: "B", startDate: now)
        try FileManager.default.removeItem(at: fixture.file("audio", of: bad.id))
        try FileManager.default.createSymbolicLink(
            at: fixture.file("audio", of: bad.id), withDestinationURL: fixture.base)
        await #expect(throws: MeetingStoreError.symbolicLinkRefused) {
            _ = try await store.audioFolder(for: bad.id)
        }
    }

    // MARK: Diagnostics

    @Test("Diagnostics events hold counts and codes only")
    func diagnosticsEvents() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let diagnostics = RecordingMeetingDiagnostics()
        let store = fixture.makeStore(diagnostics: diagnostics)
        let created = try await store.create(
            title: "SECRET-TITLE", startDate: LibrarySample.startDate)
        _ = try await store.appendTurns(
            [LibrarySample.turn(1, text: "SECRET-WORDS")], to: created.id, expectedVersion: 1)
        _ = try await store.search("secret", limit: 5)
        try await store.delete(created.id)
        let dump = "\(diagnostics.events)"
        #expect(!dump.contains("SECRET"))
        #expect(
            diagnostics.events.contains {
                if case .libraryIndexRebuilt = $0 { return true }
                return false
            })
        #expect(
            diagnostics.events.contains {
                if case .libraryWrite(.written, _) = $0 { return true }
                return false
            })
    }
}
