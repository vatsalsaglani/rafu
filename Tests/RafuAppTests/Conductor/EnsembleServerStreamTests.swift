import Darwin
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Ensemble server streaming")
struct EnsembleServerStreamTests {
    @Test("Peer UID is checked before subscription bytes are read")
    func uidBeforeRead() async throws {
        let server = LauncherIPCServer(
            peerUID: { _ in getuid() &+ 1 },
            subscriptionHandler: { _ in
                Issue.record("A foreign peer must not reach the subscription handler")
                return nil
            }
        )
        let pair = try serverSocketPair()
        try serverWriteAll(Data(repeating: 0, count: 9), to: pair.client)

        await server.serveConnectionForTesting(pair.server)
        var reader = ServerFrameReader()
        #expect(
            try reader.response(from: pair.client)
                == .rejected(reason: "peer user mismatch")
        )
        Darwin.close(pair.client)
    }

    @Test("Subscribed acknowledgement and events are separate RAFU frames")
    func framedEvents() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: EnsembleEvent.self)
        let server = LauncherIPCServer(
            subscriptionHandler: { _ in stream },
            subscriptionCursor: { 12 }
        )
        let pair = try serverSocketPair()
        try serverWriteAll(
            LauncherIPCCodec.encode(subscriptionEnvelope()),
            to: pair.client
        )
        let task = Task {
            await server.serveConnectionForTesting(pair.server)
        }
        await waitForStreamingCount(1, server: server)
        var reader = ServerFrameReader()
        #expect(
            try reader.response(from: pair.client)
                == .ensemble(.subscribed(cursor: 12))
        )

        let event = EnsembleEvent(
            cursor: 13,
            at: Date(timeIntervalSince1970: 1),
            runID: "run-a",
            kind: "state",
            state: .completed
        )
        continuation.yield(event)
        continuation.finish()
        #expect(try reader.event(from: pair.client) == event)
        await task.value
        Darwin.close(pair.client)
    }

    @Test("The streaming cap returns a typed failure frame")
    func streamingCap() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: EnsembleEvent.self)
        let server = LauncherIPCServer(
            subscriptionHandler: { _ in stream },
            subscriptionCursor: { 1 },
            maxStreamingConnections: 1
        )
        let first = try serverSocketPair()
        try serverWriteAll(
            LauncherIPCCodec.encode(subscriptionEnvelope()),
            to: first.client
        )
        let firstTask = Task {
            await server.serveConnectionForTesting(first.server)
        }
        await waitForStreamingCount(1, server: server)
        var firstReader = ServerFrameReader()
        #expect(
            try firstReader.response(from: first.client)
                == .ensemble(.subscribed(cursor: 1))
        )

        let overflow = try serverSocketPair()
        try serverWriteAll(
            LauncherIPCCodec.encode(subscriptionEnvelope()),
            to: overflow.client
        )
        await server.serveConnectionForTesting(overflow.server)
        var overflowReader = ServerFrameReader()
        guard
            case .ensemble(.failure(let code, let message)) =
                try overflowReader.response(from: overflow.client)
        else {
            Issue.record("Expected a typed stream-cap failure")
            continuation.finish()
            await firstTask.value
            return
        }
        #expect(code == EnsembleExitCode.unavailable.rawValue)
        #expect(message.contains("limit"))

        continuation.finish()
        await firstTask.value
        #expect(await server.liveStreamingConnectionCountForTesting == 0)
        Darwin.close(first.client)
        Darwin.close(overflow.client)
    }

    @Test("stopListening cancels and shuts down a live stream")
    func stopEndsStreams() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: EnsembleEvent.self)
        let root = URL(
            fileURLWithPath: "/tmp/rafu-ensemble-stop-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = LauncherIPCSocketPath.resolve(baseDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LauncherIPCServer(
            socketURL: socketURL,
            subscriptionHandler: { _ in stream },
            subscriptionCursor: { 3 }
        )
        try await server.startListening()

        let client = try connectServerSocket(at: socketURL)
        try serverWriteAll(
            LauncherIPCCodec.encode(subscriptionEnvelope()),
            to: client
        )
        await waitForStreamingCount(1, server: server)
        var reader = ServerFrameReader()
        #expect(
            try reader.response(from: client)
                == .ensemble(.subscribed(cursor: 3))
        )

        await server.stopListening()
        #expect(await server.liveConnectionCountForTesting == 0)
        #expect(await server.liveStreamingConnectionCountForTesting == 0)
        var byte: UInt8 = 0
        #expect(Darwin.read(client, &byte, 1) == 0)

        continuation.finish()
        Darwin.close(client)
    }
}

private func subscriptionEnvelope() -> LauncherIPCEnvelope {
    LauncherIPCEnvelope(
        kind: .ensembleSubscribe,
        ensemble: EnsembleRequestPayload(
            verb: "await",
            workingDirectory: "/work",
            runIDs: ["run-a"],
            states: [.completed]
        )
    )
}

private struct ServerSocketPair {
    let client: Int32
    let server: Int32
}

private let serverSIGPIPEIgnored: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

private func serverSocketPair() throws -> ServerSocketPair {
    _ = serverSIGPIPEIgnored
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw LauncherIPCServerError.systemCall(name: "socketpair", code: errno)
    }
    for descriptor in descriptors {
        var one: Int32 = 1
        _ = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &one,
            socklen_t(MemoryLayout.size(ofValue: one))
        )
    }
    return ServerSocketPair(client: descriptors[0], server: descriptors[1])
}

private func connectServerSocket(at socketURL: URL) throws -> Int32 {
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        throw LauncherIPCServerError.systemCall(name: "socket", code: errno)
    }
    var one: Int32 = 1
    _ = Darwin.setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &one,
        socklen_t(MemoryLayout.size(ofValue: one))
    )
    var address = try LauncherSocketAddress.make(path: socketURL.path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(
                fileDescriptor,
                socketAddress,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(fileDescriptor)
        throw LauncherIPCServerError.systemCall(name: "connect", code: code)
    }
    return fileDescriptor
}

private func waitForStreamingCount(
    _ expected: Int,
    server: LauncherIPCServer
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await server.liveStreamingConnectionCountForTesting != expected,
        ContinuousClock.now < deadline
    {
        await Task.yield()
    }
    #expect(await server.liveStreamingConnectionCountForTesting == expected)
}

private struct ServerFrameReader {
    private var decoder = LauncherIPCFrameDecoder()
    private var pending: [Data] = []

    mutating func response(from fileDescriptor: Int32) throws -> LauncherIPCResponse {
        try LauncherIPCCodec.decode(
            LauncherIPCResponse.self,
            from: body(from: fileDescriptor)
        )
    }

    mutating func event(from fileDescriptor: Int32) throws -> EnsembleEvent {
        try LauncherIPCCodec.decode(
            EnsembleEvent.self,
            from: body(from: fileDescriptor)
        )
    }

    private mutating func body(from fileDescriptor: Int32) throws -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        var storage = [UInt8](repeating: 0, count: 4_096)
        while true {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 2_000) > 0 else {
                throw LauncherIPCServerError.systemCall(name: "poll", code: errno)
            }
            let count = storage.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LauncherIPCServerError.systemCall(name: "read", code: errno)
            }
            guard count > 0 else {
                throw LauncherIPCServerError.systemCall(name: "read", code: ECONNRESET)
            }
            let bodies = try decoder.consume(Data(storage.prefix(count)))
            if let first = bodies.first {
                pending.append(contentsOf: bodies.dropFirst())
                return first
            }
        }
    }
}

private func serverWriteAll(_ data: Data, to fileDescriptor: Int32) throws {
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
                throw LauncherIPCServerError.systemCall(name: "write", code: errno)
            }
            guard count > 0 else {
                throw LauncherIPCServerError.systemCall(name: "write", code: EPIPE)
            }
            offset += count
        }
    }
}
