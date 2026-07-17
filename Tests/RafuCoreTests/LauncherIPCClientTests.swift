import Darwin
import Foundation
import Synchronization
import Testing

@testable import RafuCore

@Suite("Launcher IPC client")
struct LauncherIPCClientTests {
    @Test("Handshake precedes an open request over two owned socketpair connections")
    func handshakeThenRequest() async throws {
        let handshakePair = try socketPair()
        let requestPair = try socketPair()
        let connector = DescriptorQueue([handshakePair.client, requestPair.client])
        let handshakeServer = serveOnce(
            handshakePair.server,
            response: .accepted(
                workspaceMatched: false,
                windowFocused: false,
                waitSupported: false
            )
        )
        let requestServer = serveOnce(
            requestPair.server,
            response: .accepted(
                workspaceMatched: true,
                windowFocused: true,
                waitSupported: false
            )
        )
        let client = LauncherIPCClient { try connector.take() }
        let request = LauncherOpenRequest(
            target: .local(path: "/work/app"),
            activationPolicy: .reuseWindow
        )

        let response = try client.perform(request)
        let handshake = try await handshakeServer.value
        let receivedRequest = try await requestServer.value

        #expect(handshake.kind == .handshake)
        #expect(handshake.payload == nil)
        #expect(receivedRequest.kind == .openFolder)
        #expect(receivedRequest.payload == request)
        #expect(
            response
                == .accepted(
                    workspaceMatched: true,
                    windowFocused: true,
                    waitSupported: false
                )
        )
        #expect(connector.isEmpty)
    }

    @Test("A goto request uses the typed goto discriminator")
    func gotoKind() async throws {
        let handshakePair = try socketPair()
        let requestPair = try socketPair()
        let connector = DescriptorQueue([handshakePair.client, requestPair.client])
        let handshakeServer = serveOnce(
            handshakePair.server,
            response: .accepted(
                workspaceMatched: false,
                windowFocused: false,
                waitSupported: false
            )
        )
        let requestServer = serveOnce(
            requestPair.server,
            response: .accepted(
                workspaceMatched: true,
                windowFocused: true,
                waitSupported: false
            )
        )
        let request = LauncherOpenRequest(
            target: .local(path: "/work/app/main.swift"),
            sourceLocation: SourceLocation(line: 12, column: 4)
        )

        _ = try LauncherIPCClient { try connector.take() }.perform(request)
        _ = try await handshakeServer.value
        let receivedRequest = try await requestServer.value

        #expect(receivedRequest.kind == .goto)
        #expect(receivedRequest.payload == request)
    }

    @Test("A typed handshake rejection stops before the request connection")
    func handshakeRejection() async throws {
        let pair = try socketPair()
        let connector = DescriptorQueue([pair.client])
        let server = serveOnce(
            pair.server,
            response: .rejected(reason: "incompatible protocol version")
        )
        let client = LauncherIPCClient { try connector.take() }

        #expect(throws: LauncherIPCClientError.rejected(reason: "incompatible protocol version")) {
            try client.perform(LauncherOpenRequest(target: .local(path: "/work")))
        }
        _ = try await server.value
        #expect(connector.isEmpty)
    }

    @Test("Only absent or refused connect errors trigger app startup")
    func unavailableClassification() {
        #expect(
            LauncherIPCClientError.systemCall(name: "connect", code: ENOENT).isListenerUnavailable)
        #expect(
            LauncherIPCClientError.systemCall(name: "connect", code: ECONNREFUSED)
                .isListenerUnavailable
        )
        #expect(
            !LauncherIPCClientError.systemCall(name: "connect", code: EACCES)
                .isListenerUnavailable
        )
        #expect(
            !LauncherIPCClientError.systemCall(name: "read", code: ECONNREFUSED)
                .isListenerUnavailable
        )
    }

    @Test("Reconnect backoff is exponential, bounded, and under ten seconds")
    func reconnectSchedule() {
        let delays = LauncherIPCReconnectSchedule.delaysMicroseconds
        #expect(delays.first == 50_000)
        #expect(delays.max() == 1_000_000)
        #expect(delays.reduce(0, +) < 10_000_000)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $1 >= $0 })
    }
}

private struct SocketPair {
    let client: Int32
    let server: Int32
}

private func socketPair() throws -> SocketPair {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw LauncherIPCClientError.systemCall(name: "socketpair", code: errno)
    }
    return SocketPair(client: descriptors[0], server: descriptors[1])
}

private final class DescriptorQueue: Sendable {
    private let descriptors: Mutex<[Int32]>

    init(_ descriptors: [Int32]) {
        self.descriptors = Mutex(descriptors)
    }

    var isEmpty: Bool {
        descriptors.withLock { $0.isEmpty }
    }

    func take() throws -> Int32 {
        try descriptors.withLock { descriptors in
            guard !descriptors.isEmpty else {
                throw LauncherIPCClientError.disconnected
            }
            return descriptors.removeFirst()
        }
    }
}

private func serveOnce(
    _ fileDescriptor: Int32,
    response: LauncherIPCResponse
) -> Task<LauncherIPCEnvelope, Error> {
    Task.detached {
        defer { Darwin.close(fileDescriptor) }
        let envelope = try readEnvelope(from: fileDescriptor)
        let frame = try LauncherIPCCodec.encode(response)
        try writeAll(frame, to: fileDescriptor)
        return envelope
    }
}

private func readEnvelope(from fileDescriptor: Int32) throws -> LauncherIPCEnvelope {
    var decoder = LauncherIPCFrameDecoder()
    var storage = [UInt8](repeating: 0, count: 256)
    while true {
        let count = storage.withUnsafeMutableBytes { bytes in
            Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw LauncherIPCClientError.systemCall(name: "read", code: errno)
        }
        guard count > 0 else { throw LauncherIPCClientError.disconnected }
        let bodies = try decoder.consume(Data(storage.prefix(count)))
        if let body = bodies.first {
            return try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: body)
        }
    }
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                fileDescriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw LauncherIPCClientError.systemCall(name: "write", code: errno)
            }
            guard count > 0 else { throw LauncherIPCClientError.disconnected }
            offset += count
        }
    }
}
