import Darwin
import Foundation
import OSLog
import RafuCore

nonisolated enum LauncherIPCServerError: Error, Equatable, Sendable {
    case alreadyRunning
    case occupiedPath
    case systemCall(name: String, code: Int32)
}

/// Owns Rafu's one same-user Unix-domain listener. Blocking socket syscalls
/// run only in detached tasks; actor state owns the listener fd, tracks each
/// accepted fd for shutdown, and never shares mutable byte buffers.
actor LauncherIPCServer {
    typealias PeerUIDProvider = @Sendable (Int32) throws -> uid_t
    typealias RequestHandler =
        @MainActor @Sendable (LauncherIPCEnvelope) async -> LauncherIPCResponse

    nonisolated static let shared = LauncherIPCServer()

    private nonisolated static let logger = Logger(
        subsystem: "dev.vatsalsaglani.rafu",
        category: "LauncherIPC"
    )

    private struct Connection: Sendable {
        let fileDescriptor: Int32
        let task: Task<Void, Never>
    }

    private let socketURL: URL
    private let peerUID: PeerUIDProvider
    private let handler: RequestHandler
    private var listenerFileDescriptor: Int32?
    private var ownsSocketPath = false
    private var acceptTask: Task<Void, Never>?
    private var connections: [UUID: Connection] = [:]

    init(
        socketURL: URL = LauncherIPCSocketPath.resolve(),
        peerUID: @escaping PeerUIDProvider = LauncherIPCServer.systemPeerUID,
        handler: @escaping RequestHandler = LauncherIPCServer.defaultHandler
    ) {
        self.socketURL = socketURL
        self.peerUID = peerUID
        self.handler = handler
    }

    /// Lifecycle-compatible fire-and-forget wrapper used by the frozen app
    /// delegate hook. Tests and diagnostics call `startListening()` directly
    /// when they need the startup result.
    nonisolated func start() {
        Task {
            do {
                try await startListening()
            } catch LauncherIPCServerError.alreadyRunning {
                Self.logger.info("Listener start rejected: already running")
            } catch {
                Self.logger.error("Listener start rejected")
            }
        }
    }

    /// Lifecycle-compatible wrapper. `stopListening()` remains awaitable for
    /// tests and controlled shutdown paths.
    nonisolated func stop() {
        Task { await stopListening() }
    }

    /// Creates the private directory, safely removes only a stale socket,
    /// binds with mode 0600, and starts the detached accept loop. Idempotent
    /// for repeated calls on this actor instance.
    func startListening() throws {
        guard listenerFileDescriptor == nil else { return }

        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw Self.systemCallError("chmod-directory")
        }

        try prepareSocketPath()
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Self.systemCallError("socket") }

        do {
            var address = try LauncherSocketAddress.make(path: socketURL.path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(
                        listener,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                let code = errno
                if code == EADDRINUSE {
                    throw LauncherIPCServerError.alreadyRunning
                }
                throw LauncherIPCServerError.systemCall(name: "bind", code: code)
            }
            ownsSocketPath = true
            guard Darwin.chmod(socketURL.path, 0o600) == 0 else {
                throw Self.systemCallError("chmod-socket")
            }
            guard Darwin.listen(listener, 16) == 0 else {
                throw Self.systemCallError("listen")
            }
        } catch {
            Darwin.close(listener)
            unlinkOwnedSocket()
            throw error
        }

        listenerFileDescriptor = listener
        acceptTask = Task.detached(name: "Launcher IPC accept") { [weak self] in
            await self?.runAcceptLoop(listener: listener)
        }
    }

    /// Closes the listener, shuts down every accepted fd to unblock reads,
    /// awaits their detached tasks, and removes only this server's socket.
    func stopListening() async {
        let acceptTask = acceptTask
        self.acceptTask = nil
        acceptTask?.cancel()

        if let listenerFileDescriptor {
            self.listenerFileDescriptor = nil
            Darwin.shutdown(listenerFileDescriptor, SHUT_RDWR)
            Darwin.close(listenerFileDescriptor)
        }

        let activeConnections = Array(connections.values)
        for connection in activeConnections {
            connection.task.cancel()
            Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
        }

        await acceptTask?.value
        for connection in activeConnections {
            await connection.task.value
        }
        connections.removeAll()
        unlinkOwnedSocket()
    }

    /// Headless socketpair seam. Ownership of `fileDescriptor` transfers to
    /// this method and it is closed exactly once after the response attempt.
    func serveConnectionForTesting(_ fileDescriptor: Int32) async {
        await Self.processConnection(
            fileDescriptor,
            expectedUID: getuid(),
            peerUID: peerUID,
            handler: handler
        )
        Darwin.close(fileDescriptor)
    }

    private nonisolated func runAcceptLoop(listener: Int32) async {
        while !Task.isCancelled {
            let accepted = Darwin.accept(listener, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                return
            }
            if Task.isCancelled {
                Darwin.close(accepted)
                return
            }
            await registerConnection(accepted)
        }
    }

    private func registerConnection(_ fileDescriptor: Int32) {
        guard listenerFileDescriptor != nil else {
            Darwin.close(fileDescriptor)
            return
        }
        let id = UUID()
        let expectedUID = getuid()
        let peerUID = peerUID
        let handler = handler
        let task = Task.detached(name: "Launcher IPC connection") { [weak self] in
            await Self.processConnection(
                fileDescriptor,
                expectedUID: expectedUID,
                peerUID: peerUID,
                handler: handler
            )
            Darwin.close(fileDescriptor)
            await self?.connectionFinished(id)
        }
        connections[id] = Connection(fileDescriptor: fileDescriptor, task: task)
    }

    private func connectionFinished(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    /// Peer authentication is deliberately the first operation. No call to
    /// `read` occurs until the accepted socket's effective UID matches ours.
    private nonisolated static func processConnection(
        _ fileDescriptor: Int32,
        expectedUID: uid_t,
        peerUID: PeerUIDProvider,
        handler: RequestHandler
    ) async {
        do {
            guard try peerUID(fileDescriptor) == expectedUID else {
                try writeResponse(.rejected(reason: "peer user mismatch"), to: fileDescriptor)
                logger.info("Request unknown rejected")
                return
            }

            let envelope = try readEnvelope(from: fileDescriptor)
            let kind = logName(for: envelope.kind)
            let response: LauncherIPCResponse

            guard envelope.wireVersion == LauncherIPCProtocol.wireVersion else {
                response = .rejected(reason: "incompatible wire version")
                try writeResponse(response, to: fileDescriptor)
                logger.info("Request \(kind, privacy: .public) rejected")
                return
            }
            guard envelope.protocolVersion == LauncherIPCProtocol.protocolVersion else {
                response = .rejected(reason: "incompatible protocol version")
                try writeResponse(response, to: fileDescriptor)
                logger.info("Request \(kind, privacy: .public) rejected")
                return
            }
            if case .unknown = envelope.kind {
                response = .rejected(reason: "unsupported request kind")
                try writeResponse(response, to: fileDescriptor)
                logger.info("Request unknown rejected")
                return
            }

            response = await handler(envelope)
            try writeResponse(response, to: fileDescriptor)
            switch response {
            case .accepted:
                logger.info("Request \(kind, privacy: .public) accepted")
            case .rejected:
                logger.info("Request \(kind, privacy: .public) rejected")
            }
        } catch LauncherIPCFramingError.unsupportedWireVersion {
            try? writeResponse(
                .rejected(reason: "incompatible wire version"),
                to: fileDescriptor
            )
            logger.info("Request unknown rejected")
        } catch {
            try? writeResponse(.rejected(reason: "malformed request"), to: fileDescriptor)
            logger.info("Request unknown rejected")
        }
    }

    private nonisolated static func readEnvelope(from fileDescriptor: Int32) throws
        -> LauncherIPCEnvelope
    {
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
                throw LauncherIPCFramingError.truncatedFrame(
                    receivedBytes: 0,
                    expectedBytes: LauncherIPCFrameEncoder.headerByteCount
                )
            }

            let bodies = try decoder.consume(Data(storage.prefix(count)))
            if let body = bodies.first {
                return try LauncherIPCCodec.decode(LauncherIPCEnvelope.self, from: body)
            }
        }
    }

    private nonisolated static func writeResponse(
        _ response: LauncherIPCResponse,
        to fileDescriptor: Int32
    ) throws {
        let frame = try LauncherIPCCodec.encode(response)
        try frame.withUnsafeBytes { bytes in
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
                guard count > 0 else {
                    throw LauncherIPCServerError.systemCall(name: "write", code: EPIPE)
                }
                offset += count
            }
        }
    }

    private func prepareSocketPath() throws {
        var status = stat()
        guard lstat(socketURL.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw Self.systemCallError("lstat")
        }
        guard status.st_mode & S_IFMT == S_IFSOCK else {
            throw LauncherIPCServerError.occupiedPath
        }

        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Self.systemCallError("socket-probe") }
        defer { Darwin.close(probe) }

        var address = try LauncherSocketAddress.make(path: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    probe,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 { throw LauncherIPCServerError.alreadyRunning }
        let code = errno
        guard code == ECONNREFUSED || code == ENOENT else {
            throw LauncherIPCServerError.systemCall(name: "connect-probe", code: code)
        }
        guard Darwin.unlink(socketURL.path) == 0 || errno == ENOENT else {
            throw Self.systemCallError("unlink-stale")
        }
    }

    private func unlinkOwnedSocket() {
        guard ownsSocketPath else { return }
        ownsSocketPath = false
        var status = stat()
        guard lstat(socketURL.path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else {
            return
        }
        _ = Darwin.unlink(socketURL.path)
    }

    private nonisolated static func systemPeerUID(_ fileDescriptor: Int32) throws -> uid_t {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(fileDescriptor, &effectiveUID, &effectiveGID) == 0 else {
            throw systemCallError("getpeereid")
        }
        return effectiveUID
    }

    private nonisolated static func systemCallError(_ name: String) -> LauncherIPCServerError {
        LauncherIPCServerError.systemCall(name: name, code: errno)
    }

    private nonisolated static func logName(for kind: LauncherIPCRequestKind) -> String {
        switch kind {
        case .handshake: "handshake"
        case .openFolder: "openFolder"
        case .goto: "goto"
        case .unknown: "unknown"
        }
    }

    @MainActor
    private static func defaultHandler(
        _ envelope: LauncherIPCEnvelope
    ) async -> LauncherIPCResponse {
        switch envelope.kind {
        case .handshake:
            .accepted(workspaceMatched: false, windowFocused: false, waitSupported: false)
        case .openFolder, .goto, .unknown:
            .rejected(reason: "request router unavailable")
        }
    }
}
