import Foundation

nonisolated struct ServerSentEvent: Equatable, Sendable {
    var event: String
    var data: String
    var id: String?
}

nonisolated struct ServerSentEventParser: Sendable {
    static let maximumEventBytes = 1_024 * 1_024

    private var eventName: String?
    private var dataLines: [String] = []
    private var eventID: String?
    private var eventBytes = 0

    mutating func consume(line: String) throws -> ServerSentEvent? {
        if line.isEmpty { return dispatchEvent() }
        if line.first == ":" { return nil }

        let field: Substring
        let value: Substring
        if let separator = line.firstIndex(of: ":") {
            field = line[..<separator]
            let valueStart = line.index(after: separator)
            let rawValue = line[valueStart...]
            value = rawValue.first == " " ? rawValue.dropFirst() : rawValue
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": eventName = String(value)
        case "data":
            let next = String(value)
            eventBytes += next.utf8.count
            guard eventBytes <= Self.maximumEventBytes else {
                throw AIProviderError.responseTooLarge(maximumBytes: Self.maximumEventBytes)
            }
            dataLines.append(next)
        case "id":
            if !value.contains("\0") { eventID = String(value) }
        default: break
        }
        return nil
    }

    mutating func finish() -> ServerSentEvent? {
        dispatchEvent()
    }

    private mutating func dispatchEvent() -> ServerSentEvent? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(
            event: eventName.flatMap { $0.isEmpty ? nil : $0 } ?? "message",
            data: dataLines.joined(separator: "\n"),
            id: eventID
        )
    }
}
