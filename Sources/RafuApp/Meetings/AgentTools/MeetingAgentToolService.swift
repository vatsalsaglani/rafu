import Foundation
import RafuCore

/// Runs the three read-only meeting tools for agents in Ensemble terminals:
/// `meeting_access`, `meeting_search` and `meeting_read`.
///
/// Each call reads Settings ▸ Meetings ▸ "Allow agents to read your
/// meetings" first, at the time of the call. With the switch off, a call
/// gives no meeting data, no title and no count, and does not ask for the
/// store (so the Meetings feature is not made). The tools take ids, never
/// paths, never write and never start a process.
@MainActor
final class MeetingAgentToolService {
    private let access: () -> MeetingAgentAccess
    private let store: () -> (any MeetingStoring)?

    /// - Parameters:
    ///   - access: reads the switch. Called once at the start of each call.
    ///   - store: gives the library, or nil when Meetings is not available.
    ///     Called only when the switch is on.
    init(
        access: @escaping () -> MeetingAgentAccess,
        store: @escaping () -> (any MeetingStoring)?
    ) {
        self.access = access
        self.store = store
    }

    /// The service of the app: the switch from the standard user defaults,
    /// the store from the shared Meetings feature.
    static let shared = MeetingAgentToolService(
        access: { UserDefaultsMeetingPreferences().agentAccess() },
        store: {
            // Reached only with the switch on: an agent call with the switch
            // off never makes the Meetings feature.
            let feature = MeetingsFeatureFactory.shared.resolve()
            return feature.availability.isAvailable ? feature.store : nil
        })

    func perform(_ call: CanvasAgentToolCall) async -> CanvasBridgeResponse {
        // The first step of each tool: read the switch now, never a cached value.
        let current = access()
        if call.tool == .meetingAccess {
            return Self.reply(MeetingAgentToolReplies.access(current))
        }
        if case .failure(let denied) = MeetingAgentAccessGate.check(current) {
            return .init(error: denied.message)
        }
        guard let store = store() else {
            return .init(error: MeetingAgentAccessGate.unavailableMessage)
        }
        do {
            switch call.tool {
            case .meetingSearch: return try await search(call, store: store)
            case .meetingRead: return try await read(call, store: store)
            default: return .init(error: CanvasAgentToolError.unknownTool.message)
            }
        } catch {
            // A library error can hold a path: never pass its text on.
            return .init(error: MeetingAgentAccessGate.readFailedMessage)
        }
    }

    // MARK: Tools

    private func search(_ call: CanvasAgentToolCall, store: any MeetingStoring) async throws
        -> CanvasBridgeResponse
    {
        let limit = MeetingAgentToolReplies.clamped(
            call.limit ?? MeetingAgentToolLimits.defaultSearchLimit,
            to: MeetingAgentToolLimits.searchLimits)
        guard let query = call.query else {
            return Self.reply(MeetingAgentToolReplies.list(try await store.list(), limit: limit))
        }
        // Ask for more hits than the limit: hits in meetings that are not
        // ready are left out after the search.
        let hits = try await store.search(query, limit: limit * 4)
        var summaries: [MeetingID: MeetingSummaryRecord] = [:]
        for meeting in Set(hits.map { $0.meeting }) {
            if let summary = try await store.summary(of: meeting) { summaries[meeting] = summary }
        }
        return Self.reply(
            MeetingAgentToolReplies.search(hits, summaries: summaries, limit: limit))
    }

    private func read(_ call: CanvasAgentToolCall, store: any MeetingStoring) async throws
        -> CanvasBridgeResponse
    {
        // The same text for an unknown id and for a meeting that is not ready.
        guard let meeting = call.meetingID.flatMap(MeetingID.init(uuidString:)),
            let summary = try await store.summary(of: meeting), summary.state == .ready
        else {
            return .init(error: MeetingAgentAccessGate.noSuchMeetingMessage)
        }
        var after: MeetingTurnID?
        if let text = call.after {
            guard let parsed = MeetingTurnID(text: text) else {
                return .init(error: CanvasAgentToolError.invalidArgument("after").message)
            }
            after = parsed
        }
        let limit = MeetingAgentToolReplies.clamped(
            call.limit ?? MeetingAgentToolLimits.defaultReadLimit,
            to: MeetingAgentToolLimits.readLimits)
        let page = try await store.turns(of: meeting, after: after, limit: limit)
        let names =
            try await (store as? any MeetingLibraryServicing)?.speakerNames(of: meeting) ?? [:]
        return Self.reply(MeetingAgentToolReplies.read(summary, page: page, names: names))
    }

    private static func reply(_ reply: MeetingAgentToolReply) -> CanvasBridgeResponse {
        var result = CanvasAgentToolResult()
        result.meeting = reply
        return .init(toolResult: result)
    }
}
