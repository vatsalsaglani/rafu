import Darwin
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Launcher IPC listener")
struct LauncherIPCServerTests {
    @Test("A same-user socketpair request receives a framed response")
    func sameUserRequest() async throws {
        let server = LauncherIPCServer(handler: { envelope in
            #expect(envelope.kind == .handshake)
            return .accepted(
                workspaceMatched: false,
                windowFocused: false,
                waitSupported: false
            )
        })
        let pair = try SocketPair()
        try writeAll(
            try LauncherIPCCodec.encode(
                LauncherIPCEnvelope(kind: .handshake, requestID: "same-user")
            ),
            to: pair.client
        )

        await server.serveConnectionForTesting(pair.releaseServer())
        let response = try readResponse(from: pair.client)
        #expect(
            response
                == .accepted(
                    workspaceMatched: false,
                    windowFocused: false,
                    waitSupported: false
                )
        )
    }

    @Test("Peer UID is checked before malformed body bytes are read")
    func foreignUIDRejectedBeforeBodyRead() async throws {
        let server = LauncherIPCServer(
            peerUID: { _ in getuid() &+ 1 },
            handler: { _ in
                Issue.record("Foreign peer must never reach the request handler")
                return .accepted(
                    workspaceMatched: false,
                    windowFocused: false,
                    waitSupported: false
                )
            }
        )
        let pair = try SocketPair()
        try writeAll(Data(repeating: 0, count: 9), to: pair.client)

        await server.serveConnectionForTesting(pair.releaseServer())
        #expect(try readResponse(from: pair.client) == .rejected(reason: "peer user mismatch"))
    }

    @Test("Oversized and malformed frames receive typed rejection responses")
    func invalidFramesRejected() async throws {
        let oversizedLength = UInt32(LauncherIPCProtocol.maxFrameBytes + 1)
        let oversizedHeader = Data([
            0x52, 0x41, 0x46, 0x55,
            UInt8(LauncherIPCProtocol.wireVersion),
            UInt8((oversizedLength >> 24) & 0xFF),
            UInt8((oversizedLength >> 16) & 0xFF),
            UInt8((oversizedLength >> 8) & 0xFF),
            UInt8(oversizedLength & 0xFF),
        ])

        for frame in [oversizedHeader, Data(repeating: 0, count: 9)] {
            let server = LauncherIPCServer()
            let pair = try SocketPair()
            try writeAll(frame, to: pair.client)
            await server.serveConnectionForTesting(pair.releaseServer())
            #expect(try readResponse(from: pair.client) == .rejected(reason: "malformed request"))
        }

        let incompatibleWireHeader = Data([0x52, 0x41, 0x46, 0x55, 99, 0, 0, 0, 0])
        let server = LauncherIPCServer()
        let pair = try SocketPair()
        try writeAll(incompatibleWireHeader, to: pair.client)
        await server.serveConnectionForTesting(pair.releaseServer())
        #expect(
            try readResponse(from: pair.client)
                == .rejected(reason: "incompatible wire version")
        )
    }

    @Test("Envelope version and unknown kind receive typed rejections")
    func typedEnvelopeRejections() async throws {
        let envelopes = [
            LauncherIPCEnvelope(
                kind: .handshake,
                requestID: "protocol-version",
                protocolVersion: LauncherIPCProtocol.protocolVersion + 1
            ),
            LauncherIPCEnvelope(kind: .unknown("future"), requestID: "unknown-kind"),
        ]
        let expected: [LauncherIPCResponse] = [
            .rejected(reason: "incompatible protocol version"),
            .rejected(reason: "unsupported request kind"),
        ]

        for (envelope, response) in zip(envelopes, expected) {
            let server = LauncherIPCServer()
            let pair = try SocketPair()
            try writeAll(try LauncherIPCCodec.encode(envelope), to: pair.client)
            await server.serveConnectionForTesting(pair.releaseServer())
            #expect(try readResponse(from: pair.client) == response)
        }
    }

    @Test("Two socketpair clients are handled independently")
    func concurrentClients() async throws {
        let server = LauncherIPCServer(handler: { envelope in
            .accepted(
                workspaceMatched: envelope.requestID == "first",
                windowFocused: envelope.requestID == "second",
                waitSupported: false
            )
        })
        let first = try SocketPair()
        let second = try SocketPair()
        try writeAll(
            try LauncherIPCCodec.encode(
                LauncherIPCEnvelope(kind: .handshake, requestID: "first")
            ),
            to: first.client
        )
        try writeAll(
            try LauncherIPCCodec.encode(
                LauncherIPCEnvelope(kind: .handshake, requestID: "second")
            ),
            to: second.client
        )

        async let firstServe: Void = server.serveConnectionForTesting(first.releaseServer())
        async let secondServe: Void = server.serveConnectionForTesting(second.releaseServer())
        _ = await (firstServe, secondServe)

        #expect(
            try readResponse(from: first.client)
                == .accepted(
                    workspaceMatched: true,
                    windowFocused: false,
                    waitSupported: false
                )
        )
        #expect(
            try readResponse(from: second.client)
                == .accepted(
                    workspaceMatched: false,
                    windowFocused: true,
                    waitSupported: false
                )
        )
    }

    @Test("A failed second listener never unlinks the live owner's socket")
    func liveSocketOwnershipIsPreserved() async throws {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/rafu-ipc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = LauncherIPCSocketPath.resolve(baseDirectory: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let owner = LauncherIPCServer(socketURL: socketURL)
        try await owner.startListening()

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: socketURL.deletingLastPathComponent().path
        )
        let socketAttributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((socketAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let contender = LauncherIPCServer(socketURL: socketURL)
        await #expect(throws: LauncherIPCServerError.alreadyRunning) {
            try await contender.startListening()
        }
        await contender.stopListening()
        #expect(FileManager.default.fileExists(atPath: socketURL.path))

        let silentClient = try connectSocket(at: socketURL)
        await owner.stopListening()
        Darwin.close(silentClient)
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }
}

private final class SocketPair {
    let client: Int32
    private var server: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        client = descriptors[0]
        server = descriptors[1]
    }

    func releaseServer() -> Int32 {
        let descriptor = server
        server = -1
        return descriptor
    }

    deinit {
        Darwin.close(client)
        if server >= 0 { Darwin.close(server) }
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
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
    }
}

private func readResponse(from fileDescriptor: Int32) throws -> LauncherIPCResponse {
    var decoder = LauncherIPCFrameDecoder()
    var storage = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = storage.withUnsafeMutableBytes { bytes in
            Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count == 0 {
            try decoder.finish()
            throw POSIXError(.ENODATA)
        }
        if let body = try decoder.consume(Data(storage.prefix(count))).first {
            return try LauncherIPCCodec.decode(LauncherIPCResponse.self, from: body)
        }
    }
}

private func connectSocket(at url: URL) throws -> Int32 {
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var address = try LauncherSocketAddress.make(path: url.path)
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
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return fileDescriptor
}
