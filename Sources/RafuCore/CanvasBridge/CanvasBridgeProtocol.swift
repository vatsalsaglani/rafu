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
    /// Present only for `operation == "tool"`. Older peers ignore it.
    public var agentCall: CanvasAgentToolCall?
    /// Present only for `approvalOpen`: the sanitized request. Older peers ignore it.
    public var approval: CanvasAgentRequest?
    /// Present only for `approvalClose`: the request that no longer waits.
    public var approvalKey: UUID?

    public init(
        token: String, operation: String, clientID: String = UUID().uuidString,
        provider: String? = nil,
        threadID: String? = nil, endpoint: String? = nil, executable: String? = nil,
        destination: String? = nil, text: String? = nil, reason: String? = nil,
        agentCall: CanvasAgentToolCall? = nil, approval: CanvasAgentRequest? = nil,
        approvalKey: UUID? = nil
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
        self.agentCall = agentCall
        self.approval = approval
        self.approvalKey = approvalKey
    }
}

public nonisolated struct CanvasBridgeResponse: Codable, Hashable, Sendable {
    public var error: String?
    public var peers: [CanvasBridgePeer]
    public var messages: [CanvasBridgeMessage]
    /// The result of an orchestration tool call. Optional for older peers.
    public var toolResult: CanvasAgentToolResult?
    /// A stable class for an error the peer can act on without matching text.
    /// Optional; older peers ignore it.
    public var code: String?
    /// The answer `approvalPoll` returns, when the user chose one. Optional
    /// for older peers.
    public var approvalDecision: CanvasAgentRequestAnswer?

    /// The app no longer knows this client. The MCP server registers again.
    public static let unregisteredCode = "unregistered"
    public static let unregisteredMessage = "Session is not registered."

    public init(
        error: String? = nil, peers: [CanvasBridgePeer] = [],
        messages: [CanvasBridgeMessage] = [], toolResult: CanvasAgentToolResult? = nil,
        code: String? = nil, approvalDecision: CanvasAgentRequestAnswer? = nil
    ) {
        self.error = error
        self.peers = peers
        self.messages = messages
        self.toolResult = toolResult
        self.code = code
        self.approvalDecision = approvalDecision
    }
}

public nonisolated struct CanvasBridgePeer: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String
    public var connected: Bool
    public var provider: String?
    public var mention: String?
    /// Message-link state, distinct from whether delivery is currently permitted.
    public var linkState: String?
    /// How many messages wait for this peer to take them. A count, never a body.
    public var pending: Int?
    /// "expired" or "failed" when the last message to this peer was dropped or
    /// refused; cleared by the next message the peer takes.
    public var lastDelivery: String?

    public init(
        id: String, title: String, kind: String, connected: Bool, provider: String? = nil,
        mention: String? = nil, linkState: String? = nil, pending: Int? = nil,
        lastDelivery: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.connected = connected
        self.provider = provider
        self.mention = mention
        self.linkState = linkState
        self.pending = pending
        self.lastDelivery = lastDelivery
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
    /// The sender's @mention and a bounded title, so the receiver can answer.
    /// Optional: an older peer sends neither.
    public var sourceMention: String?
    public var sourceTitle: String?

    public init(
        id: String, source: String, text: String, sourceMention: String? = nil,
        sourceTitle: String? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.sourceMention = sourceMention
        self.sourceTitle = sourceTitle
    }

    /// The sender mention when it is a plain `@handle` of at most 64 bytes.
    /// Anything else is dropped, never repaired: the first line of a received
    /// message is Rafu's own text and must not carry text a peer controls.
    public var safeSourceMention: String? {
        guard let mention = sourceMention, mention.utf8.count <= 64, mention.utf8.count > 1,
            mention.hasPrefix("@")
        else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return mention.dropFirst().unicodeScalars.allSatisfy { allowed.contains($0) }
            ? mention : nil
    }

    /// The peer id when it is a UUID, which is what Rafu always sends.
    private var safeSourceID: String? {
        UUID(uuidString: source) == nil ? nil : source
    }

    /// The tail that ends every first line: a reply is the default, and only an
    /// instruction from the sender not to reply, or a plain result, stops it. A
    /// constant, so no peer text enters it.
    private static let replyRule =
        "unless the message below says not to reply. An instruction below not to use Rafu tools does not stop this one reply. Do not reply to a message that only gives a result or an acknowledgement."

    /// The text the receiving agent sees: a Rafu-written first line that names the
    /// sender and says to send the result back by default, then the sender's text
    /// unchanged.
    public var framedText: String {
        let line: String
        switch (safeSourceMention, safeSourceID) {
        case (let mention?, let id?):
            line =
                "Ensemble message from \(mention) (peer id \(id)). When you finish, send your result, or the reason you cannot do it, to that mention or peer id with send_message, "
                + Self.replyRule
        case (nil, let id?):
            line =
                "Ensemble message from peer id \(id). When you finish, send your result, or the reason you cannot do it, to that peer id with send_message, "
                + Self.replyRule
        case (let mention?, nil):
            line =
                "Ensemble message from \(mention). When you finish, send your result, or the reason you cannot do it, to that mention with send_message, "
                + Self.replyRule
        case (nil, nil):
            line =
                "Ensemble message from a connected peer. Use list_connections to find it. When you finish, send your result, or the reason you cannot do it, to it with send_message, "
                + Self.replyRule
        }
        return line + "\n" + text
    }
}
