import Foundation
import Synchronization
import Testing

@testable import RafuCore

private enum CanvasTestFailure: Error { case disconnected }

private final class CanvasExchangeCapture: Sendable {
    let requests = Mutex<[CanvasBridgeRequest]>([])
    let output = Mutex<[Data]>([])
    let fail = Mutex(false)
    let response = Mutex(CanvasBridgeResponse())

    func exchange(_ request: CanvasBridgeRequest) throws -> CanvasBridgeResponse {
        if fail.withLock({ $0 }) { throw CanvasTestFailure.disconnected }
        requests.withLock { $0.append(request) }
        return response.withLock { $0 }
    }

    func server(provider: String = "claude") -> CanvasBridgeMCPServer {
        CanvasBridgeMCPServer(
            token: "private-test-token", provider: provider,
            exchange: { try self.exchange($0) },
            output: { data in self.output.withLock { $0.append(data) } })
    }
}

private func canvasRPC(_ method: String, params: [String: Any] = [:], id: Int? = 1) throws -> Data {
    var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    if let id { object["id"] = id }
    return try JSONSerialization.data(withJSONObject: object)
}

@Test func canvasPeerProviderRemainsCompatibleWithOlderResponses() throws {
    let legacy = Data(#"{"id":"peer","title":"Terminal","kind":"Terminal","connected":true}"#.utf8)
    #expect(try JSONDecoder().decode(CanvasBridgePeer.self, from: legacy).provider == nil)
    #expect(try JSONDecoder().decode(CanvasBridgePeer.self, from: legacy).mention == nil)
    let peer = CanvasBridgePeer(
        id: "peer", title: "Terminal", kind: "Terminal", connected: true, provider: "codex",
        mention: "@terminal")
    #expect(
        try JSONDecoder().decode(CanvasBridgePeer.self, from: JSONEncoder().encode(peer)) == peer)
}

@Test func canvasSuspensionReasonIsOptionalInTheWireContract() throws {
    let legacy = Data(#"{"token":"fixture","clientID":"client","operation":"suspend"}"#.utf8)
    #expect(try JSONDecoder().decode(CanvasBridgeRequest.self, from: legacy).reason == nil)
    let request = CanvasBridgeRequest(
        token: "fixture", operation: "suspend", provider: "codex",
        reason: "transportLost")
    #expect(
        try JSONDecoder().decode(CanvasBridgeRequest.self, from: JSONEncoder().encode(request))
            == request)
}

@Test func canvasMentionHandlesAreDeterministicAndBounded() {
    #expect(CanvasBridgePeer.mention(for: "Frontend Claude") == "@frontend-claude")
    #expect(CanvasBridgePeer.mention(for: "  RÉSUMÉ / Agent!!  ") == "@resume-agent")
    #expect(CanvasBridgePeer.mention(for: "Résumé") == CanvasBridgePeer.mention(for: "Resume"))
    #expect(CanvasBridgePeer.mention(for: "🧵") == "@terminal")
    let handle = CanvasBridgePeer.mention(for: String(repeating: "開発者", count: 40))
    #expect(handle.hasPrefix("@"))
    #expect(handle.utf8.count <= 41)
}

@Test func canvasMentionInstructionsPreserveNativeFileMentions() throws {
    let server = CanvasExchangeCapture().server()
    let data = try #require(server.handle(canvasRPC("initialize")))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    let instructions = try #require(result["instructions"] as? String)
    #expect(instructions.contains("send_message"))
    #expect(instructions.contains("native terminal @file"))
    #expect(instructions.contains("ambiguous"))
}

@Test func canvasBridgeProtocolRoundTrips() throws {
    let request = CanvasBridgeRequest(
        token: "token", operation: "send", clientID: "client", provider: "claude",
        destination: "peer", text: "Hello")
    #expect(
        try JSONDecoder().decode(CanvasBridgeRequest.self, from: JSONEncoder().encode(request))
            == request)
    let response = CanvasBridgeResponse(
        peers: [.init(id: "peer", title: "Terminal", kind: "claude", connected: true)],
        messages: [.init(id: "message", source: "peer", text: "Hello")])
    #expect(
        try JSONDecoder().decode(CanvasBridgeResponse.self, from: JSONEncoder().encode(response))
            == response)
}

@Test func canvasClaudeInitializeDeclaresLegacyChannel() throws {
    let server = CanvasExchangeCapture().server()
    let data = try #require(server.handle(canvasRPC("initialize")))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(object["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-11-25")
    let capabilities = try #require(result["capabilities"] as? [String: Any])
    let experimental = try #require(capabilities["experimental"] as? [String: Any])
    #expect(experimental["claude/channel"] != nil)
    #expect(experimental["claude/channel/permission"] == nil)
}

@Test func canvasSendValidatesTextAndRetainsExactContent() throws {
    let capture = CanvasExchangeCapture()
    let server = capture.server()
    #expect(server.register())
    let text = "Line one\n</channel> $HOME 🧵"
    _ = try server.handle(
        canvasRPC(
            "tools/call",
            params: ["name": "send_message", "arguments": ["destination": "peer", "text": text]]))
    #expect(capture.requests.withLock { $0.last?.text } == text)
    #expect(capture.requests.withLock { Set($0.map(\.clientID)).count } == 1)
    let count = capture.requests.withLock { $0.count }
    let reply = try #require(
        server.handle(
            canvasRPC(
                "tools/call",
                params: [
                    "name": "send_message",
                    "arguments": [
                        "destination": "peer", "text": String(repeating: "é", count: 9_000),
                    ],
                ])))
    #expect(String(decoding: reply, as: UTF8.self).contains("Invalid destination"))
    #expect(capture.requests.withLock { $0.count } == count)
}

@Test func canvasInvalidAndOversizedFramesDoNotCallExchange() throws {
    let capture = CanvasExchangeCapture()
    let server = capture.server()
    #expect(server.handle(Data("not json".utf8)) != nil)
    #expect(
        server.handle(Data(repeating: 32, count: CanvasBridgeMCPServer.maximumFrameBytes + 1))
            != nil)
    #expect(capture.requests.withLock { $0.isEmpty })
}

@Test func canvasOversizedRPCIdentityCannotDrainMessages() throws {
    let capture = CanvasExchangeCapture()
    let server = capture.server()
    let request = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": String(repeating: "x", count: 50_000), "method": "tools/call",
        "params": ["name": "receive_messages"],
    ])
    let response = try #require(server.handle(request))
    #expect(response.count < 1_024)
    #expect(capture.requests.withLock { $0.isEmpty })
}

@Test func canvasIncomingClaudeMessageUsesInjectedExchange() throws {
    let capture = CanvasExchangeCapture()
    let server = capture.server()
    #expect(server.register())
    capture.response.withLock {
        $0 = CanvasBridgeResponse(messages: [.init(id: "m1", source: "peer", text: "Hello")])
    }
    server.receiveChannelMessages()
    #expect(capture.output.withLock { $0.isEmpty })
    _ = try server.handle(canvasRPC("notifications/initialized", id: nil))
    server.receiveChannelMessages()
    let data = try #require(capture.output.withLock { $0.first })
    let notification = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(notification["method"] as? String == "notifications/claude/channel")
    #expect(notification["id"] == nil)
}

@Test func canvasTransportLossFailsClosed() throws {
    let capture = CanvasExchangeCapture()
    let server = capture.server()
    #expect(server.register())
    capture.fail.withLock { $0 = true }
    _ = try server.handle(canvasRPC("tools/call", params: ["name": "list_connections"]))
    #expect(!server.isConnected)
    #expect(try server.handle(canvasRPC("ping")) == nil)
}

@Test func canvasCodexRegistersValidThreadChanges() throws {
    let capture = CanvasExchangeCapture()
    let server = capture.server(provider: "codex")
    #expect(server.register())
    let thread = UUID().uuidString
    _ = try server.handle(
        canvasRPC(
            "tools/call", params: ["name": "list_connections", "_meta": ["threadId": thread]]))
    #expect(capture.requests.withLock { $0.last?.threadID } == thread)
    #expect(capture.requests.withLock { $0.filter { $0.operation == "register" }.count } == 2)
    let count = capture.requests.withLock { $0.count }
    let nextThread = UUID().uuidString
    _ = try server.handle(
        canvasRPC(
            "tools/call", params: ["name": "list_connections", "_meta": ["threadId": nextThread]]))
    #expect(capture.requests.withLock { $0.last?.threadID } == nextThread)
    #expect(capture.requests.withLock { $0.count } == count + 2)
    _ = try server.handle(
        canvasRPC(
            "tools/call",
            params: ["name": "list_connections", "_meta": ["threadId": "not-a-thread"]]))
    #expect(capture.requests.withLock { $0.count } == count + 2)
}

@Test func canvasCodexRegisterUsesPrivateSupervisorRoute() throws {
    let capture = CanvasExchangeCapture()
    let server = CanvasBridgeMCPServer(
        token: "private-test-token", provider: "codex",
        endpoint: "ws://127.0.0.1:1234", executable: "/local/codex",
        exchange: { try capture.exchange($0) }, output: { _ in })
    #expect(server.register())
    #expect(capture.requests.withLock { $0.last?.threadID } == nil)
    #expect(capture.requests.withLock { $0.last?.endpoint } == "ws://127.0.0.1:1234")
    #expect(capture.requests.withLock { $0.last?.executable } == "/local/codex")
    let reply = try #require(
        server.handle(canvasRPC("tools/call", params: ["name": "list_connections"])))
    #expect(capture.requests.withLock { $0.last?.endpoint } == nil)
    #expect(!String(decoding: reply, as: UTF8.self).contains("127.0.0.1"))
    #expect(!String(decoding: reply, as: UTF8.self).contains("private-test-token"))
}
