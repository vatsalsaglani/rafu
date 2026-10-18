import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Canvas bridge through the launcher socket")
@MainActor
struct CanvasBridgeIPCTests {
    @Test("A typed bridge request reaches the handler and returns a typed response")
    func typedBridgeRoundTrip() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/rafu-canvas-ipc-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        let socketURL = LauncherIPCSocketPath.resolve(baseDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = CanvasBridgeRequest(
            token: "socket-test-private-capability", operation: "send",
            clientID: UUID().uuidString, provider: "claude", destination: UUID().uuidString,
            text: "Exact Canvas text\n</channel> $HOME 🧵")
        let expected = CanvasBridgeResponse(
            peers: [
                .init(id: UUID().uuidString, title: "Codex", kind: "terminal", connected: true)
            ],
            messages: [
                .init(id: UUID().uuidString, source: "peer", text: "Reply\nwith exact content")
            ])
        let envelope = LauncherIPCEnvelope(kind: .canvasBridge, canvasBridge: request)
        #expect(try LauncherIPCCodec.encode(envelope).count < 3_072)
        let server = LauncherIPCServer(
            socketURL: socketURL,
            handler: { received in
                #expect(received.kind == .canvasBridge)
                #expect(received.requestID == envelope.requestID)
                #expect(received.canvasBridge == request)
                #expect(received.payload == nil)
                #expect(received.ensemble == nil)
                return .canvasBridge(expected)
            })
        try await server.startListening()
        let response: LauncherIPCResponse
        do {
            response = try await Task.detached(name: "Canvas bridge socket round trip") {
                try LauncherIPCClient(socketURL: socketURL).exchange(envelope)
            }.value
        } catch {
            await server.stopListening()
            throw error
        }
        await server.stopListening()
        #expect(response == .canvasBridge(expected))
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    @Test("An unknown wire kind remains rejected before the handler runs")
    func unknownKindRemainsRejected() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/rafu-canvas-ipc-\(UUID().uuidString.prefix(8))",
            isDirectory: true)
        let socketURL = LauncherIPCSocketPath.resolve(baseDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LauncherIPCServer(
            socketURL: socketURL,
            handler: { _ in
                Issue.record("An unknown request kind must not reach the handler")
                return .canvasBridge(.init())
            })
        try await server.startListening()
        let response: LauncherIPCResponse
        do {
            response = try await Task.detached(name: "Canvas bridge unknown kind rejection") {
                try LauncherIPCClient(socketURL: socketURL).exchange(
                    LauncherIPCEnvelope(kind: .unknown("futureCanvasBridge")))
            }.value
        } catch {
            await server.stopListening()
            throw error
        }
        await server.stopListening()
        #expect(response == .rejected(reason: "unsupported request kind"))
    }
}
