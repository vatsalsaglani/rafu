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

    @Test("A stuck client that sends a partial header is closed after the read timeout")
    func timedOutConnectionIsClosedWithMalformedRejection() async throws {
        // A short injected timeout keeps this test fast; production uses
        // `LauncherIPCServer.defaultConnectionTimeout` (5s).
        let server = LauncherIPCServer(connectionTimeout: 0.2)
        let pair = try SocketPair()
        try writeAll(Data([0x52, 0x41, 0x46]), to: pair.client)

        let start = ContinuousClock.now
        await server.serveConnectionForTesting(pair.releaseServer())
        let elapsed = ContinuousClock.now - start

        #expect(try readResponse(from: pair.client) == .rejected(reason: "malformed request"))
        // Well below the 5s production default — confirms the injected
        // timeout, not some unrelated bound, ended the stalled read.
        #expect(elapsed < .seconds(2))
    }

    @Test("A connection beyond the live cap is closed immediately, not queued")
    func connectionsAtCapAreClosedImmediately() async throws {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/rafu-ipc-cap-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let socketURL = LauncherIPCSocketPath.resolve(baseDirectory: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let server = LauncherIPCServer(
            socketURL: socketURL, connectionTimeout: 2, maxConnections: 1)
        try await server.startListening()

        // Occupies the only connection slot by never finishing its handshake.
        let blockedClient = try connectSocket(at: socketURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await server.liveConnectionCountForTesting < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await server.liveConnectionCountForTesting == 1)

        // A second connection arrives while the server is at capacity; the
        // accept loop must close it immediately (observed here as an
        // immediate EOF) rather than blocking or queuing it.
        let overflowClient = try connectSocket(at: socketURL)
        var buffer = [UInt8](repeating: 0, count: 8)
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(overflowClient, bytes.baseAddress, bytes.count)
        }
        #expect(readCount == 0)

        Darwin.close(blockedClient)
        Darwin.close(overflowClient)
        await server.stopListening()
    }
}

@Suite("Launcher request routing")
struct LauncherRequestRoutingTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test("Automatic and reuse requests focus an exact workspace match")
    func exactFolderMatch() {
        let roots = [OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/work/a"))]
        for policy in [LauncherActivationPolicy.automatic, .reuseWindow] {
            let request = openRequest("/work/a", policy: policy)
            #expect(
                LauncherRequestRouting.route(request: request, openRoots: roots)
                    == .focus(windowID: firstID)
            )
        }
    }

    @Test("New-window bypasses an existing exact match")
    func newWindowBypassesMatch() {
        let roots = [OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/work/a"))]
        let request = openRequest("/work/a", policy: .newWindow)
        #expect(
            LauncherRequestRouting.route(request: request, openRoots: roots)
                == .seedNewWindow(url: fileURL("/work/a"))
        )
    }

    @Test("A nonmatching request reuses the first ordered window")
    func nonMatchReusesOrderedWindow() {
        let roots = [
            OpenWorkspaceRoot(windowID: secondID, rootURL: fileURL("/work/b")),
            OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/work/a")),
        ]
        let request = openRequest("/work/c", policy: .automatic)
        #expect(
            LauncherRequestRouting.route(request: request, openRoots: roots)
                == .focus(windowID: secondID)
        )
    }

    @Test("No open window seeds the requested workspace")
    func emptyRegistrySeedsWindow() {
        let request = openRequest("/work/a")
        #expect(
            LauncherRequestRouting.route(request: request, openRoots: [])
                == .seedNewWindow(url: fileURL("/work/a"))
        )
    }

    @Test("Goto selects the deepest containing workspace and a relative file")
    func gotoSelectsDeepestRoot() {
        let roots = [
            OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/work")),
            OpenWorkspaceRoot(windowID: secondID, rootURL: fileURL("/work/a")),
        ]
        let location = RafuCore.SourceLocation(line: 42, column: 8)
        let request = gotoRequest("/work/a/Sources/main.swift", location: location)
        #expect(
            LauncherRequestRouting.route(request: request, openRoots: roots)
                == .focusAndGoto(
                    windowID: secondID,
                    file: "Sources/main.swift",
                    location: location
                )
        )
    }

    @Test("A goto outside every root reuses a window but opens its containing folder")
    func gotoOutsideWorkspace() {
        let roots = [OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/work/a"))]
        let request = gotoRequest("/other/main.swift", location: RafuCore.SourceLocation(line: 3))
        #expect(
            LauncherRequestRouting.route(request: request, openRoots: roots)
                == .focus(windowID: firstID)
        )
        #expect(
            LauncherRequestRouting.workspaceURL(for: request, openRoots: roots)?.path
                == "/other"
        )
        #expect(
            LauncherRequestRouting.relativeGotoPath(
                for: request,
                workspaceURL: fileURL("/other")
            ) == "main.swift"
        )
    }

    @Test("New-window goto seeds the matching root instead of the file's parent")
    func newWindowGotoUsesMatchedRoot() {
        let roots = [OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/work/a"))]
        let request = gotoRequest(
            "/work/a/Sources/main.swift",
            location: RafuCore.SourceLocation(line: 3),
            policy: .newWindow
        )
        #expect(
            LauncherRequestRouting.route(request: request, openRoots: roots)
                == .seedNewWindow(url: fileURL("/work/a"))
        )
    }

    @Test("Path-component boundaries prevent false prefix matches")
    func pathPrefixIsNotContainment() {
        let roots = [OpenWorkspaceRoot(windowID: firstID, rootURL: fileURL("/repo"))]
        let request = gotoRequest("/repo2/main.swift", location: RafuCore.SourceLocation(line: 1))
        #expect(!LauncherRequestRouting.workspaceMatched(request: request, openRoots: roots))
    }

    @Test("SSH and relative local targets are rejected by local routing")
    func unsupportedTargets() {
        let ssh = LauncherOpenRequest(target: .ssh(hostAlias: "prod", path: "/srv/app"))
        let relative = LauncherOpenRequest(target: .local(path: "relative/path"))
        #expect(LauncherRequestRouting.route(request: ssh, openRoots: []) == nil)
        #expect(LauncherRequestRouting.route(request: relative, openRoots: []) == nil)
    }

    private func openRequest(
        _ path: String,
        policy: LauncherActivationPolicy = .automatic
    ) -> LauncherOpenRequest {
        LauncherOpenRequest(target: .local(path: path), activationPolicy: policy)
    }

    private func gotoRequest(
        _ path: String,
        location: RafuCore.SourceLocation,
        policy: LauncherActivationPolicy = .automatic
    ) -> LauncherOpenRequest {
        LauncherOpenRequest(
            target: .local(path: path),
            sourceLocation: location,
            activationPolicy: policy
        )
    }
}

@MainActor
@Suite("Launcher request router effects")
struct LauncherRequestRouterEffectTests {
    @Test("Nonmatching reuse focuses before enqueuing the replacement folder")
    func reuseEffects() {
        let id = UUID()
        var events: [String] = []
        let router = LauncherRequestRouter(
            dependencies: dependencies(
                roots: [OpenWorkspaceRoot(windowID: id, rootURL: fileURL("/work/a"))],
                focus: { focusedID in
                    events.append("focus:\(focusedID)")
                    return true
                },
                enqueue: { url in events.append("enqueue:\(url.path)") }
            )
        )
        let request = LauncherOpenRequest(target: .local(path: "/work/b"))

        #expect(
            router.handle(
                LauncherIPCEnvelope(kind: .openFolder, payload: request, requestID: "reuse")
            )
                == .accepted(
                    workspaceMatched: false,
                    windowFocused: true,
                    waitSupported: false
                )
        )
        #expect(events == ["focus:\(id)", "enqueue:/work/b"])
    }

    @Test("New-window goto queues selection before enqueue and scene creation")
    func newWindowGotoEffects() {
        var events: [String] = []
        let router = LauncherRequestRouter(
            dependencies: dependencies(
                roots: [],
                enqueue: { url in events.append("enqueue:\(url.path)") },
                openWindow: {
                    events.append("openWindow")
                    return true
                },
                queueNewGoto: { root, relative, location in
                    events.append("goto:\(root.path):\(relative):\(location.line)")
                }
            )
        )
        let request = LauncherOpenRequest(
            target: .local(path: "/other/main.swift"),
            sourceLocation: RafuCore.SourceLocation(line: 7, column: 2),
            activationPolicy: .newWindow
        )

        #expect(
            router.handle(
                LauncherIPCEnvelope(kind: .goto, payload: request, requestID: "goto")
            )
                == .accepted(
                    workspaceMatched: false,
                    windowFocused: false,
                    waitSupported: false
                )
        )
        #expect(events == ["goto:/other:main.swift:7", "enqueue:/other", "openWindow"])
    }

    @Test("Matching goto uses the registered session directly")
    func matchingGotoEffects() {
        let id = UUID()
        var received: (UUID, String, RafuCore.SourceLocation)?
        let router = LauncherRequestRouter(
            dependencies: dependencies(
                roots: [OpenWorkspaceRoot(windowID: id, rootURL: fileURL("/work/a"))],
                goto: { windowID, relative, location in
                    received = (windowID, relative, location)
                    return true
                }
            )
        )
        let location = RafuCore.SourceLocation(line: 9, column: 4)
        let request = LauncherOpenRequest(
            target: .local(path: "/work/a/main.swift"),
            sourceLocation: location
        )

        #expect(
            router.handle(
                LauncherIPCEnvelope(kind: .goto, payload: request, requestID: "match")
            )
                == .accepted(
                    workspaceMatched: true,
                    windowFocused: true,
                    waitSupported: false
                )
        )
        #expect(received?.0 == id)
        #expect(received?.1 == "main.swift")
        #expect(received?.2 == location)
    }

    private func dependencies(
        roots: [OpenWorkspaceRoot],
        focus: @escaping (UUID) -> Bool = { _ in true },
        enqueue: @escaping (URL) -> Void = { _ in },
        openWindow: @escaping () -> Bool = { true },
        goto: @escaping (UUID, String, RafuCore.SourceLocation) -> Bool = { _, _, _ in true },
        queueNewGoto: @escaping (URL, String, RafuCore.SourceLocation) -> Void = { _, _, _ in }
    ) -> LauncherRequestRouter.Dependencies {
        LauncherRequestRouter.Dependencies(
            snapshots: { roots },
            focus: focus,
            enqueueFolder: enqueue,
            openWindow: openWindow,
            goto: goto,
            queueGoto: { _, _, _, _ in },
            queueGotoForNextWindow: queueNewGoto
        )
    }
}

private func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL
}

/// These tests drive raw, hand-rolled fds against the IPC server, and a
/// test-side `write` racing the server closing its end raises SIGPIPE, whose
/// default disposition KILLS the whole test process (surfaced on CI as every
/// in-flight test stuck at "started", and locally as `swift test
/// --no-parallel` dying with signal 13). Production code guards its own fds
/// with `SO_NOSIGPIPE` (`LauncherIPCClient`/`LauncherIPCServer`); the test
/// helpers below now do the same, and this process-wide SIG_IGN is the
/// belt-and-braces so a missed fd can never take down the test run — a
/// suppressed SIGPIPE just turns the write into a handled EPIPE.
private let sigpipeIgnoredForSocketTests: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

private func setNoSigPipe(_ fileDescriptor: Int32) {
    _ = sigpipeIgnoredForSocketTests
    var one: Int32 = 1
    _ = setsockopt(
        fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &one,
        socklen_t(MemoryLayout.size(ofValue: one))
    )
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
        setNoSigPipe(client)
        setNoSigPipe(server)
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
    setNoSigPipe(fileDescriptor)
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
