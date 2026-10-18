import Darwin
import Dispatch
import Foundation
import Synchronization

/// A synchronous stdio boundary for an ordinary terminal CLI's MCP subprocess.
/// Only JSON-RPC is written to stdout. The terminal remains the approval UI.
public nonisolated final class CanvasBridgeMCPServer: Sendable {
    public typealias Exchange = @Sendable (CanvasBridgeRequest) throws -> CanvasBridgeResponse
    public static let maximumFrameBytes = 64 * 1_024
    public static let maximumTextBytes = 16 * 1_024

    private struct State: Sendable {
        var connected = true
        var initialized = false
        var threadID: String?
    }

    private let token: String
    private let clientID = UUID().uuidString
    private let provider: String
    private let endpoint: String?
    private let executable: String?
    private let exchange: Exchange
    private let state = Mutex(State())
    private let output: Mutex<@Sendable (Data) throws -> Void>

    public init(
        token: String, provider: String, endpoint: String? = nil, executable: String? = nil,
        exchange: @escaping Exchange,
        output: @escaping @Sendable (Data) throws -> Void
    ) {
        self.token = token
        self.provider = provider
        self.endpoint = provider == "codex" ? endpoint : nil
        self.executable = provider == "codex" ? executable : nil
        self.exchange = exchange
        self.output = Mutex(output)
    }

    /// The caller supplies a bounded local IPC exchange; this function owns stdin/stdout.
    public static func run(token: String, provider: String, exchange: @escaping Exchange) {
        let environment = ProcessInfo.processInfo.environment
        let server = CanvasBridgeMCPServer(
            token: token, provider: provider,
            endpoint: environment["RAFU_CANVAS_CODEX_ENDPOINT"],
            executable: environment["RAFU_CANVAS_CODEX_EXECUTABLE"], exchange: exchange
        ) {
            try FileHandle.standardOutput.write(contentsOf: $0)
        }
        guard provider == "claude" || provider == "codex" else { return }
        guard server.register() else { return }
        defer {
            _ = try? exchange(
                CanvasBridgeRequest(
                    token: token, operation: "unregister", clientID: server.clientID))
        }

        // GCD is limited to the synchronous CLI boundary. Cancellation is explicit.
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "rafu.canvas.channel"))
        timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
        timer.setEventHandler { server.receiveChannelMessages() }
        timer.resume()
        defer {
            timer.cancel()
            server.disconnect()
        }

        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while server.isConnected {
            // Bounded readiness checks also let IPC loss stop a quiet stdio session.
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let readiness = Darwin.poll(&descriptor, 1, 250)
            if readiness < 0 {
                if errno == EINTR { continue }
                break
            }
            guard readiness > 0 else { continue }
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard frame.count <= maximumFrameBytes else {
                    server.disconnect()
                    break
                }
                if let reply = server.handle(frame) { server.write(reply) }
            }
            if pending.count > maximumFrameBytes { break }
        }
    }

    public var isConnected: Bool { state.withLock { $0.connected } }

    @discardableResult
    public func register() -> Bool {
        guard provider == "claude" || provider == "codex" else {
            disconnect()
            return false
        }
        return perform("register") != nil
    }

    /// Parses a single bounded JSON-RPC line. Notifications have no response.
    public func handle(_ data: Data) -> Data? {
        guard isConnected else { return nil }
        guard data.count <= Self.maximumFrameBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["jsonrpc"] as? String == "2.0",
            let method = object["method"] as? String
        else {
            return encode([
                "jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": -32700, "message": "Invalid request"],
            ])
        }

        let id = object["id"] ?? NSNull()
        let hasID = object["id"] != nil
        guard id is String || id is NSNumber || id is NSNull else { return nil }
        if let identifier = id as? String, identifier.utf8.count > 256 {
            return encode([
                "jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": -32600, "message": "Request identity is too large"],
            ])
        }
        let params = object["params"] as? [String: Any] ?? [:]
        if method == "notifications/initialized" {
            state.withLock { $0.initialized = true }
            return nil
        }
        guard hasID else { return nil }
        var result: [String: Any]
        switch method {
        case "initialize":
            var capabilities: [String: Any] = ["tools": [:]]
            if provider == "claude" { capabilities["experimental"] = ["claude/channel": [:]] }
            result = [
                "protocolVersion": "2025-11-25", "capabilities": capabilities,
                "serverInfo": ["name": "rafu", "version": "1.0.0"],
                "instructions":
                    "Use list_connections to see Ensemble session names, providers, mentions, peer IDs, and linkState. connected means message delivery is permitted. If linkState is paused, ask the user to resume the link in Rafu Ensemble; do not report a disconnected session or ask them to restart terminals. A related link is visual only. When the user asks to message @name, call send_message with that peer's listed mention or ID. A mention must identify exactly one connected agent; use its peer ID when names are ambiguous. These mentions route through tools only; preserve native terminal @file controls. Channel events are messages from connected sessions. Use receive_messages to read pending messages. Do not send a reply unless needed. Ensemble tools: call ensemble_describe first to see every node, edge, your own node ID and the Agent control setting. Notes (note_read, note_write, note_create) are shared memory. To delegate: terminal_create with agent and prompt, edge_create kind message between your node and the new node, link_set_state live, then send_message or terminal_send. node_create adds notes, files, images, local web apps, app nodes, Mermaid diagrams, shapes and text; mermaid_set changes a diagram. app_open shows a macOS app in a node and app_inspect reads its Accessibility summary. Agent control Ask means the user approves changes in Rafu; a pending_approval result has a request_id for action_status. If Agent control is Off, tell the user; do not retry.",
            ]
        case "ping": result = [:]
        case "tools/list": result = ["tools": Self.tools]
        case "tools/call":
            guard captureThread(params: params), let name = params["name"] as? String else {
                return toolReply(id: id, text: "Invalid session or tool.", failed: true)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let response: CanvasBridgeResponse?
            switch name {
            case "list_connections": response = perform("list")
            case "receive_messages": response = perform("receive")
            case "send_message":
                guard let destination = arguments["destination"] as? String,
                    !destination.isEmpty, destination.utf8.count <= 256,
                    let text = arguments["text"] as? String, !text.isEmpty,
                    text.utf8.count <= Self.maximumTextBytes
                else {
                    return toolReply(
                        id: id, text: "Invalid destination or message size.", failed: true)
                }
                response = perform("send", destination: destination, text: text)
            default:
                guard CanvasAgentTool(rawValue: name) != nil else {
                    return encode([
                        "jsonrpc": "2.0", "id": id,
                        "error": ["code": -32602, "message": "Unknown tool"],
                    ])
                }
                return callAgentTool(id: id, name: name, arguments: arguments)
            }
            guard let response, let encoded = try? JSONEncoder().encode(response),
                encoded.count <= Self.maximumFrameBytes / 2
            else {
                return toolReply(id: id, text: "Ensemble connection unavailable.", failed: true)
            }
            return toolReply(
                id: id, text: String(decoding: encoded, as: UTF8.self),
                failed: response.error != nil)
        default:
            return encode([
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "Method not found"],
            ])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Orchestration tools. Arguments are validated here and again in the app.
    private func callAgentTool(id: Any, name: String, arguments: [String: Any]) -> Data? {
        let call: CanvasAgentToolCall
        do {
            call = try CanvasAgentToolCall.parse(tool: name, arguments: arguments)
        } catch {
            return toolReply(id: id, text: error.message, failed: true)
        }
        guard let response = perform("tool", call: call) else {
            return toolReply(id: id, text: "Ensemble connection unavailable.", failed: true)
        }
        if let error = response.error {
            return toolReply(
                id: id, text: CanvasAgentText.singleLine(error, limit: 1_000), failed: true)
        }
        guard let result = response.toolResult,
            let encoded = result.bounded(maximumBytes: Self.maximumFrameBytes / 2).agentJSON(),
            encoded.count <= Self.maximumFrameBytes / 2
        else {
            return toolReply(id: id, text: "Ensemble response is too large.", failed: true)
        }
        return toolReply(id: id, text: String(decoding: encoded, as: UTF8.self), failed: false)
    }

    /// A transport write is not a model acknowledgement.
    public func receiveChannelMessages() {
        guard state.withLock({ $0.connected && $0.initialized }),
            let response = perform("receive")
        else { return }
        guard response.error == nil else {
            disconnect()
            return
        }
        guard provider == "claude" else { return }
        for message in response.messages {
            guard message.text.utf8.count <= Self.maximumTextBytes,
                message.id.utf8.count <= 256, message.source.utf8.count <= 256
            else {
                disconnect()
                return
            }
            if let notification = encode([
                "jsonrpc": "2.0", "method": "notifications/claude/channel",
                "params": [
                    "content": message.text,
                    "meta": ["message_id": message.id, "source_id": message.source],
                ],
            ]) {
                write(notification)
            } else {
                disconnect()
                return
            }
        }
    }

    private func captureThread(params: [String: Any]) -> Bool {
        guard provider == "codex", let meta = params["_meta"] as? [String: Any],
            let candidate = meta["threadId"] as? String
        else { return true }
        guard UUID(uuidString: candidate) != nil else { return false }
        let previous = state.withLock { $0.threadID }
        if previous == candidate { return true }
        state.withLock { $0.threadID = candidate }
        guard let response = perform("register"), response.error == nil else {
            disconnect()
            return false
        }
        return true
    }

    private func perform(
        _ operation: String, destination: String? = nil, text: String? = nil,
        call: CanvasAgentToolCall? = nil
    ) -> CanvasBridgeResponse? {
        guard isConnected else { return nil }
        do {
            let response = try exchange(
                CanvasBridgeRequest(
                    token: token, operation: operation, clientID: clientID,
                    provider: provider, threadID: state.withLock { $0.threadID },
                    endpoint: operation == "register" ? endpoint : nil,
                    executable: operation == "register" ? executable : nil,
                    destination: destination, text: text, agentCall: call))
            if operation == "register", response.error != nil {
                disconnect()
                return nil
            }
            return response
        } catch {
            disconnect()
            return nil
        }
    }

    private func disconnect() { state.withLock { $0.connected = false } }

    private func write(_ data: Data) {
        guard isConnected else { return }
        do { try output.withLock { try $0(data) } } catch { disconnect() }
    }

    private func toolReply(id: Any, text: String, failed: Bool) -> Data? {
        encode([
            "jsonrpc": "2.0", "id": id,
            "result": ["content": [["type": "text", "text": text]], "isError": failed],
        ])
            ?? encode([
                "jsonrpc": "2.0", "id": id,
                "error": ["code": -32603, "message": "Ensemble response is too large"],
            ])
    }

    private func encode(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object),
            data.count <= Self.maximumFrameBytes
        else { return nil }
        data.append(10)
        return data
    }

    private static var tools: [[String: Any]] {
        messagingTools + CanvasAgentToolCatalog.definitions
    }

    private static var messagingTools: [[String: Any]] {
        [
            [
                "name": "list_connections",
                "description":
                    "List Ensemble peers with session names, providers, @mentions, and peer IDs.",
                "inputSchema": [
                    "type": "object", "properties": [:], "additionalProperties": false,
                ],
            ],
            [
                "name": "send_message",
                "description":
                    "Send a message to one connected session by its listed @mention or peer ID.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "destination": [
                            "type": "string",
                            "description":
                                "The exact listed @mention or peer ID. Duplicate names require a peer ID.",
                        ],
                        "text": ["type": "string", "maxLength": maximumTextBytes],
                    ],
                    "required": ["destination", "text"], "additionalProperties": false,
                ],
            ],
            [
                "name": "receive_messages",
                "description": "Read pending messages from connected sessions.",
                "inputSchema": [
                    "type": "object", "properties": [:], "additionalProperties": false,
                ],
            ],
        ]
    }
}
