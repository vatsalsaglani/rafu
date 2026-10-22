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
        /// The stdio loop runs. Only stdin EOF, a poll error, an oversized frame or
        /// an output failure clear it. A lost app link never does.
        var connected = true
        var initialized = false
        var threadID: String?
        /// The app knows this client. Any loss clears it; a good register sets it.
        var registered = false
        var degraded = false
        var backoffMilliseconds = CanvasBridgeMCPServer.initialBackoffMilliseconds
        /// Uptime in nanoseconds before which the heartbeat does no work.
        var retryAt: UInt64 = 0
        var lastDiagnostic: String?
    }

    static let initialBackoffMilliseconds = 300
    static let maximumBackoffMilliseconds = 5_000

    /// Pure retry policy: double after each failure, up to a cap.
    public static func nextBackoff(_ current: Int) -> Int {
        min(max(current, 1) * 2, maximumBackoffMilliseconds)
    }

    private let token: String
    private let clientID = UUID().uuidString
    private let provider: String
    private let endpoint: String?
    private let executable: String?
    private let exchange: Exchange
    private let state = Mutex(State())
    private let output: Mutex<@Sendable (Data) throws -> Void>
    private let diagnostics: @Sendable (String) -> Void
    private let uptime: @Sendable () -> UInt64

    /// `diagnostics` receives one bounded line without a newline. A line never
    /// carries the token, a socket path, a thread ID or message text.
    public init(
        token: String, provider: String, endpoint: String? = nil, executable: String? = nil,
        exchange: @escaping Exchange,
        output: @escaping @Sendable (Data) throws -> Void,
        diagnostics: (@Sendable (String) -> Void)? = nil,
        uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.token = token
        self.provider = provider
        self.endpoint = provider == "codex" ? endpoint : nil
        self.executable = provider == "codex" ? executable : nil
        self.exchange = exchange
        self.output = Mutex(output)
        self.diagnostics = diagnostics ?? Self.writeDiagnostic
        self.uptime = uptime
    }

    @Sendable
    private static func writeDiagnostic(_ line: String) {
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }

    /// The caller supplies a bounded local IPC exchange; this function owns stdin/stdout.
    /// It returns only on stdin EOF, a poll error, an oversized frame or an output
    /// failure. A lost or refused app link keeps the server alive and retrying.
    public static func run(token: String, provider: String, exchange: @escaping Exchange) {
        let environment = ProcessInfo.processInfo.environment
        let server = CanvasBridgeMCPServer(
            token: token, provider: provider,
            endpoint: environment["RAFU_CANVAS_CODEX_ENDPOINT"],
            executable: environment["RAFU_CANVAS_CODEX_EXECUTABLE"], exchange: exchange,
            output: { try FileHandle.standardOutput.write(contentsOf: $0) }
        )
        guard provider == "claude" || provider == "codex" else { return }
        // A failed first register is not fatal. The heartbeat and the next tool
        // call register again, and the client still sees a live MCP server.
        server.register()
        defer {
            _ = try? exchange(
                CanvasBridgeRequest(
                    token: token, operation: "unregister", clientID: server.clientID))
            server.diagnoseClosed()
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
            // Bounded readiness checks keep the loop responsive to the stop flag.
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

    public var isRegistered: Bool { state.withLock { $0.registered } }

    @discardableResult
    public func register() -> Bool {
        guard provider == "claude" || provider == "codex" else {
            disconnect()
            return false
        }
        return exchangeOnce("register") != nil
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
            guard let response else {
                return toolReply(id: id, text: Self.unreachableText, failed: true)
            }
            guard let encoded = try? JSONEncoder().encode(response),
                encoded.count <= Self.maximumFrameBytes / 2
            else {
                return toolReply(id: id, text: "Ensemble response is too large.", failed: true)
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
            return toolReply(id: id, text: Self.unreachableText, failed: true)
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

    /// A transport write is not a model acknowledgement. This is also the
    /// heartbeat. While the link is down it only registers again, no faster than
    /// the bounded backoff, and it never ends the server.
    public func receiveChannelMessages() {
        guard state.withLock({ $0.connected && $0.initialized }) else { return }
        guard uptime() >= state.withLock({ $0.retryAt }) else { return }
        guard isRegistered else {
            register()
            return
        }
        guard let response = exchangeOnce("receive") else { return }
        if let error = response.error {
            // The route may be paused, suspended or reset. Register again, bounded.
            state.withLock { $0.registered = false }
            noteFailure(refused: error)
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
        // A failed register is not fatal. The next register sends the stored
        // thread, and the tool call itself reports the outage.
        _ = exchangeOnce("register")
        return true
    }

    private func perform(
        _ operation: String, destination: String? = nil, text: String? = nil,
        call: CanvasAgentToolCall? = nil
    ) -> CanvasBridgeResponse? {
        guard isConnected else { return nil }
        // A caller is waiting, so it registers again at once. Only the heartbeat
        // honours the backoff.
        if !isRegistered, exchangeOnce("register") == nil { return nil }
        return exchangeOnce(operation, destination: destination, text: text, call: call)
    }

    /// One IPC exchange. A transport error or a refused register marks the link
    /// degraded and returns nil. Nothing here ends the server.
    private func exchangeOnce(
        _ operation: String, destination: String? = nil, text: String? = nil,
        call: CanvasAgentToolCall? = nil
    ) -> CanvasBridgeResponse? {
        guard isConnected else { return nil }
        let response: CanvasBridgeResponse
        do {
            response = try exchange(
                CanvasBridgeRequest(
                    token: token, operation: operation, clientID: clientID,
                    provider: provider, threadID: state.withLock { $0.threadID },
                    endpoint: operation == "register" ? endpoint : nil,
                    executable: operation == "register" ? executable : nil,
                    destination: destination, text: text, agentCall: call))
        } catch {
            state.withLock { $0.registered = false }
            noteFailure(transport: error)
            return nil
        }
        if operation == "register" {
            if let error = response.error {
                state.withLock { $0.registered = false }
                noteFailure(refused: error)
                return nil
            }
            state.withLock { $0.registered = true }
            noteSuccess()
            return response
        }
        if response.code == CanvasBridgeResponse.unregisteredCode
            || response.error == CanvasBridgeResponse.unregisteredMessage
        {
            // The app lost this client. The next heartbeat or call registers again.
            state.withLock { $0.registered = false }
            return response
        }
        if response.error == nil { noteSuccess() }
        return response
    }

    private func noteSuccess() {
        let restored = state.withLock { state -> Bool in
            let wasDegraded = state.degraded
            state.degraded = false
            state.backoffMilliseconds = Self.initialBackoffMilliseconds
            state.retryAt = 0
            state.lastDiagnostic = nil
            return wasDegraded
        }
        if restored { diagnose("Ensemble link restored.") }
    }

    private func noteFailure(transport error: any Error) {
        noteFailure(line: "Ensemble link lost (\(Self.category(of: error))). Retrying.")
    }

    /// `message` is an app literal, never request data. It is still bounded.
    private func noteFailure(refused message: String) {
        let literal = CanvasAgentText.singleLine(message, limit: 100)
        noteFailure(line: "Ensemble link refused: \(literal) Retrying.")
    }

    private func noteFailure(line: String) {
        let announce = state.withLock { state -> Bool in
            state.degraded = true
            state.retryAt = uptime() + UInt64(state.backoffMilliseconds) * 1_000_000
            state.backoffMilliseconds = Self.nextBackoff(state.backoffMilliseconds)
            guard state.lastDiagnostic != line else { return false }
            state.lastDiagnostic = line
            return true
        }
        if announce { diagnose(line) }
    }

    /// A category from the error type only. It never reads a path or a message.
    static func category(of error: any Error) -> String {
        guard let error = error as? LauncherIPCClientError else { return "connection error" }
        switch error {
        case .disconnected: return "Rafu closed the connection"
        case .rejected: return "request rejected"
        case .systemCall(_, let code):
            if error.isListenerUnavailable { return "Rafu is not listening" }
            if code == EAGAIN || code == ETIMEDOUT { return "Rafu did not answer in time" }
            return "connection error"
        }
    }

    private func diagnose(_ line: String) {
        diagnostics(String(("Rafu: " + line).prefix(200)))
    }

    private func diagnoseClosed() {
        if state.withLock({ $0.degraded }) { diagnose("Ensemble link closed.") }
    }

    private static let unreachableText =
        "Rafu is not reachable right now. The Ensemble link is reconnecting. Try again in a few seconds."

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
