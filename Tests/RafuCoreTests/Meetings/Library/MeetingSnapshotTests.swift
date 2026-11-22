import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting library: agent snapshot and packet")
struct MeetingSnapshotTests {
    private func seed(_ store: MeetingStore) async throws -> MeetingID {
        let created = try await store.create(
            title: "Planning", startDate: LibrarySample.startDate)
        var version = try await store.appendTurns(
            [
                LibrarySample.turn(1, .me, start: 3, text: "Hello everyone"),
                LibrarySample.turn(2, .speaker(2), start: 747, text: "Hi, I am here\nwith a note"),
                LibrarySample.turn(
                    3, .me, start: 750, text: "Hi I am here with a note", echo: true),
            ], to: created.id, expectedVersion: 1)
        version = try await store.renameSpeaker(
            .speaker(2), to: "Priya", in: created.id, expectedVersion: version)
        _ = try await store.setDuration(900, of: created.id, expectedVersion: version)
        return created.id
    }

    @Test("A snapshot holds only meeting.md and transcript.md, in a private folder")
    func snapshotHoldsTwoFiles() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let id = try await seed(store)
        // Audio and a conversation exist; neither may reach the snapshot.
        let audio = try await store.audioFolder(for: id)
        try Data(count: 64).write(to: audio.appending(path: "me.caf"))
        _ = try await store.appendConversation(
            MeetingConversationEntry(date: LibrarySample.startDate, role: .question, text: "Q"),
            to: id)

        let snapshot = try await store.makeAgentSnapshot(of: id)
        defer { snapshot.remove() }
        #expect(snapshot.meeting == id)
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshot.folder.path)
            .sorted()
        #expect(names == ["meeting.md", "transcript.md"])
        for name in names {
            let url = snapshot.folder.appending(path: name)
            let info = try #require(MeetingFileIO.lstatInfo(url))
            #expect((info.st_mode & S_IFMT) == S_IFREG, "\(name) is a regular file")
            #expect(LibraryFixture.mode(of: url) == 0o600)
            #expect(!name.hasPrefix("."))
        }
        #expect(!names.contains { ["AGENTS.md", "CLAUDE.md"].contains($0.uppercased()) })
        #expect(LibraryFixture.mode(of: snapshot.folder) == 0o700)
        #expect(LibraryFixture.mode(of: fixture.snapshotRoot) == 0o700)
        // The folder is below the injected snapshot root and not in the library.
        #expect(snapshot.folder.path.hasPrefix(fixture.snapshotRoot.path))
        #expect(!snapshot.folder.path.hasPrefix(fixture.root.path))

        // The snapshot is frozen: a later edit does not change it.
        let transcript = try String(contentsOf: snapshot.transcriptURL, encoding: .utf8)
        _ = try await store.rename(id, title: "Changed", expectedVersion: 4)
        #expect(try String(contentsOf: snapshot.transcriptURL, encoding: .utf8) == transcript)

        snapshot.remove()
        #expect(!FileManager.default.fileExists(atPath: snapshot.folder.path))
        snapshot.remove()
    }

    @Test("The snapshot text has turn ids, confirmed names, no echo turn and no audio path")
    func snapshotText() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let id = try await seed(store)
        let snapshot = try await store.makeAgentSnapshot(of: id)
        defer { snapshot.remove() }
        let transcript = try String(contentsOf: snapshot.transcriptURL, encoding: .utf8)
        #expect(
            transcript
                == "[t1 00:03] Me: Hello everyone\n[t2 12:27] Priya: Hi, I am here with a note\n")
        let overview = try String(contentsOf: snapshot.overviewURL, encoding: .utf8)
        #expect(overview.hasPrefix("# Meeting\n\nTitle: Planning\nDate: "))
        #expect(overview.contains("Length: 15:00\n"))
        #expect(overview.hasSuffix("Speakers: Me, Priya\n"))
        #expect(!overview.contains(fixture.base.path))
        #expect(!transcript.contains(fixture.base.path))
    }

    @Test("The packet is the same text as one string")
    func packetText() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let id = try await seed(store)
        let snapshot = try await store.makeAgentSnapshot(of: id)
        defer { snapshot.remove() }
        let packet = try await store.agentPacketText(of: id)
        let overview = try String(contentsOf: snapshot.overviewURL, encoding: .utf8)
        let transcript = try String(contentsOf: snapshot.transcriptURL, encoding: .utf8)
        #expect(
            packet == "=== meeting.md ===\n" + overview + "\n=== transcript.md ===\n" + transcript)
    }

    @Test("A snapshot of a missing meeting is a typed error and leaves no folder")
    func missingMeeting() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let missing = MeetingID()
        await #expect(throws: MeetingStoreError.notFound(missing)) {
            _ = try await store.makeAgentSnapshot(of: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotRoot.path))
    }

    @Test("Stale snapshot folders are removed after their age")
    func staleSnapshots() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let later = Date(timeIntervalSince1970: 1_800_000_000 + 7_200)
        let store = fixture.makeStore(clock: { later })
        let id = try await seed(store)
        let old = try await store.makeAgentSnapshot(of: id)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: old.folder.path)
        let fresh = try await store.makeAgentSnapshot(of: id)
        defer { fresh.remove() }
        try FileManager.default.setAttributes(
            [.modificationDate: later], ofItemAtPath: fresh.folder.path)
        await store.removeStaleSnapshots(olderThan: 3_600)
        #expect(!FileManager.default.fileExists(atPath: old.folder.path))
        #expect(FileManager.default.fileExists(atPath: fresh.folder.path))
    }
}
