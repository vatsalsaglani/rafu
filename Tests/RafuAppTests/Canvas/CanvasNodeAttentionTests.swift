import Foundation
import RafuCore
import Testing

@testable import RafuApp

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Ensemble attention records")
struct CanvasNodeAttentionTests {
    @Test("Attention halves every seven days and never grows")
    func decay() {
        let record = CanvasNodeAttention(seconds: 800, lastFocused: epoch)
        #expect(record.decayed(at: epoch) == 800)
        #expect(abs(record.decayed(at: epoch.addingTimeInterval(7 * 86_400)) - 400) < 1e-6)
        #expect(abs(record.decayed(at: epoch.addingTimeInterval(14 * 86_400)) - 200) < 1e-6)
        // A clock that went backwards does not inflate the value.
        #expect(record.decayed(at: epoch.addingTimeInterval(-3_600)) == 800)
    }

    @Test("Merging adds time and keeps the later date, in any order")
    func merging() throws {
        let id = CanvasCardID()
        let early = [id: CanvasNodeAttention(seconds: 100, lastFocused: epoch)]
        let late = [
            id: CanvasNodeAttention(seconds: 50, lastFocused: epoch.addingTimeInterval(7 * 86_400))
        ]
        let one = try #require(CanvasAttention.merged(early, adding: late)[id])
        let two = try #require(CanvasAttention.merged(late, adding: early)[id])
        #expect(one.lastFocused == late[id]?.lastFocused)
        #expect(abs(one.seconds - 100) < 1e-6)  // 100 halved once, plus 50
        #expect(abs(one.seconds - two.seconds) < 1e-6)
    }

    @Test("Seconds are capped at 100 hours")
    func secondsCap() throws {
        let id = CanvasCardID()
        let huge = [id: CanvasNodeAttention(seconds: 10_000_000, lastFocused: epoch)]
        let merged = try #require(CanvasAttention.merged([:], adding: huge)[id])
        #expect(merged.seconds == CanvasLimits.attentionMaxSeconds)
        let again = try #require(CanvasAttention.merged(huge, adding: huge)[id])
        #expect(again.seconds == CanvasLimits.attentionMaxSeconds)
    }

    @Test("Pruning drops gone cards, old entries, junk and keeps at most 100 cards")
    func pruning() {
        let live = CanvasCardID()
        let gone = CanvasCardID()
        let old = CanvasCardID()
        let junk = CanvasCardID()
        let future = CanvasCardID()
        let records: CanvasAttention.Records = [
            live: .init(seconds: 500, lastFocused: epoch.addingTimeInterval(-86_400)),
            gone: .init(seconds: 500, lastFocused: epoch),
            old: .init(seconds: 500, lastFocused: epoch.addingTimeInterval(-91 * 86_400)),
            junk: .init(seconds: .nan, lastFocused: epoch),
            future: .init(seconds: 500, lastFocused: epoch.addingTimeInterval(10 * 86_400)),
        ]
        let pruned = CanvasAttention.pruned(records, live: [live, old, junk, future], now: epoch)
        #expect(Set(pruned.keys) == [live, future])
        // A date in the future is pulled back to now.
        #expect(pruned[future]?.lastFocused == epoch)

        let many = Dictionary(
            uniqueKeysWithValues: (0..<150).map {
                (CanvasCardID(), CanvasNodeAttention(seconds: 100 + Double($0), lastFocused: epoch))
            })
        let capped = CanvasAttention.pruned(many, live: nil, now: epoch)
        #expect(capped.count == CanvasLimits.cards)
        // The least attended are the ones that go.
        #expect(capped.values.map(\.seconds).min() == 150)
    }

    @Test("Scores are decayed seconds and last-focused dates")
    func scores() {
        let id = CanvasCardID()
        let result = CanvasAttention.scores(
            [id: .init(seconds: 80, lastFocused: epoch)], at: epoch.addingTimeInterval(7 * 86_400))
        #expect(abs((result.seconds[id] ?? 0) - 40) < 1e-6)
        #expect(result.lastFocused[id] == epoch)
    }
}

@Suite("Ensemble attention clock")
struct CanvasAttentionClockTests {
    @Test("Content time counts fully and focus without content counts 30 percent")
    func weights() throws {
        let id = CanvasCardID()
        var clock = CanvasAttentionClock()
        let opened = clock.move(to: .init(card: id, contentIsActive: false), at: epoch)
        #expect(opened == nil)
        let focusSample = clock.move(
            to: .init(card: id, contentIsActive: true), at: epoch.addingTimeInterval(100))
        let focusOnly = try #require(focusSample)
        #expect(abs(focusOnly.seconds - 30) < 1e-9)
        let contentSample = clock.move(to: nil, at: epoch.addingTimeInterval(160))
        let content = try #require(contentSample)
        #expect(abs(content.seconds - 60) < 1e-9)
        #expect(content.card == id && content.end == epoch.addingTimeInterval(160))
    }

    @Test("An unchanged focus records nothing and short stretches are dropped")
    func noChurn() {
        let id = CanvasCardID()
        var clock = CanvasAttentionClock()
        _ = clock.move(to: .init(card: id, contentIsActive: true), at: epoch)
        let same = clock.move(
            to: .init(card: id, contentIsActive: true), at: epoch.addingTimeInterval(500))
        #expect(same == nil)
        // Arrow-key navigation: under a second is not attention.
        _ = clock.fold(at: epoch.addingTimeInterval(500))
        let folded = clock.fold(at: epoch.addingTimeInterval(500.5))
        #expect(folded == nil)
        let closed = clock.move(to: nil, at: epoch.addingTimeInterval(500.5))
        #expect(closed == nil)
    }

    @Test("One stretch counts at most 30 minutes")
    func segmentCap() throws {
        let id = CanvasCardID()
        var clock = CanvasAttentionClock()
        _ = clock.move(to: .init(card: id, contentIsActive: true), at: epoch)
        let closed = clock.move(to: nil, at: epoch.addingTimeInterval(86_400))
        let sample = try #require(closed)
        #expect(sample.seconds == CanvasLimits.attentionSegmentSeconds)
    }

    @Test("Folding keeps the same focus running")
    func folding() throws {
        let id = CanvasCardID()
        var clock = CanvasAttentionClock()
        _ = clock.move(to: .init(card: id, contentIsActive: true), at: epoch)
        let firstSample = clock.fold(at: epoch.addingTimeInterval(40))
        let secondSample = clock.move(to: nil, at: epoch.addingTimeInterval(100))
        let first = try #require(firstSample)
        let second = try #require(secondSample)
        #expect(first.seconds == 40 && second.seconds == 60)
    }
}

@Suite("Ensemble attention on a board")
@MainActor
struct CanvasBoardAttentionTests {
    private func board() -> CanvasBoardState {
        var document = CanvasDocument(title: "Attention")
        document.cards = (0..<2).map {
            CanvasCard(
                title: "Card \($0)", rect: CanvasRect(x: Double($0) * 400, y: 0),
                content: .note(snapshot: ""))
        }
        return CanvasBoardState(document: document)
    }

    @Test("Focus transitions accumulate; selection does not")
    func accumulation() throws {
        let board = board()
        let first = board.cards[0].id
        board.resumeAttention(now: epoch)
        // Plain selection (marquee, Select All) is not attention.
        board.selection = Set(board.cards.map(\.id))
        board.attentionFocusChanged(now: epoch.addingTimeInterval(50))
        #expect(board.attentionPending.isEmpty)

        board.focusedCardID = first
        board.attentionFocusChanged(now: epoch.addingTimeInterval(100))
        board.contentIsActive = true
        board.attentionFocusChanged(now: epoch.addingTimeInterval(110))
        board.suspendAttention(now: epoch.addingTimeInterval(130))
        // 10 s focused at 0.3, then 20 s in content at 1.0.
        let pending = try #require(board.attentionPending[first])
        #expect(abs(pending.seconds - 23) < 1e-3)
        #expect(pending.lastFocused == epoch.addingTimeInterval(130))
        #expect(board.attentionPending.count == 1)

        // A suspended board gathers nothing, even if focus changes.
        board.focusedCardID = board.cards[1].id
        board.attentionFocusChanged(now: epoch.addingTimeInterval(500))
        #expect(board.attentionPending.count == 1)

        let delta = board.takeAttentionDelta(now: epoch.addingTimeInterval(600))
        #expect(delta.count == 1 && board.attentionPending.isEmpty)
        board.restoreAttentionDelta(delta)
        #expect(abs((board.attentionPending[first]?.seconds ?? 0) - 23) < 1e-3)
    }

    @Test("Scores include saved, unflushed and running time, decayed")
    func scores() {
        let board = board()
        let first = board.cards[0].id
        let second = board.cards[1].id
        board.adoptSavedAttention([
            first: .init(seconds: 800, lastFocused: epoch.addingTimeInterval(-7 * 86_400))
        ])
        board.resumeAttention(now: epoch)
        board.focusedCardID = second
        board.contentIsActive = true
        board.attentionFocusChanged(now: epoch)
        let scores = board.attentionScores(at: epoch.addingTimeInterval(60))
        #expect(abs((scores.seconds[first] ?? 0) - 400) < 0.5)
        #expect(abs((scores.seconds[second] ?? 0) - 60) < 1e-6)
        #expect(scores.lastFocused[second] == epoch.addingTimeInterval(60))
    }

    @Test("A routine flush is requested at most every 30 seconds")
    func flushThrottle() {
        let board = board()
        var requests = 0
        board.requestAttentionFlush = { requests += 1 }
        board.resumeAttention(now: epoch)
        board.focusedCardID = board.cards[0].id
        board.attentionFocusChanged(now: epoch)
        board.focusedCardID = board.cards[1].id
        board.attentionFocusChanged(now: epoch.addingTimeInterval(5))
        #expect(requests == 1)
        _ = board.takeAttentionDelta(now: epoch.addingTimeInterval(6))
        board.focusedCardID = board.cards[0].id
        board.attentionFocusChanged(now: epoch.addingTimeInterval(20))
        #expect(requests == 1)
        board.focusedCardID = board.cards[1].id
        board.attentionFocusChanged(now: epoch.addingTimeInterval(40))
        #expect(requests == 2)
    }
}

@Suite("Ensemble attention sidecar")
struct CanvasAttentionSidecarTests {
    private func makeStore() -> (CanvasPersistenceStore, URL, TerminalGroupWorkspaceKey) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root.appending(path: "work"))
        return (CanvasPersistenceStore(directory: root), root, key)
    }

    private func sidecarURL(_ root: URL, _ key: TerminalGroupWorkspaceKey) -> URL {
        root.appending(path: String(key.rawValue.dropFirst(7)))
            .appending(path: CanvasPersistenceStore.attentionFileName)
    }

    @Test("Attention round-trips, merges, and the file is private and holds numbers only")
    func roundTrip() async throws {
        let (store, root, key) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = CanvasID()
        let card = CanvasCardID()
        let delta = [card: CanvasNodeAttention(seconds: 90, lastFocused: epoch)]
        let saved = try #require(
            await store.recordAttention(
                board, delta: delta, live: [card], workspace: key, now: epoch))
        #expect(saved[card]?.seconds == 90)
        let again = try #require(
            await store.recordAttention(
                board, delta: delta, live: [card], workspace: key, now: epoch))
        #expect(again[card]?.seconds == 180)
        let loaded = await store.loadAttention(board, workspace: key, now: epoch)
        #expect(loaded[card]?.seconds == 180)
        #expect(loaded[card]?.lastFocused == epoch)

        let url = sidecarURL(root, key)
        let permissions =
            try FileManager.default.attributesOfItem(atPath: url.path)[
                .posixPermissions] as? Int
        #expect(permissions == 0o600)
        // Only ids, durations and dates: no title, path or text key.
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "boards"])
        let boards = try #require(object["boards"] as? [[String: Any]])
        #expect(Set(boards[0].keys) == ["id", "cards"])
        let cards = try #require(boards[0]["cards"] as? [[String: Any]])
        #expect(Set(cards[0].keys) == ["id", "seconds", "lastFocused"])
    }

    @Test("Cards that are gone and entries older than 90 days are dropped on write")
    func prunesOnWrite() async throws {
        let (store, root, key) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = CanvasID()
        let keep = CanvasCardID()
        let gone = CanvasCardID()
        let stale = CanvasCardID()
        let delta: CanvasAttention.Records = [
            keep: .init(seconds: 60, lastFocused: epoch),
            gone: .init(seconds: 60, lastFocused: epoch),
            stale: .init(seconds: 60, lastFocused: epoch.addingTimeInterval(-100 * 86_400)),
        ]
        let saved = try #require(
            await store.recordAttention(
                board, delta: delta, live: [keep, stale], workspace: key, now: epoch))
        #expect(Set(saved.keys) == [keep])
    }

    @Test("At most ten boards are kept and a deleted board is forgotten")
    func boardCap() async throws {
        let (store, root, key) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let boards = (0..<12).map { _ in CanvasID() }
        for (offset, board) in boards.enumerated() {
            let card = CanvasCardID()
            _ = await store.recordAttention(
                board,
                delta: [
                    card: .init(
                        seconds: 60, lastFocused: epoch.addingTimeInterval(Double(offset) * 60))
                ],
                live: [card], workspace: key, now: epoch.addingTimeInterval(1_000))
        }
        let later = epoch.addingTimeInterval(1_000)
        var present = 0
        for board in boards {
            if !(await store.loadAttention(board, workspace: key, now: later)).isEmpty {
                present += 1
            }
        }
        #expect(present == CanvasLimits.boards)
        // The newest board stays; the oldest went.
        #expect(await store.loadAttention(boards[0], workspace: key, now: later).isEmpty)
        #expect(!(await store.loadAttention(boards[11], workspace: key, now: later)).isEmpty)
        await store.forgetAttention(boards[11], workspace: key, now: later)
        #expect(await store.loadAttention(boards[11], workspace: key, now: later).isEmpty)
    }

    @Test("A corrupt, oversized or wrong-version sidecar loads as empty and is replaced")
    func badSidecar() async throws {
        let (store, root, key) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = CanvasID()
        let card = CanvasCardID()
        let delta = [card: CanvasNodeAttention(seconds: 60, lastFocused: epoch)]
        _ = await store.recordAttention(
            board, delta: delta, live: [card], workspace: key, now: epoch)
        let url = sidecarURL(root, key)

        try Data("{ not json".utf8).write(to: url)
        #expect(await store.loadAttention(board, workspace: key, now: epoch).isEmpty)

        try Data(repeating: 0x20, count: CanvasLimits.attentionFileBytes + 10).write(to: url)
        #expect(await store.loadAttention(board, workspace: key, now: epoch).isEmpty)

        try Data(#"{"version":99,"boards":[]}"#.utf8).write(to: url)
        #expect(await store.loadAttention(board, workspace: key, now: epoch).isEmpty)

        // The next write starts clean.
        let saved = await store.recordAttention(
            board, delta: delta, live: [card], workspace: key, now: epoch)
        #expect(saved?[card]?.seconds == 60)
    }

    @Test("A symbolic link is not followed")
    func symlink() async throws {
        let (store, root, key) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let board = CanvasID()
        let card = CanvasCardID()
        let delta = [card: CanvasNodeAttention(seconds: 60, lastFocused: epoch)]
        _ = await store.recordAttention(
            board, delta: delta, live: [card], workspace: key, now: epoch)
        let url = sidecarURL(root, key)
        let target = root.appending(path: "real.json")
        try FileManager.default.moveItem(at: url, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(await store.loadAttention(board, workspace: key, now: epoch).isEmpty)
    }
}
