import Darwin
import Dispatch
import Foundation

public enum EnsembleCLIClientError: Error, Equatable, LocalizedError, Sendable {
    case disconnected
    case heartbeatTimeout
    case timedOut
    case failure(code: Int32, message: String)
    case rejected(reason: String)
    case unexpectedResponse
    case systemCall(name: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "Rafu.app closed the Ensemble connection."
        case .heartbeatTimeout:
            "Rafu.app missed three Ensemble heartbeats."
        case .timedOut:
            "The Ensemble await condition timed out."
        case .failure(_, let message):
            message
        case .rejected(let reason):
            "Rafu.app rejected the Ensemble request: \(reason)"
        case .unexpectedResponse:
            "Rafu.app returned an unexpected Ensemble response."
        case .systemCall(let name, let code):
            "Ensemble IPC \(name) failed (error \(code))."
        }
    }
}

public protocol EnsembleCLIClientProtocol: Sendable {
    func performEnsemble(_ payload: EnsembleRequestPayload) throws -> EnsembleResponsePayload

    func subscribe(
        payload: EnsembleRequestPayload,
        timeout: TimeInterval?,
        onSubscribed: (UInt64) throws -> Bool,
        onEvent: (EnsembleEvent) throws -> Bool
    ) throws
}

/// Synchronous, single-owner client used by the command-line executable.
/// One-shot verbs retain the launcher's two-connection handshake/request
/// sequence. A subscription owns one connection for its full framed stream.
public struct EnsembleCLIClient: EnsembleCLIClientProtocol, Sendable {
    typealias Connector = @Sendable () throws -> Int32

    public static let heartbeatInterval: TimeInterval = 15
    public static let missedHeartbeatLimit = 3
    public static let streamReadTimeout: TimeInterval =
        heartbeatInterval * TimeInterval(missedHeartbeatLimit)

    private let connector: Connector
    private let heartbeatTimeout: TimeInterval

    public init(socketURL: URL = LauncherIPCSocketPath.resolve()) {
        connector = { try Self.connect(to: socketURL) }
        heartbeatTimeout = Self.streamReadTimeout
    }

    init(
        heartbeatTimeout: TimeInterval = EnsembleCLIClient.streamReadTimeout,
        connector: @escaping Connector
    ) {
        self.connector = connector
        self.heartbeatTimeout = heartbeatTimeout
    }

    public func performEnsemble(
        _ payload: EnsembleRequestPayload
    ) throws -> EnsembleResponsePayload {
        let handshake = try exchange(
            LauncherIPCEnvelope(kind: .handshake),
            receiveTimeout: 2
        )
        guard case .accepted = handshake else {
            if case .rejected(let reason) = handshake {
                throw EnsembleCLIClientError.rejected(reason: reason)
            }
            throw EnsembleCLIClientError.unexpectedResponse
        }

        let kind: LauncherIPCRequestKind
        switch payload.verb {
        case "status": kind = .ensembleStatus
        case "artifact": kind = .ensembleArtifact
        default: throw EnsembleCLIClientError.unexpectedResponse
        }
        let response = try exchange(
            LauncherIPCEnvelope(kind: kind, ensemble: payload),
            receiveTimeout: 2
        )
        guard case .ensemble(let ensemble) = response else {
            if case .rejected(let reason) = response {
                throw EnsembleCLIClientError.rejected(reason: reason)
            }
            throw EnsembleCLIClientError.unexpectedResponse
        }
        return ensemble
    }

    /// Opens the stream, waits for its subscribed acknowledgement, invokes
    /// `onSubscribed` so callers can take a one-shot snapshot without a lost
    /// wakeup, then consumes events until either callback returns `true`.
    public func subscribe(
        payload: EnsembleRequestPayload,
        timeout: TimeInterval?,
        onSubscribed: (UInt64) throws -> Bool,
        onEvent: (EnsembleEvent) throws -> Bool
    ) throws {
        guard payload.verb == "await" else {
            throw EnsembleCLIClientError.unexpectedResponse
        }

        let fileDescriptor = try connector()
        defer { Darwin.close(fileDescriptor) }
        try Self.configure(
            fileDescriptor,
            receiveTimeout: min(heartbeatTimeout, timeout ?? heartbeatTimeout),
            sendTimeout: 2
        )

        let envelope = LauncherIPCEnvelope(kind: .ensembleSubscribe, ensemble: payload)
        try Self.writeAll(LauncherIPCCodec.encode(envelope), to: fileDescriptor)

        let deadline = timeout.map(Self.deadline(after:))
        var reader = StreamFrameReader()
        let responseBody = try reader.readBody(
            from: fileDescriptor,
            heartbeatTimeout: heartbeatTimeout,
            deadline: deadline
        )
        let response = try LauncherIPCCodec.decode(LauncherIPCResponse.self, from: responseBody)
        let cursor: UInt64
        switch response {
        case .ensemble(.subscribed(let acknowledgedCursor)):
            cursor = acknowledgedCursor
        case .ensemble(.failure(let code, let message)):
            throw EnsembleCLIClientError.failure(code: code, message: message)
        case .rejected(let reason):
            throw EnsembleCLIClientError.rejected(reason: reason)
        case .accepted, .ensemble:
            throw EnsembleCLIClientError.unexpectedResponse
        }

        if try onSubscribed(cursor) { return }

        while true {
            let body = try reader.readBody(
                from: fileDescriptor,
                heartbeatTimeout: heartbeatTimeout,
                deadline: deadline
            )
            let event = try LauncherIPCCodec.decode(EnsembleEvent.self, from: body)
            if try onEvent(event) { return }
        }
    }

    private func exchange(
        _ envelope: LauncherIPCEnvelope,
        receiveTimeout: TimeInterval
    ) throws -> LauncherIPCResponse {
        let fileDescriptor = try connector()
        defer { Darwin.close(fileDescriptor) }
        try Self.configure(fileDescriptor, receiveTimeout: receiveTimeout, sendTimeout: 2)
        try Self.writeAll(LauncherIPCCodec.encode(envelope), to: fileDescriptor)

        var reader = StreamFrameReader()
        let body = try reader.readBody(
            from: fileDescriptor,
            heartbeatTimeout: receiveTimeout,
            deadline: nil
        )
        return try LauncherIPCCodec.decode(LauncherIPCResponse.self, from: body)
    }

    private static func connect(to socketURL: URL) throws -> Int32 {
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw systemCallError("socket") }
        do {
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

    private static func configure(
        _ fileDescriptor: Int32,
        receiveTimeout: TimeInterval,
        sendTimeout: TimeInterval
    ) throws {
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
        try setTimeout(
            receiveTimeout,
            option: SO_RCVTIMEO,
            name: "setsockopt-receive-timeout",
            fileDescriptor: fileDescriptor
        )
        try setTimeout(
            sendTimeout,
            option: SO_SNDTIMEO,
            name: "setsockopt-send-timeout",
            fileDescriptor: fileDescriptor
        )
    }

    private static func setTimeout(
        _ seconds: TimeInterval,
        option: Int32,
        name: String,
        fileDescriptor: Int32
    ) throws {
        let microseconds = max(1, Int(min(seconds, TimeInterval(Int.max / 1_000_000)) * 1_000_000))
        var timeout = timeval(
            tv_sec: microseconds / 1_000_000,
            tv_usec: Int32(microseconds % 1_000_000)
        )
        guard
            Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                option,
                &timeout,
                socklen_t(MemoryLayout.size(ofValue: timeout))
            ) == 0
        else { throw systemCallError(name) }
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
                guard count > 0 else { throw EnsembleCLIClientError.disconnected }
                offset += count
            }
        }
    }

    fileprivate static func deadline(after seconds: TimeInterval) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds < Double(UInt64.max - now) else { return UInt64.max }
        return now + UInt64(nanoseconds)
    }

    fileprivate static func systemCallError(_ name: String) -> EnsembleCLIClientError {
        EnsembleCLIClientError.systemCall(name: name, code: errno)
    }
}

private struct StreamFrameReader {
    private var decoder = LauncherIPCFrameDecoder()
    private var pendingBodies: [Data] = []

    mutating func readBody(
        from fileDescriptor: Int32,
        heartbeatTimeout: TimeInterval,
        deadline: UInt64?
    ) throws -> Data {
        if !pendingBodies.isEmpty {
            return pendingBodies.removeFirst()
        }

        // A heartbeat proves liveness only when its complete RAFU frame
        // arrives. Partial header/body bytes must not restart this deadline:
        // otherwise a stalled or malicious peer could keep `await` alive
        // forever by trickling one byte per interval.
        let frameDeadline = EnsembleCLIClient.deadline(after: heartbeatTimeout)
        var storage = [UInt8](repeating: 0, count: 4_096)
        while true {
            let activeDeadline = min(deadline ?? UInt64.max, frameDeadline)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < activeDeadline else {
                throw timeoutError(
                    userDeadline: deadline,
                    frameDeadline: frameDeadline
                )
            }
            let wait = TimeInterval(activeDeadline - now) / 1_000_000_000
            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let milliseconds = Int32(
                max(1, min(ceil(wait * 1_000), TimeInterval(Int32.max))))
            let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw EnsembleCLIClient.systemCallError("poll")
            }
            if pollResult == 0 {
                continue
            }
            let count = storage.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                throw EnsembleCLIClient.systemCallError("read")
            }
            if count == 0 {
                try decoder.finish()
                throw EnsembleCLIClientError.disconnected
            }

            let bodies = try decoder.consume(Data(storage.prefix(count)))
            if let first = bodies.first {
                pendingBodies.append(contentsOf: bodies.dropFirst())
                return first
            }
        }
    }

    private func timeoutError(
        userDeadline: UInt64?,
        frameDeadline: UInt64
    ) -> EnsembleCLIClientError {
        if let userDeadline, userDeadline <= frameDeadline {
            return .timedOut
        }
        return .heartbeatTimeout
    }
}
