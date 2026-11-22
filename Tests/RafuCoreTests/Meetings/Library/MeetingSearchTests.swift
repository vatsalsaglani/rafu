import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting library: search")
struct MeetingSearchTests {
    @Test("The tokenizer lowercases, folds diacritics and splits on punctuation")
    func tokenizer() {
        #expect(MeetingSearchTokenizer.tokens(in: "Hello, World-42!") == ["hello", "world", "42"])
        #expect(MeetingSearchTokenizer.tokens(in: "José Müller") == ["jose", "muller"])
        #expect(MeetingSearchTokenizer.tokens(in: "  ...  ").isEmpty)
        #expect(
            MeetingSearchTokenizer.tokens(in: String(repeating: "a", count: 90)).map(\.count)
                == [40, 40, 10])
    }

    @Test("Search finds titles and turns, matches word starts, and needs every word")
    func basicSearch() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let budget = try await store.create(
            title: "Budget review", startDate: Date(timeIntervalSince1970: 200))
        let other = try await store.create(
            title: "Standup", startDate: Date(timeIntervalSince1970: 100))
        _ = try await store.appendTurns(
            [
                LibrarySample.turn(1, text: "We should cut the cloud spending by ten percent"),
                LibrarySample.turn(2, .them, text: "Agreed, the budget is tight"),
            ], to: budget.id, expectedVersion: 1)
        _ = try await store.appendTurns(
            [LibrarySample.turn(1, text: "Nothing about money here, only cloud")],
            to: other.id, expectedVersion: 1)

        let budgetHits = try await store.search("budget", limit: 10)
        #expect(budgetHits.count == 2)
        #expect(budgetHits[0].turn == nil)
        #expect(budgetHits[0].snippet == "Budget review")
        #expect(budgetHits[1].turn == MeetingTurnID(2))
        #expect(budgetHits.allSatisfy { $0.meeting == budget.id })

        // A word start matches: "spend" finds "spending".
        let prefix = try await store.search("spend", limit: 10)
        #expect(prefix.map(\.turn) == [MeetingTurnID(1)])
        #expect(prefix[0].snippet.contains("spending"))

        // Newest meeting first, then the other one.
        let cloud = try await store.search("CLOUD", limit: 10)
        #expect(cloud.map(\.meeting) == [budget.id, other.id])

        // Every word must be in the same turn.
        #expect(try await store.search("cloud percent", limit: 10).count == 1)
        #expect(try await store.search("cloud budget", limit: 10).isEmpty)
        #expect(try await store.search("   ", limit: 10).isEmpty)
        #expect(try await store.search("cloud", limit: 1).count == 1)
        #expect(try await store.search("cloud", limit: 0).isEmpty)
    }

    @Test("The index follows appends, renames, text edits and title changes")
    func indexStaysCurrent() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let created = try await store.create(title: "Alpha", startDate: LibrarySample.startDate)
        // Build the index first, so later changes must update it.
        #expect(try await store.search("alpha", limit: 5).count == 1)
        var version = try await store.appendTurns(
            [LibrarySample.turn(1, text: "mispeled word")], to: created.id, expectedVersion: 1)
        #expect(try await store.search("mispeled", limit: 5).count == 1)
        version = try await store.editTurnText(
            MeetingTurnID(1), to: "spelled word", in: created.id, expectedVersion: version)
        #expect(try await store.search("mispeled", limit: 5).isEmpty)
        #expect(try await store.search("spelled", limit: 5).count == 1)
        version = try await store.rename(created.id, title: "Omega", expectedVersion: version)
        #expect(try await store.search("alpha", limit: 5).isEmpty)
        #expect(try await store.search("omega", limit: 5).count == 1)
    }

    @Test("The index made again from the files gives the same results")
    func rebuildGivesSameResults() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let diagnostics = RecordingMeetingDiagnostics()
        let store = fixture.makeStore(diagnostics: diagnostics)
        for number in 0..<6 {
            let created = try await store.create(
                title: "Meeting \(number)", startDate: Date(timeIntervalSince1970: Double(number)))
            _ = try await store.appendTurns(
                [
                    LibrarySample.turn(1, text: "roadmap item \(number) and launch plan"),
                    LibrarySample.turn(2, .them, text: "launch date for number \(number)"),
                ], to: created.id, expectedVersion: 1)
        }
        let queries = ["launch", "roadmap item", "meeting 3", "number", "zzz"]
        var before: [[MeetingSearchHit]] = []
        for query in queries { before.append(try await store.search(query, limit: 50)) }
        try await store.rebuildSearchIndex()
        var after: [[MeetingSearchHit]] = []
        for query in queries { after.append(try await store.search(query, limit: 50)) }
        #expect(before == after)
        #expect(before[0].count == 12)

        // A fresh store on the same files also gives the same results.
        let fresh = fixture.makeStore()
        var fromFiles: [[MeetingSearchHit]] = []
        for query in queries { fromFiles.append(try await fresh.search(query, limit: 50)) }
        #expect(before == fromFiles)

        let rebuilds = diagnostics.events.filter {
            if case .libraryIndexRebuilt(let meetings, _) = $0 { return meetings == 6 }
            return false
        }
        #expect(rebuilds.count == 2)
    }

    @Test("A snippet is short and centred on the match")
    func snippetCut() {
        let text =
            String(repeating: "alpha ", count: 40) + "needle "
            + String(repeating: "omega ", count: 40)
        let snippet = MeetingStore.snippet(text, for: ["needle"])
        #expect(snippet.contains("needle"))
        #expect(snippet.count <= 122)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(MeetingStore.snippet("short text", for: ["short"]) == "short text")
    }

    @Test("Search over 500 synthetic meetings answers in under 200 ms")
    func searchSpeed() async throws {
        let fixture = LibraryFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let vocabulary = [
            "budget", "roadmap", "customer", "release", "design", "launch", "incident", "review",
            "metrics", "hiring", "contract", "pricing", "feedback", "latency", "migration",
            "security", "onboarding", "forecast", "partner", "support",
        ]
        for number in 0..<500 {
            let created = try await store.create(
                title: "Synthetic meeting \(number)",
                startDate: Date(timeIntervalSince1970: Double(1_700_000_000 + number)))
            var turns: [MeetingTurn] = []
            for turnNumber in 1...20 {
                let words = (0..<14).map {
                    vocabulary[(number * 7 + turnNumber * 3 + $0 * 5) % vocabulary.count]
                }
                turns.append(
                    LibrarySample.turn(
                        turnNumber, turnNumber % 2 == 0 ? .them : .me,
                        text: words.joined(separator: " ") + " item\(number)x\(turnNumber)"))
            }
            _ = try await store.appendTurns(turns, to: created.id, expectedVersion: 1)
        }

        // The first search makes the index from the files.
        let buildStart = ContinuousClock.now
        _ = try await store.search("budget", limit: 50)
        let buildTime = ContinuousClock.now - buildStart

        var slowest: Duration = .zero
        for query in ["budget roadmap", "latency", "item250", "securi migrat", "nomatchatall"] {
            let start = ContinuousClock.now
            let hits = try await store.search(query, limit: 50)
            let elapsed = ContinuousClock.now - start
            slowest = max(slowest, elapsed)
            if query == "item250" { #expect(hits.count == 20) }
            if query == "nomatchatall" { #expect(hits.isEmpty) }
        }
        let exact = try await store.search("item250x7", limit: 50)
        #expect(exact.count == 1)
        #expect(exact.first?.turn == MeetingTurnID(7))
        #expect(
            slowest < .milliseconds(200), "slowest warm search \(slowest); first build \(buildTime)"
        )
    }
}
