import Darwin
import Foundation
import Synchronization
import Testing

@testable import RafuCore

@Suite(.serialized)
struct CanvasCodexSessionTests {
    @Test func terminalUsesPrivateEndpointAndServerStopsOnExit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let arguments = ["resume", "a value; $(literal)"]
        let status = CanvasCodexSession.run(
            executable: fixture.executable.path, arguments: arguments,
            environment: ProcessInfo.processInfo.environment.merging([
                "RAFU_CANVAS_TOKEN": "fixture-token",
                "RAFU_CANVAS_SOCKET": "/tmp/fixture-bridge.sock",
            ]) { _, value in value },
            serverArguments: ["-c", "mcp_servers.rafu.command=\"/test/bridge\""]
        )
        #expect(status == 23)
        let terminal = try fixture.read("terminal.json")
        let server = try fixture.read("server.json")
        let terminalArguments = try #require(terminal["arguments"] as? [String])
        let serverArguments = try #require(server["arguments"] as? [String])
        #expect(terminalArguments.first == "--remote")
        let endpoint = try #require(terminalArguments.dropFirst().first)
        #expect(endpoint.hasPrefix("unix:///tmp/rafu-cdx-"))
        #expect(Array(terminalArguments.dropFirst(2)) == arguments)
        #expect(serverArguments.prefix(2) == ["app-server", "--listen"])
        let backendEndpoint = String(endpoint.dropLast("terminal".count)) + "socket"
        #expect(serverArguments[2] == backendEndpoint)
        #expect(
            serverArguments.contains(
                "mcp_servers.rafu.env.RAFU_CANVAS_CODEX_ENDPOINT=\"\(backendEndpoint)\""))
        #expect(
            serverArguments.contains(
                "mcp_servers.rafu.env.RAFU_CANVAS_CODEX_EXECUTABLE=\"\(fixture.executable.path)\""))
        let serverPID = try #require(server["pid"] as? Int32)
        #expect(kill(serverPID, 0) == -1)
        #expect(errno == ESRCH)
        #expect(
            !FileManager.default.fileExists(atPath: String(endpoint.dropFirst("unix://".count))))
    }

    /// Records bridge requests and printed lines for a supervisor run.
    private final class BridgeProbe: Sendable {
        let requests = Mutex<[CanvasBridgeRequest]>([])
        let lines = Mutex<[String]>([])
        let bindReply = Mutex(CanvasBridgeResponse())
        let bindFailure = Mutex<(any Error)?>(nil)

        func exchange(_ request: CanvasBridgeRequest) throws -> CanvasBridgeResponse {
            requests.withLock { $0.append(request) }
            if request.operation == "bind" {
                if let failure = bindFailure.withLock({ $0 }) { throw failure }
                return bindReply.withLock { $0 }
            }
            return CanvasBridgeResponse()
        }

        func run(_ fixture: Fixture) -> Int32 {
            CanvasCodexSession.run(
                executable: fixture.executable.path, arguments: [],
                environment: ProcessInfo.processInfo.environment.merging([
                    "RAFU_CANVAS_TOKEN": "fixture-private-token",
                    "RAFU_CANVAS_SOCKET": "/tmp/fixture-bridge.sock",
                ]) { _, value in value },
                serverArguments: [],
                exchange: { try self.exchange($0) },
                report: { line in self.lines.withLock { $0.append(line) } })
        }
    }

    @Test func releaseFollowsTheTerminalExitSoAnotherRunCanBind() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = BridgeProbe()
        #expect(probe.run(fixture) == 23)
        let requests = probe.requests.withLock { $0 }
        #expect(requests.map(\.operation) == ["bind", "release"])
        #expect(requests[1].endpoint == requests[0].endpoint)
        #expect(requests[1].provider == "codex")
        #expect(requests.allSatisfy { $0.token == "fixture-private-token" })
        // A normal exit prints nothing.
        #expect(probe.lines.withLock { $0.isEmpty })
    }

    @Test func refusedBindReportsTheAppReasonAndANextStep() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = BridgeProbe()
        let reason = "Another agent is already connected in this terminal."
        probe.bindReply.withLock { $0 = CanvasBridgeResponse(error: reason) }
        #expect(probe.run(fixture) == 126)
        let lines = probe.lines.withLock { $0 }
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.hasPrefix("Rafu: Ensemble could not bind the Codex session."))
        #expect(line.contains(reason))
        #expect(line.contains("start a new terminal"))
        #expect(!line.contains("rafu-cdx"))
        #expect(!line.contains("fixture-private-token"))
        #expect(!line.contains("/tmp"))
        #expect(line.utf8.count < 300)
        #expect(probe.requests.withLock { $0.map(\.operation) } == ["bind"])
        // No terminal started, so there is nothing to release.
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("terminal.json").path))
    }

    @Test func unreachableAppDuringBindIsNamedWithoutDetail() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = BridgeProbe()
        probe.bindFailure.withLock { $0 = LauncherIPCClientError.disconnected }
        #expect(probe.run(fixture) == 126)
        let line = try #require(probe.lines.withLock { $0.first })
        #expect(line.contains("Rafu did not answer."))
        #expect(line.contains("Run codex again"))
        #expect(!line.contains("rafu-cdx"))
    }

    @Test func deliveryPreservesMessageAndThreadArguments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let socket = try fixture.bindSocket()
        defer { Darwin.close(socket) }
        let threadID = UUID().uuidString
        let message = "Review this line.\nLiteral: ; $(touch /never-run)"
        try await CanvasCodexSession.sendApproved(
            executable: fixture.executable.path, endpoint: fixture.endpoint,
            threadID: threadID, text: message, approvedPaths: [fixture.executable.path]
        )
        let queued = try fixture.read("queue.json")
        #expect(
            queued["arguments"] as? [String]
                == [
                    "queue", "--remote", fixture.endpoint, "--thread", threadID, "--message",
                    message,
                ]
        )
    }

    @Test func plainLaunchPreparesThreadButExplicitResumeKeepsItsSelection() {
        #expect(CanvasCodexSession.shouldPrepareThread([]))
        #expect(
            CanvasCodexSession.shouldPrepareThread(["--model", "example", "Explain this file"]))
        #expect(!CanvasCodexSession.shouldPrepareThread(["resume", "--last"]))
        #expect(!CanvasCodexSession.shouldPrepareThread(["-C", "/workspace", "fork", "--last"]))
    }

    @Test func controlConnectionCreatesResumableThreadWithoutStartingTurn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let process = Process()
        process.executableURL = fixture.executable
        process.arguments = ["app-server", "--listen", fixture.endpoint]
        let ready = Pipe()
        process.standardOutput = ready
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        let rpc = try CanvasCodexRPC(endpoint: fixture.endpoint)
        let thread = try rpc.createThread(cwd: fixture.root.path)
        #expect(thread == "00000000-0000-4000-8000-000000000001")
        try rpc.resumeThread(thread)
        let requests = try fixture.read("requests.json")
        #expect(
            requests["methods"] as? [String] == [
                "initialize", "initialized", "thread/start", "thread/name/set", "thread/resume",
            ])
    }

    @Test func controlConnectionRejectsOversizedFramesBeforeReadingPayload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let process = Process()
        process.executableURL = fixture.executable
        process.arguments = ["app-server", "--listen", fixture.endpoint]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "RAFU_TEST_RPC_OVERSIZE": "1"
        ]) { _, value in value }
        let ready = Pipe()
        process.standardOutput = ready
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        #expect(throws: CanvasCodexRPC.RPCError.protocolViolation) {
            _ = try CanvasCodexRPC(endpoint: fixture.endpoint)
        }
    }

    @Test func proxyRevokesBeforeForwardingNavigationButAllowsInitialResume() throws {
        let backend = try Fixture()
        let frontend = try Fixture()
        defer {
            backend.remove()
            frontend.remove()
        }
        let process = Process()
        process.executableURL = backend.executable
        process.arguments = ["app-server", "--listen", backend.endpoint]
        let ready = Pipe()
        process.standardOutput = ready
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        let expected = "00000000-0000-4000-8000-000000000001"
        let marker = backend.root.appendingPathComponent("suspended")
        let proxy = try CanvasCodexProxy(
            frontend: frontend.root.appendingPathComponent("socket").path,
            backend: backend.endpoint, threadID: expected
        ) { _ in
            try Data("revoked".utf8).write(to: marker)
        }
        defer { proxy.stop() }
        let rpc = try CanvasCodexRPC(endpoint: frontend.endpoint)
        try rpc.resumeThread(expected)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        _ = try rpc.createThread(cwd: backend.root.path)
        let requests = try backend.read("requests.json")
        #expect(requests["suspensionSeen"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func proxyStreamsLargeMatchedResponsesAndRejectsUnknownIDs(unknownID: Bool) throws {
        let backend = try Fixture()
        let frontend = try Fixture()
        defer {
            backend.remove()
            frontend.remove()
        }
        let server = Process()
        server.executableURL = backend.executable
        server.arguments = ["app-server", "--listen", backend.endpoint]
        server.environment = ProcessInfo.processInfo.environment.merging([
            "RAFU_TEST_PROXY_LARGE": unknownID ? "unknown" : "matched"
        ]) { _, value in value }
        let ready = Pipe()
        server.standardOutput = ready
        try server.run()
        defer {
            server.terminate()
            server.waitUntilExit()
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        let marker = backend.root.appendingPathComponent("suspended")
        let proxy = try CanvasCodexProxy(
            frontend: frontend.root.appendingPathComponent("socket").path,
            backend: backend.endpoint, threadID: UUID().uuidString
        ) { reason in
            try Data(reason.rawValue.utf8).write(to: marker)
        }
        defer { proxy.stop() }
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        client.arguments = [
            "-c",
            #"""
            import json, socket, struct, sys
            connection = socket.socket(socket.AF_UNIX)
            connection.settimeout(5)
            connection.connect(sys.argv[1])
            connection.sendall(b'GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n\r\n')
            def exact(count):
                data = b''
                while len(data) < count:
                    part = connection.recv(count - len(data))
                    if not part: raise EOFError()
                    data += part
                return data
            header = b''
            while not header.endswith(b'\r\n\r\n'): header += exact(1)
            for identifier in [1, 2]:
                request = json.dumps({'id': identifier, 'method': 'fixture/large'}).encode()
                connection.sendall(bytes([129, 128 | len(request)]) + bytes(4) + request)
                if sys.argv[2] == 'unknown':
                    assert connection.recv(1) == b''
                    break
                header = exact(2)
                length = header[1] & 127
                if length == 126: length = struct.unpack('!H', exact(2))[0]
                elif length == 127: length = struct.unpack('!Q', exact(8))[0]
                response = json.loads(exact(length))
                assert response['id'] == identifier
                assert response['result']['padding'] == 'x' * 524288
            connection.close()
            """#, frontend.root.appendingPathComponent("socket").path,
            unknownID ? "unknown" : "matched",
        ]
        try client.run()
        client.waitUntilExit()
        #expect(client.terminationStatus == 0)
        if unknownID {
            #expect(try String(contentsOf: marker, encoding: .utf8) == "transportLost")
        }
    }

    @Test func largeResponseEnvelopeRequiresCanonicalResponseAndBoundedID() {
        #expect(CanvasCodexProxy.responseID(Data(#"{ "id" : 7, "result": "#.utf8)) == "7")
        #expect(CanvasCodexProxy.responseID(Data(#"{"id":"a\"b","error":"#.utf8)) != nil)
        #expect(CanvasCodexProxy.responseID(Data(#"{"id":7,"method":"#.utf8)) == nil)
        #expect(CanvasCodexProxy.responseID(Data(#"{"params":{},"id":7,"result":"#.utf8)) == nil)
        #expect(CanvasCodexProxy.responseID(Data(#"{"id":true,"result":"#.utf8)) == nil)
    }

    @Test func proxyRejectsOtherThreadAndCachedRuntimeIdentity() {
        let expected = UUID().uuidString
        #expect(
            !CanvasCodexProxy.requiresSuspension(
                ["method": "thread/resume", "params": ["threadId": expected]], threadID: expected,
                outgoing: true))
        #expect(
            CanvasCodexProxy.requiresSuspension(
                ["method": "thread/resume", "params": ["threadId": UUID().uuidString]],
                threadID: expected, outgoing: true))
        #expect(
            CanvasCodexProxy.requiresSuspension(
                ["method": "thread/unsubscribe", "params": ["threadId": expected]],
                threadID: expected, outgoing: true))
        #expect(
            CanvasCodexProxy.requiresSuspension(
                ["method": "thread/started", "params": ["thread": ["id": UUID().uuidString]]],
                threadID: expected, outgoing: false))
    }

    @Test func startupMetadataReadDoesNotSelectAnotherConversation() {
        let expected = UUID().uuidString
        let other = UUID().uuidString
        for params: [String: Any] in [
            ["threadId": other], ["threadId": other, "includeTurns": false],
        ] {
            #expect(
                !CanvasCodexProxy.requiresSuspension(
                    ["method": "thread/read", "params": params], threadID: expected, outgoing: true)
            )
        }
        #expect(
            CanvasCodexProxy.requiresSuspension(
                ["method": "thread/read", "params": ["threadId": other, "includeTurns": true]],
                threadID: expected, outgoing: true))
        #expect(
            CanvasCodexProxy.requiresSuspension(
                ["method": "thread/resume", "params": ["threadId": other]],
                threadID: expected, outgoing: true))
        #expect(
            CanvasCodexProxy.requiresSuspension(
                ["method": "thread/unknown", "params": ["threadId": other]],
                threadID: expected, outgoing: true))
    }

    @Test func startupSummaryTurnQueriesDoNotSelectAnotherConversation() {
        let expected = UUID().uuidString
        let other = UUID().uuidString
        let queries: [[String: Any]] = [
            ["threadId": other, "limit": 1],
            ["threadId": other, "limit": 1, "itemsView": NSNull()],
            ["threadId": other, "itemsView": "notLoaded"],
            ["threadId": other, "itemsView": "summary"],
        ]
        for params in queries {
            #expect(
                !CanvasCodexProxy.requiresSuspension(
                    ["method": "thread/turns/list", "params": params], threadID: expected,
                    outgoing: true))
        }
        for view in ["full", "unknown"] {
            #expect(
                CanvasCodexProxy.requiresSuspension(
                    [
                        "method": "thread/turns/list",
                        "params": ["threadId": other, "itemsView": view],
                    ],
                    threadID: expected, outgoing: true))
        }
    }

    @Test func executableApprovalUsesResolvedInstallPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: CanvasCodexSession.SessionError.untrustedExecutable) {
            try CanvasCodexSession.validateExecutable(
                fixture.executable.path, approvedPaths: ["/usr/bin/codex"])
        }
        let link = fixture.root.appendingPathComponent("approved-codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.executable)
        try CanvasCodexSession.validateExecutable(
            fixture.executable.path, approvedPaths: [link.path])
    }

    @Test func listenerMayBeOwnedSymlinkToOwnedSocketButNotRegularFile() throws {
        let advertised = try Fixture()
        let actual = try Fixture()
        defer {
            advertised.remove()
            actual.remove()
        }
        let socket = try actual.bindSocket()
        defer { Darwin.close(socket) }
        let link = advertised.root.appendingPathComponent("socket")
        let target = actual.root.appendingPathComponent("socket")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try CanvasCodexSession.validateEndpoint(advertised.endpoint)
        // The advertised directory remains 0700. Only the resolved parent changes.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: actual.root.path)
        #expect(throws: CanvasCodexSession.SessionError.invalidEndpoint) {
            try CanvasCodexSession.validateEndpoint(advertised.endpoint)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: actual.root.path)
        let jump = advertised.root.appendingPathComponent("jump")
        try FileManager.default.createSymbolicLink(at: jump, withDestinationURL: actual.root)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: jump.appendingPathComponent("socket"))
        #expect(throws: CanvasCodexSession.SessionError.invalidEndpoint) {
            try CanvasCodexSession.validateEndpoint(advertised.endpoint)
        }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual.executable)
        #expect(throws: CanvasCodexSession.SessionError.invalidEndpoint) {
            try CanvasCodexSession.validateEndpoint(advertised.endpoint)
        }
    }

    @Test func rejectsUnownedOrMalformedEndpointsAndInvalidMessages() async throws {
        for endpoint in [
            "ws://127.0.0.1:1", "unix:///tmp/other/socket", "unix:///tmp/rafu-cdx-../socket",
        ] {
            #expect(throws: CanvasCodexSession.SessionError.invalidEndpoint) {
                try CanvasCodexSession.validateEndpoint(endpoint)
            }
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let socket = try fixture.bindSocket()
        defer { Darwin.close(socket) }
        await #expect(throws: CanvasCodexSession.SessionError.invalidMessage) {
            try await CanvasCodexSession.sendApproved(
                executable: fixture.executable.path, endpoint: fixture.endpoint, threadID: "wrong",
                text: "message", approvedPaths: [fixture.executable.path]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        #expect(throws: CanvasCodexSession.SessionError.invalidEndpoint) {
            try CanvasCodexSession.validateEndpoint(fixture.endpoint)
        }
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        var endpoint: String { "unix://\(root.path)/socket" }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/rafu-cdx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            executable = root.appendingPathComponent("fake-codex")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let literal = String(decoding: try encoder.encode(root.path), as: UTF8.self)
            let source = """
                #!/usr/bin/python3
                import base64, hashlib, json, os, signal, socket, struct, sys
                root = \(literal)
                def record(name):
                    with open(root + '/' + name, 'w') as stream:
                        json.dump({'pid': os.getpid(), 'arguments': sys.argv[1:]}, stream)
                if sys.argv[1] == 'app-server':
                    record('server.json')
                    server = socket.socket(socket.AF_UNIX)
                    server.bind(sys.argv[3][len('unix://'):])
                    server.listen(1)
                    print('R', end='', flush=True)
                    def exact(connection, count):
                        data = b''
                        while len(data) < count:
                            chunk = connection.recv(count - len(data))
                            if not chunk:
                                raise EOFError()
                            data += chunk
                        return data
                    def serve(connection):
                        headers = b''
                        while not headers.endswith(b'\\r\\n\\r\\n'):
                            headers += exact(connection, 1)
                        key = [line.split(b':', 1)[1].strip() for line in headers.split(b'\\r\\n') if line.lower().startswith(b'sec-websocket-key:')][0]
                        accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                        connection.sendall(b'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: ' + accept + b'\\r\\n\\r\\n')
                        methods = []
                        while True:
                            header = exact(connection, 2)
                            length = header[1] & 127
                            if length == 126:
                                length = struct.unpack('!H', exact(connection, 2))[0]
                            elif length == 127:
                                length = struct.unpack('!Q', exact(connection, 8))[0]
                            assert header[1] & 128
                            mask = exact(connection, 4)
                            raw = exact(connection, length)
                            request = json.loads(bytes(value ^ mask[index % 4] for index, value in enumerate(raw)))
                            methods.append(request['method'])
                            with open(root + '/requests.json', 'w') as stream:
                                json.dump({'methods': methods, 'suspensionSeen': os.path.exists(root + '/suspended')}, stream)
                            if 'id' not in request:
                                continue
                            result = {'thread': {'id': '00000000-0000-4000-8000-000000000001'}} if request['method'] == 'thread/start' else {}
                            if os.getenv('RAFU_TEST_RPC_OVERSIZE'):
                                connection.sendall(bytes([129, 127]) + struct.pack('!Q', 262145))
                                continue
                            if request['method'] == 'fixture/large':
                                result = {'padding': 'x' * 524288}
                            identifier = request['id'] + 99 if os.getenv('RAFU_TEST_PROXY_LARGE') == 'unknown' else request['id']
                            body = json.dumps({'id': identifier, 'result': result}).encode()
                            connection.sendall((bytes([129, 127]) + struct.pack('!Q', len(body)) if len(body) > 125 else bytes([129, len(body)])) + body)
                    while True:
                        connection, _ = server.accept()
                        try:
                            serve(connection)
                        except EOFError:
                            pass
                        finally:
                            connection.close()
                elif sys.argv[1] == 'queue':
                    record('queue.json')
                else:
                    record('terminal.json')
                    sys.exit(23)
                """
            try Data(source.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func bindSocket() throws -> Int32 {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(descriptor >= 0)
            var address = try LauncherSocketAddress.make(
                path: root.appendingPathComponent("socket").path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(result == 0)
            return descriptor
        }

        func read(_ name: String) throws -> [String: Any] {
            try #require(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: root.appendingPathComponent(name))) as? [String: Any]
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
