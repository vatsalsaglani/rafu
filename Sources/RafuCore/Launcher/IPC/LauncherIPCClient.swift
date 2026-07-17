import Darwin
import Foundation

public enum LauncherIPCClientError: Error, Equatable, LocalizedError, Sendable {
    case disconnected
    case rejected(reason: String)
    case systemCall(name: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "Rafu.app closed the launcher connection before replying."
        case .rejected(let reason):
            "Rafu.app rejected the launcher request: \(reason)"
        case .systemCall(let name, let code):
            "Launcher IPC \(name) failed (error \(code))."
        }
    }

    public var isListenerUnavailable: Bool {
        guard case .systemCall(let name, let code) = self, name == "connect" else {
            return false
        }
        return code == ENOENT || code == ECONNREFUSED
    }
}

/// Synchronous, single-owner client for Rafu's short-lived launcher CLI.
/// Each exchange owns and closes exactly one fd; the I2 server contract is
/// one frame per connection, so handshake and request use sequential sockets.
public struct LauncherIPCClient: Sendable {
    typealias Connector = @Sendable () throws -> Int32

    private let connector: Connector

    public init(socketURL: URL = LauncherIPCSocketPath.resolve()) {
        connector = { try Self.connect(to: socketURL) }
    }

    init(connector: @escaping Connector) {
        self.connector = connector
    }

    public func perform(_ request: LauncherOpenRequest) throws -> LauncherIPCResponse {
        let handshake = try exchange(LauncherIPCEnvelope(kind: .handshake))
        guard case .accepted = handshake else {
            if case .rejected(let reason) = handshake {
                throw LauncherIPCClientError.rejected(reason: reason)
            }
            throw LauncherIPCClientError.disconnected
        }

        let kind: LauncherIPCRequestKind =
            request.sourceLocation == nil ? .openFolder : .goto
        return try exchange(LauncherIPCEnvelope(kind: kind, payload: request))
    }

    private func exchange(_ envelope: LauncherIPCEnvelope) throws -> LauncherIPCResponse {
        let fileDescriptor = try connector()
        defer { Darwin.close(fileDescriptor) }

        let frame = try LauncherIPCCodec.encode(envelope)
        try Self.writeAll(frame, to: fileDescriptor)
        return try Self.readResponse(from: fileDescriptor)
    }

    private static func connect(to socketURL: URL) throws -> Int32 {
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw systemCallError("socket") }
        do {
            var one: Int32 = 1
            guard
                Darwin.setsockopt(
                    fileDescriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &one,
                    socklen_t(MemoryLayout.size(ofValue: one))
                ) == 0
            else { throw systemCallError("setsockopt") }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            let timeoutLength = socklen_t(MemoryLayout.size(ofValue: timeout))
            guard
                Darwin.setsockopt(
                    fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength) == 0,
                Darwin.setsockopt(
                    fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength) == 0
            else { throw systemCallError("setsockopt") }

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
            guard result == 0 else { throw systemCallError("connect") }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
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
                    throw systemCallError("write")
                }
                guard count > 0 else { throw LauncherIPCClientError.disconnected }
                offset += count
            }
        }
    }

    private static func readResponse(from fileDescriptor: Int32) throws -> LauncherIPCResponse {
        var decoder = LauncherIPCFrameDecoder()
        var storage = [UInt8](repeating: 0, count: 4_096)

        while true {
            let count = storage.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemCallError("read")
            }
            if count == 0 {
                try decoder.finish()
                throw LauncherIPCClientError.disconnected
            }

            let bodies = try decoder.consume(Data(storage.prefix(count)))
            if let body = bodies.first {
                return try LauncherIPCCodec.decode(LauncherIPCResponse.self, from: body)
            }
        }
    }

    private static func systemCallError(_ name: String) -> LauncherIPCClientError {
        LauncherIPCClientError.systemCall(name: name, code: errno)
    }
}

/// Pure retry schedule used after `/usr/bin/open` starts the app without a
/// document argument. Its total is below the lane's approximately ten-second
/// cap and tests can assert it without sleeping.
public enum LauncherIPCReconnectSchedule {
    public static let delaysMicroseconds: [useconds_t] = [
        50_000, 100_000, 200_000, 400_000, 800_000,
        1_000_000, 1_000_000, 1_000_000, 1_000_000, 1_000_000,
        1_000_000, 1_000_000, 1_000_000,
    ]
}
