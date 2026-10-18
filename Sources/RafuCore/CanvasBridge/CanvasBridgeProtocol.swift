import Foundation

/// Private, local transport messages. The token must never be written to logs.
public nonisolated struct CanvasBridgeRequest: Codable, Hashable, Sendable {
    public var token: String
    public var clientID: String
    public var operation: String
    public var provider: String?
    public var threadID: String?
    public var endpoint: String?
    public var executable: String?
    public var destination: String?
    public var text: String?
    public var reason: String?

    public init(
        token: String, operation: String, clientID: String = UUID().uuidString,
        provider: String? = nil,
        threadID: String? = nil, endpoint: String? = nil, executable: String? = nil,
        destination: String? = nil, text: String? = nil, reason: String? = nil
    ) {
        self.token = token
        self.clientID = clientID
        self.operation = operation
        self.provider = provider
        self.threadID = threadID
        self.endpoint = endpoint
        self.executable = executable
        self.destination = destination
        self.text = text
        self.reason = reason
    }
}

public nonisolated struct CanvasBridgeResponse: Codable, Hashable, Sendable {
    public var error: String?
    public var peers: [CanvasBridgePeer]
    public var messages: [CanvasBridgeMessage]

    public init(
        error: String? = nil, peers: [CanvasBridgePeer] = [],
        messages: [CanvasBridgeMessage] = []
    ) {
        self.error = error
        self.peers = peers
        self.messages = messages
    }
}

public nonisolated struct CanvasBridgePeer: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String
    public var connected: Bool
    public var provider: String?
    public var mention: String?

    public init(
        id: String, title: String, kind: String, connected: Bool, provider: String? = nil,
        mention: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.connected = connected
        self.provider = provider
        self.mention = mention
    }

    /// A display-name alias, not an identity. Duplicate aliases require an explicit peer ID.
    /// The byte bound leaves room for every peer in the bounded IPC response.
    public static func mention(for title: String) -> String {
        let folded = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var handle = ""
        var needsSeparator = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let addition = (needsSeparator && !handle.isEmpty ? "-" : "") + String(scalar)
                guard handle.utf8.count + addition.utf8.count <= 40 else { break }
                handle += addition
                needsSeparator = false
            } else if !handle.isEmpty {
                needsSeparator = true
            }
        }
        return "@" + (handle.isEmpty ? "terminal" : handle)
    }
}

public nonisolated struct CanvasBridgeMessage: Codable, Hashable, Sendable {
    public var id: String
    public var source: String
    public var text: String

    public init(id: String, source: String, text: String) {
        self.id = id
        self.source = source
        self.text = text
    }
}
