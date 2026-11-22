import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A real `MeetingStore` at a temporary root, with one ready meeting and one
/// meeting that is still processing. All data is synthetic.
@MainActor
private final class ToolFixture {
    static let marker = "zqxmarkerroot"

    let base: URL
    let store: MeetingStore
    var access: MeetingAgentAccess = .off
    var storeCalls = 0
    private(set) var ready: MeetingSummaryRecord!
    private(set) var processing: MeetingSummaryRecord!

    init() {
        base = FileManager.default.temporaryDirectory
            .appending(path: "\(Self.marker)-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = MeetingStore(
            rootDirectory: base.appending(path: "Library", directoryHint: .isDirectory),
            snapshotRoot: base.appending(path: "Snapshots", directoryHint: .isDirectory))
    }

    func service() -> MeetingAgentToolService {
        MeetingAgentToolService(
            access: { [unowned self] in access },
            store: { [unowned self] in
                storeCalls += 1
                return store
            })
    }

    func seed() async throws {
        let start = Date(timeIntervalSince1970: 1_795_428_900)
        var made = try await store.create(title: "Budget review", startDate: start)
        var turns: [MeetingTurn] = (1...45).map { number in
            MeetingTurn(
                id: MeetingTurnID(number), track: number.isMultiple(of: 2) ? .them : .me,
                speaker: number.isMultiple(of: 2) ? .speaker(1) : .me,
                start: Double(number) * 10, end: Double(number) * 10 + 5,
                text: number == 7 ? "We agreed the pelican budget" : "plain turn \(number)")
        }
        turns.append(
            MeetingTurn(
                id: MeetingTurnID(46), track: .me, speaker: .me, start: 470, end: 475,
                text: "echoed walrus words", isEcho: true))
        var version = try await store.appendTurns(
            turns, to: made.id, expectedVersion: made.version)
        version = try await store.renameSpeaker(
            .speaker(1), to: "Asha", in: made.id, expectedVersion: version)
        _ = try await store.setState(.ready, of: made.id, expectedVersion: version)
        ready = try await store.summary(of: made.id)

        made = try await store.create(
            title: "Pelican draft", startDate: start.addingTimeInterval(3_600))
        let other = [
            MeetingTurn(
                id: MeetingTurnID(1), track: .me, speaker: .me, start: 1, end: 2,
                text: "pelican secret plan")
        ]
        version = try await store.appendTurns(other, to: made.id, expectedVersion: made.version)
        _ = try await store.setState(.processing, of: made.id, expectedVersion: version)
        processing = try await store.summary(of: made.id)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

@MainActor
@Suite("Meeting tools for agents: the app service")
struct MeetingAgentToolServiceTests {
    private static func call(_ name: String, _ arguments: [String: Any] = [:]) throws
        -> CanvasAgentToolCall
    {
        try CanvasAgentToolCall.parse(tool: name, arguments: arguments)
    }

    /// The text an agent would see: the error, else the encoded result.
    private static func agentText(_ response: CanvasBridgeResponse) -> String {
        if let error = response.error { return error }
        return response.toolResult?.agentJSON().map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    @Test("Switch off: access says off, search and read refuse, and the store is never asked")
    func switchOff() async throws {
        let fixture = ToolFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let service = fixture.service()

        let access = await service.perform(try Self.call("meeting_access"))
        #expect(access.error == nil)
        #expect(access.toolResult?.meeting == MeetingAgentToolReplies.access(.off))

        let search = await service.perform(try Self.call("meeting_search", ["query": "pelican"]))
        #expect(search.error == MeetingAgentAccessGate.refusalMessage)
        #expect(search.toolResult == nil)

        let list = await service.perform(try Self.call("meeting_search"))
        #expect(list.error == MeetingAgentAccessGate.refusalMessage)

        let read = await service.perform(
            try Self.call("meeting_read", ["meeting_id": fixture.ready.id.uuidString]))
        #expect(read.error == MeetingAgentAccessGate.refusalMessage)
        #expect(read.toolResult == nil)

        #expect(fixture.storeCalls == 0)
    }

    @Test("Switch on: search finds the ready meeting with a turn id; processing never shows")
    func switchOnSearch() async throws {
        let fixture = ToolFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        fixture.access = .on
        let service = fixture.service()

        let access = await service.perform(try Self.call("meeting_access"))
        #expect(access.toolResult?.meeting?.access == "on")

        let search = await service.perform(try Self.call("meeting_search", ["query": "pelican"]))
        let hits = try #require(search.toolResult?.meeting?.hits)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.meetingID == fixture.ready.id.uuidString })
        #expect(hits.contains { $0.turnID == "t7" })
        let searchText = Self.agentText(search)
        #expect(!searchText.contains(fixture.processing.id.uuidString))
        #expect(!searchText.contains("secret"))

        let list = await service.perform(try Self.call("meeting_search"))
        let meetings = try #require(list.toolResult?.meeting?.meetings)
        #expect(meetings.map(\.meetingID) == [fixture.ready.id.uuidString])
        #expect(meetings.first?.state == "ready")
    }

    @Test("Read pages by 40 with next_after, names show, echo turns are absent")
    func readPages() async throws {
        let fixture = ToolFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        fixture.access = .on
        let service = fixture.service()
        let id = fixture.ready.id.uuidString

        let first = await service.perform(try Self.call("meeting_read", ["meeting_id": id]))
        let page1 = try #require(first.toolResult?.meeting)
        #expect(page1.turns?.count == 40)
        #expect(page1.nextAfter == "t40")
        #expect(page1.title == "Budget review")
        #expect(page1.speakers == ["Me", "Asha"])
        #expect(page1.turns?[1].speaker == "Asha")

        let second = await service.perform(
            try Self.call("meeting_read", ["meeting_id": id, "after": "t40"]))
        let page2 = try #require(second.toolResult?.meeting)
        // Turns 41 to 45; turn 46 is an echo and is left out.
        #expect(page2.turns?.map(\.id) == ["t41", "t42", "t43", "t44", "t45"])
        #expect(page2.nextAfter == nil)
        #expect(!Self.agentText(second).contains("walrus"))
        #expect(!Self.agentText(first).contains("walrus"))
    }

    @Test("An unknown id and a processing meeting give the same error")
    func noProbing() async throws {
        let fixture = ToolFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        fixture.access = .on
        let service = fixture.service()

        let unknown = await service.perform(
            try Self.call("meeting_read", ["meeting_id": UUID().uuidString]))
        let processing = await service.perform(
            try Self.call("meeting_read", ["meeting_id": fixture.processing.id.uuidString]))
        #expect(unknown.error == MeetingAgentAccessGate.noSuchMeetingMessage)
        #expect(processing.error == unknown.error)
        #expect(processing.toolResult == nil)
    }

    @Test("The switch is read at each call")
    func switchReadEachCall() async throws {
        let fixture = ToolFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        fixture.access = .on
        let service = fixture.service()
        let id = fixture.ready.id.uuidString

        let allowed = await service.perform(try Self.call("meeting_read", ["meeting_id": id]))
        #expect(allowed.toolResult?.meeting?.turns?.isEmpty == false)
        fixture.access = .off
        let calls = fixture.storeCalls
        let refused = await service.perform(try Self.call("meeting_read", ["meeting_id": id]))
        #expect(refused.error == MeetingAgentAccessGate.refusalMessage)
        #expect(fixture.storeCalls == calls)
        let access = await service.perform(try Self.call("meeting_access"))
        #expect(access.toolResult?.meeting?.access == "off")
        fixture.access = .on
        let again = await service.perform(try Self.call("meeting_access"))
        #expect(again.toolResult?.meeting?.access == "on")
    }

    @Test("No reply holds the library path, and no store means Meetings is not available")
    func noPathAndNoStore() async throws {
        let fixture = ToolFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        fixture.access = .on
        let service = fixture.service()
        let id = fixture.ready.id.uuidString
        let calls: [CanvasAgentToolCall] = [
            try Self.call("meeting_access"),
            try Self.call("meeting_search", ["query": "pelican"]),
            try Self.call("meeting_search", ["query": ToolFixture.marker]),
            try Self.call("meeting_search"),
            try Self.call("meeting_read", ["meeting_id": id]),
            try Self.call("meeting_read", ["meeting_id": id, "after": "t40"]),
            try Self.call("meeting_read", ["meeting_id": UUID().uuidString]),
        ]
        for call in calls {
            let text = Self.agentText(await service.perform(call))
            #expect(!text.contains(ToolFixture.marker), Comment(rawValue: call.tool.rawValue))
            #expect(!text.contains("/Library"), Comment(rawValue: call.tool.rawValue))
        }

        let empty = MeetingAgentToolService(access: { .on }, store: { nil })
        let read = await empty.perform(try Self.call("meeting_read", ["meeting_id": id]))
        #expect(read.error == MeetingAgentAccessGate.unavailableMessage)
    }

    @Test("A store error never passes its own text to the agent")
    func storeErrorIsMapped() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "\(ToolFixture.marker)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        // A file where the library folder should be: each read fails.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: "Library")
        try Data("x".utf8).write(to: root)
        let store = MeetingStore(rootDirectory: root, snapshotRoot: base.appending(path: "S"))
        let service = MeetingAgentToolService(access: { .on }, store: { store })
        for call in [
            try Self.call("meeting_search", ["query": "pelican"]),
            try Self.call("meeting_read", ["meeting_id": UUID().uuidString]),
        ] {
            let text = Self.agentText(await service.perform(call))
            #expect(!text.contains(ToolFixture.marker))
        }
    }
}
