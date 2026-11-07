import Foundation

/// One row of the voice session timeline (VPLAN section 11). In memory only:
/// never saved, never logged. Titles are tool names and counts; `detail`
/// holds at most 120 scalars of the user's own utterance.
public nonisolated struct VoiceTimelineEvent: Equatable, Identifiable, Sendable {
    public enum Lane: String, CaseIterable, Sendable {
        case you, voice, delegation, tool, board
    }

    public static let maximumDetailScalars = 120

    public let id: String
    public let lane: Lane
    public let startMS: Int
    public var endMS: Int?
    public let delegationID: String?
    public let persona: String
    public let title: String
    public var detail: String
    public var undoStepID: UUID?

    public init(
        id: String, lane: Lane, startMS: Int, endMS: Int? = nil, delegationID: String? = nil,
        persona: String, title: String, detail: String = "", undoStepID: UUID? = nil
    ) {
        self.id = id
        self.lane = lane
        self.startMS = startMS
        self.endMS = endMS
        self.delegationID = delegationID
        self.persona = persona
        self.title = CanvasAgentText.singleLine(title, limit: 80)
        self.detail = Self.bounded(detail)
        self.undoStepID = undoStepID
    }

    static func bounded(_ text: String) -> String {
        CanvasAgentText.singleLine(text, limit: maximumDetailScalars)
    }
}

/// The session's rows, newest last, at most 500. Cleared when the session closes.
public nonisolated struct VoiceTimeline: Equatable, Sendable {
    public static let capacity = 500

    public private(set) var events: [VoiceTimelineEvent] = []
    private var nextNumber = 1

    public init() {}

    /// Appends a row and returns its id ("#1", "#2", …).
    @discardableResult
    public mutating func append(
        lane: VoiceTimelineEvent.Lane, startMS: Int, delegationID: String? = nil,
        persona: String, title: String, detail: String = ""
    ) -> String {
        let id = "#\(nextNumber)"
        nextNumber += 1
        events.append(
            VoiceTimelineEvent(
                id: id, lane: lane, startMS: startMS, delegationID: delegationID,
                persona: persona, title: title, detail: detail))
        if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
        return id
    }

    /// Adds text to a row's detail (for a transcript that arrives in pieces),
    /// still bounded to 120 scalars.
    public mutating func appendDetail(_ text: String, to id: String) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].detail = VoiceTimelineEvent.bounded(events[index].detail + text)
    }

    public mutating func finish(_ id: String, endMS: Int, detail: String? = nil) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].endMS = endMS
        if let detail { events[index].detail = VoiceTimelineEvent.bounded(detail) }
    }

    public func rows(lane: VoiceTimelineEvent.Lane) -> [VoiceTimelineEvent] {
        events.filter { $0.lane == lane }
    }

    public mutating func clear() {
        events.removeAll()
        nextNumber = 1
    }
}
