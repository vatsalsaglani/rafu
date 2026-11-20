import Darwin
import Foundation
import Synchronization
import Testing

@testable import RafuCore

/// The Codex answer path: a fake app-server and a fake TUI talk through the real
/// proxy, and the test answers a request the way the app would.
@Suite(.serialized)
struct CanvasCodexApprovalTests {
    // MARK: Fixtures

    /// Lines a child process prints, each one JSON. A test waits for a line
    /// with a bounded wait on a signal, never on a fixed sleep.
    private final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        private let cursor = Mutex(0)
        private let signal = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            Thread.detachNewThread { [self] in
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        signal.signal()
                        return
                    }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        lines.withLock { $0.append(line) }
                        signal.signal()
                    }
                }
            }
        }

        /// Every line up to and including the first one that `matches`, or nil
        /// after ten seconds. Lines before the match are consumed.
        func collect(until matches: ([String: Any]) -> Bool) -> [[String: Any]]? {
            let deadline = DispatchTime.now() + 10
            while true {
                let found = lines.withLock { lines -> [[String: Any]]? in
                    let start = cursor.withLock { $0 }
                    var taken: [[String: Any]] = []
                    for index in start..<lines.count {
                        let object =
                            (try? JSONSerialization.jsonObject(with: Data(lines[index].utf8)))
                            as? [String: Any] ?? [:]
                        taken.append(object)
                        if matches(object) {
                            cursor.withLock { $0 = index + 1 }
                            return taken
                        }
                    }
                    return nil
                }
                if let found { return found }
                if signal.wait(timeout: deadline) == .timedOut { return nil }
            }
        }

        func next(where matches: ([String: Any]) -> Bool) -> [String: Any]? {
            collect(until: matches)?.last
        }
    }

    private static let serverScript = #"""
        import base64, hashlib, json, socket, struct, sys, threading
        lock = threading.Lock()
        def emit(value):
            with lock:
                sys.stdout.write(json.dumps(value) + '\n')
                sys.stdout.flush()
        def exact(c, count):
            data = b''
            while len(data) < count:
                chunk = c.recv(count - len(data))
                if not chunk: raise EOFError()
                data += chunk
            return data
        def send(c, value):
            data = json.dumps(value).encode()
            if len(data) < 126: head = bytes([129, len(data)])
            elif len(data) < 65536: head = bytes([129, 126]) + struct.pack('!H', len(data))
            else: head = bytes([129, 127]) + struct.pack('!Q', len(data))
            c.sendall(head + data)
        def serve(c, number):
            headers = b''
            while not headers.endswith(b'\r\n\r\n'): headers += exact(c, 1)
            key = [l.split(b':', 1)[1].strip() for l in headers.split(b'\r\n') if l.lower().startswith(b'sec-websocket-key:')][0]
            accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
            c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
            assembled = b''
            while True:
                header = exact(c, 2)
                fin, opcode, masked = header[0] & 128 != 0, header[0] & 15, header[1] & 128 != 0
                length = header[1] & 127
                if length == 126: length = struct.unpack('!H', exact(c, 2))[0]
                elif length == 127: length = struct.unpack('!Q', exact(c, 8))[0]
                mask = exact(c, 4) if masked else bytes(4)
                raw = exact(c, length)
                if opcode == 8: return
                data = bytes(v ^ mask[i % 4] for i, v in enumerate(raw))
                emit({'connection': number, 'frame': True, 'opcode': opcode, 'fin': fin, 'masked': masked})
                assembled += data
                if not fin: continue
                message = json.loads(assembled)
                assembled = b''
                emit({'connection': number, 'message': message, 'masked': masked})
                if 'method' in message and 'id' in message:
                    if message['method'] == 'fixture/send':
                        for frame in message['params']['frames']: send(c, frame)
                    send(c, {'id': message['id'], 'result': {}})
        server = socket.socket(socket.AF_UNIX)
        server.bind(sys.argv[1])
        server.listen(8)
        emit({'ready': True})
        count = 0
        while True:
            connection, _ = server.accept()
            count += 1
            def run(connection=connection, number=count):
                try: serve(connection, number)
                except EOFError: pass
                finally: connection.close()
            threading.Thread(target=run, daemon=True).start()
        """#

    private static let clientScript = #"""
        import json, socket, struct, sys, threading, time
        lock = threading.Lock()
        def emit(value):
            with lock:
                sys.stdout.write(json.dumps(value) + '\n')
                sys.stdout.flush()
        def exact(c, count):
            data = b''
            while len(data) < count:
                chunk = c.recv(count - len(data))
                if not chunk: raise EOFError()
                data += chunk
            return data
        c = socket.socket(socket.AF_UNIX)
        c.settimeout(20)
        c.connect(sys.argv[1])
        c.sendall(b'GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n\r\n')
        header = b''
        while not header.endswith(b'\r\n\r\n'): header += exact(c, 1)
        assert header.startswith(b'HTTP/1.1 101 '), header
        emit({'connected': True})
        def listen():
            try:
                while True:
                    head = exact(c, 2)
                    length = head[1] & 127
                    if length == 126: length = struct.unpack('!H', exact(c, 2))[0]
                    elif length == 127: length = struct.unpack('!Q', exact(c, 8))[0]
                    emit({'received': json.loads(exact(c, length))})
            except Exception:
                emit({'listenerEnded': True})
        threading.Thread(target=listen, daemon=True).start()
        def frame(text, fin, opcode):
            data = text.encode()
            first = (128 if fin else 0) | opcode
            if len(data) < 126: head = bytes([first, 128 | len(data)])
            elif len(data) < 65536: head = bytes([first, 128 | 126]) + struct.pack('!H', len(data))
            else: head = bytes([first, 128 | 127]) + struct.pack('!Q', len(data))
            mask = bytes([1, 2, 3, 4])
            return head + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(data))
        for line in sys.stdin:
            command = json.loads(line)
            if command['cmd'] == 'send':
                c.sendall(frame(json.dumps(command['message']), True, 1))
            elif command['cmd'] == 'fragment':
                c.sendall(frame(command['text'], command['fin'], command['opcode']))
            elif command['cmd'] == 'close':
                break
        c.close()
        """#

    /// One fake TUI process.
    private final class TUI: Sendable {
        private let process: Process
        private let input: FileHandle
        private let output: Lines
        private let nextID = Mutex(1_000)

        init(socket: String, script: URL) throws {
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, socket]
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            input = stdin.fileHandleForWriting
            output = Lines(stdout.fileHandleForReading)
            try process.run()
            #expect(output.next { $0["connected"] != nil } != nil)
        }

        private func write(_ object: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            try? input.write(contentsOf: data + Data("\n".utf8))
        }

        /// A request that has the server send `frames` to this TUI, then answer.
        func serverSends(_ frames: [[String: Any]]) {
            let id = nextID.withLock { value -> Int in
                value += 1
                return value
            }
            write([
                "cmd": "send",
                "message": ["id": id, "method": "fixture/send", "params": ["frames": frames]],
            ])
        }

        func send(_ message: [String: Any]) { write(["cmd": "send", "message": message]) }

        func fragment(_ text: String, fin: Bool, opcode: Int) {
            write(["cmd": "fragment", "text": text, "fin": fin, "opcode": opcode])
        }

        /// A request the server answers at once. Its answer proves that every
        /// frame sent before it passed through the proxy.
        func barrier() -> Bool {
            let id = nextID.withLock { value -> Int in
                value += 1
                return value
            }
            send(["id": id, "method": "fixture/echo", "params": [:]])
            return output.next { ($0["received"] as? [String: Any])?["id"] as? Int == id } != nil
        }

        func received(where matches: ([String: Any]) -> Bool) -> [String: Any]? {
            output.next { ($0["received"] as? [String: Any]).map(matches) ?? false }?["received"]
                as? [String: Any]
        }

        func close() {
            write(["cmd": "close"])
            process.waitUntilExit()
        }
    }

    /// What the proxy told the supervisor, or a test standing in for it.
    private final class Hooks: Sendable {
        let requests = Mutex<[CanvasAgentRequest]>([])
        let cleared = Mutex<[UUID]>([])
        private let requestSignal = DispatchSemaphore(value: 0)
        private let clearSignal = DispatchSemaphore(value: 0)

        var approvals: CanvasCodexProxy.Approvals {
            CanvasCodexProxy.Approvals(
                request: { [self] request in
                    requests.withLock { $0.append(request) }
                    requestSignal.signal()
                },
                clear: { [self] key in
                    cleared.withLock { $0.append(key) }
                    clearSignal.signal()
                })
        }

        private let requestsRead = Mutex(0)
        private let clearsRead = Mutex(0)

        /// The next request in arrival order. Each signal stands for one
        /// append, so the n-th wait returns the n-th request even when
        /// several arrive before the test reads them.
        func awaitRequest() -> CanvasAgentRequest? {
            guard requestSignal.wait(timeout: .now() + 10) == .success else { return nil }
            let index = requestsRead.withLock { read in
                defer { read += 1 }
                return read
            }
            return requests.withLock { $0.indices.contains(index) ? $0[index] : nil }
        }

        /// The next cleared key in arrival order.
        func awaitClear() -> UUID? {
            guard clearSignal.wait(timeout: .now() + 10) == .success else { return nil }
            let index = clearsRead.withLock { read in
                defer { read += 1 }
                return read
            }
            return cleared.withLock { $0.indices.contains(index) ? $0[index] : nil }
        }
    }

    private final class SuspensionLog: Sendable {
        let reasons = Mutex<[CanvasCodexProxy.SuspensionReason]>([])
    }

    /// The fake server, the proxy in front of it, and the scripts.
    private final class Harness {
        let root: URL
        let thread = UUID().uuidString
        let server = Process()
        let serverLines: Lines
        let hooks = Hooks()
        let suspensions = SuspensionLog()
        let clientScript: URL
        private(set) var proxy: CanvasCodexProxy!
        var frontend: String { root.appendingPathComponent("terminal").path }

        init(supervisor: CanvasCodexApprovalSupervisor? = nil) throws {
            // A write to a fake TUI that already ended must fail, not end the test run.
            signal(SIGPIPE, SIG_IGN)
            root = URL(fileURLWithPath: "/tmp/rafu-cdx-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let serverScript = root.appendingPathComponent("server.py")
            clientScript = root.appendingPathComponent("client.py")
            try Data(CanvasCodexApprovalTests.serverScript.utf8).write(to: serverScript)
            try Data(CanvasCodexApprovalTests.clientScript.utf8).write(to: clientScript)
            let backend = root.appendingPathComponent("socket").path
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = [serverScript.path, backend]
            let stdout = Pipe()
            server.standardOutput = stdout
            try server.run()
            serverLines = Lines(stdout.fileHandleForReading)
            #expect(serverLines.next { $0["ready"] != nil } != nil)
            proxy = try CanvasCodexProxy(
                frontend: frontend, backend: "unix://" + backend, threadID: thread,
                approvals: supervisor?.hooks ?? hooks.approvals,
                suspend: { [log = suspensions] reason in
                    log.reasons.withLock { $0.append(reason) }
                })
            supervisor?.attach(proxy)
        }

        func tui() throws -> TUI { try TUI(socket: frontend, script: clientScript) }

        func tearDown() {
            proxy.stop()
            server.terminate()
            server.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }

        func approvalFrame(
            id: Any, method: String = "item/commandExecution/requestApproval",
            params: [String: Any] = ["command": "echo hi", "cwd": "/work"], thread: String? = nil
        ) -> [String: Any] {
            var all = params
            all["threadId"] = thread ?? self.thread
            all["turnId"] = "turn-1"
            all["itemId"] = "item-1"
            return ["id": id, "method": method, "params": all]
        }

        /// The messages the server received in order, up to the next echo.
        func serverMessages(upToEcho tui: TUI) -> [[String: Any]] {
            guard tui.barrier() else { return [] }
            let lines =
                serverLines.collect {
                    ($0["message"] as? [String: Any])?["method"] as? String == "fixture/echo"
                } ?? []
            return lines.compactMap { $0["message"] as? [String: Any] }
        }
    }

    private static func jsonText(_ value: Any?) -> String {
        guard let value,
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isAnswer(_ message: [String: Any]) -> Bool {
        message["method"] == nil && message["result"] != nil
    }

    // MARK: Tests

    @Test(arguments: ["41", "\"req-7/a\""])
    func aRequestOpensAndAnInjectedAcceptReachesTheServerWithTheOriginalID(raw: String) throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        let id = try JSONSerialization.jsonObject(
            with: Data(raw.utf8), options: [.fragmentsAllowed])
        tui.serverSends([harness.approvalFrame(id: id)])
        let request = try #require(harness.hooks.awaitRequest())
        #expect(request.kind == .command)
        #expect(request.command == "echo hi")
        // The TUI still gets its own prompt, unchanged.
        let seen = try #require(
            tui.received { $0["method"] as? String == "item/commandExecution/requestApproval" })
        #expect(Self.jsonText(seen["id"]) == Self.jsonText(id))

        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .sent)
        // A second inject finds nothing, so only one frame ever goes up.
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .unknown)
        let messages = harness.serverMessages(upToEcho: tui)
        let answers = messages.filter(Self.isAnswer)
        #expect(answers.count == 1)
        let answer = try #require(answers.first)
        #expect(Self.jsonText(answer["id"]) == Self.jsonText(id))
        #expect(Self.jsonText(answer["result"]) == #"{"decision":"accept"}"#)
    }

    @Test func theAnswerFrameIsMasked() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 9)])
        let request = try #require(harness.hooks.awaitRequest())
        #expect(harness.proxy.inject(key: request.key, decision: .decline) == .sent)
        #expect(tui.barrier())
        let line = try #require(
            harness.serverLines.next {
                ($0["message"] as? [String: Any]).map(Self.isAnswer) ?? false
            })
        #expect(line["masked"] as? Bool == true)
    }

    @Test func refusesUnknownKeysAndDecisionsThatDoNotFit() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        #expect(harness.proxy.inject(key: UUID(), decision: .accept) == .unknown)
        tui.serverSends([harness.approvalFrame(id: 3)])
        let request = try #require(harness.hooks.awaitRequest())
        // Not valid for a command: nothing is sent and the request stays open.
        #expect(harness.proxy.inject(key: request.key, decision: .answers(["q": "a"])) == .refused)
        #expect(
            harness.proxy.inject(key: request.key, decision: .acceptForSession) == .sent)
        let answers = harness.serverMessages(upToEcho: tui).filter(Self.isAnswer)
        #expect(answers.count == 1)
        #expect(Self.jsonText(answers.first?["result"]) == #"{"decision":"acceptForSession"}"#)
    }

    @Test func aHumanCheckpointAcceptsOnlyAcceptDeclineAndCancel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([
            harness.approvalFrame(
                id: 4, params: ["command": "ls", "cwd": "/work", "kind": "humanCommand"])
        ])
        let request = try #require(harness.hooks.awaitRequest())
        #expect(harness.proxy.inject(key: request.key, decision: .acceptForSession) == .refused)
        #expect(harness.proxy.inject(key: request.key, decision: .cancel) == .sent)
    }

    @Test func aRequestOnlyTheTerminalCanAnswerIsNeverInjected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        // A bell character changes the text, so what the user reads would differ.
        tui.serverSends([
            harness.approvalFrame(id: 6, params: ["command": "echo \u{07}hi", "cwd": "/work"])
        ])
        let request = try #require(harness.hooks.awaitRequest())
        #expect(request.terminalOnly)
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .refused)
    }

    @Test func aTerminalAnswerClearsTheRequestAndLaterInjectsFindNothing() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 5)])
        let request = try #require(harness.hooks.awaitRequest())
        tui.send(["id": 5, "result": ["decision": "decline"]])
        #expect(harness.hooks.awaitClear() == request.key)
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .unknown)
        // The TUI's answer still went through, once.
        let answers = harness.serverMessages(upToEcho: tui).filter(Self.isAnswer)
        #expect(answers.count == 1)
        #expect(Self.jsonText(answers.first?["result"]) == #"{"decision":"decline"}"#)
    }

    @Test func aResolvedNotificationClearsTheRequestAndStillReachesTheTerminal() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 8)])
        let request = try #require(harness.hooks.awaitRequest())
        tui.serverSends([
            [
                "method": "serverRequest/resolved",
                "params": ["threadId": harness.thread, "requestId": 8],
            ]
        ])
        #expect(harness.hooks.awaitClear() == request.key)
        #expect(
            tui.received { $0["method"] as? String == "serverRequest/resolved" } != nil)
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .unknown)
    }

    @Test func aResolvedNotificationForAnotherRequestKeepsTheEntry() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 8)])
        let request = try #require(harness.hooks.awaitRequest())
        tui.serverSends([
            [
                "method": "serverRequest/resolved",
                "params": ["threadId": harness.thread, "requestId": 99],
            ]
        ])
        #expect(tui.received { $0["method"] as? String == "serverRequest/resolved" } != nil)
        #expect(harness.hooks.cleared.withLock { $0.isEmpty })
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .sent)
    }

    @Test func theEndOfTheTurnClearsEveryRequest() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 1), harness.approvalFrame(id: 2)])
        _ = try #require(harness.hooks.awaitRequest())
        _ = try #require(harness.hooks.awaitRequest())
        tui.serverSends([
            ["method": "turn/completed", "params": ["threadId": harness.thread, "turn": [:]]]
        ])
        _ = try #require(harness.hooks.awaitClear())
        _ = try #require(harness.hooks.awaitClear())
        #expect(Set(harness.hooks.cleared.withLock { $0 }).count == 2)
        let keys = harness.hooks.requests.withLock { $0.map(\.key) }
        for key in keys { #expect(harness.proxy.inject(key: key, decision: .accept) == .unknown) }
    }

    @Test func theTableHoldsEightAndEverythingStillReachesTheTerminal() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends((1...9).map { harness.approvalFrame(id: $0) })
        for _ in 1...8 { _ = try #require(harness.hooks.awaitRequest()) }
        // The ninth is not announced, but the TUI got it and can answer it.
        #expect(tui.received { ($0["id"] as? Int) == 9 && $0["method"] != nil } != nil)
        // The barrier's answer comes after all nine frames, so the proxy is done with them.
        #expect(tui.barrier())
        #expect(harness.hooks.requests.withLock { $0.count } == 8)
        // Answering one frees a place for the next.
        tui.send(["id": 1, "result": ["decision": "accept"]])
        _ = try #require(harness.hooks.awaitClear())
        tui.serverSends([harness.approvalFrame(id: 10)])
        let tenth = try #require(harness.hooks.awaitRequest())
        #expect(harness.proxy.inject(key: tenth.key, decision: .accept) == .sent)
    }

    @Test func anotherThreadAndOtherMethodsAreNotAnnounced() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        // A request for a notification (no id) and an unrelated method pass through.
        tui.serverSends([
            [
                "method": "item/commandExecution/requestApproval",
                "params": ["threadId": harness.thread, "command": "ls"],
            ],
            ["id": 12, "method": "item/other/request", "params": ["threadId": harness.thread]],
        ])
        #expect(tui.barrier())
        #expect(harness.hooks.requests.withLock { $0.isEmpty })
        // Another thread's request revokes the route and is not announced.
        tui.serverSends([harness.approvalFrame(id: 13, thread: UUID().uuidString)])
        #expect(tui.barrier())
        #expect(harness.hooks.requests.withLock { $0.isEmpty })
        #expect(harness.suspensions.reasons.withLock { $0 } == [.sessionChanged])
    }

    @Test func permissionAndQuestionAnswersHaveTheShapesCodexExpects() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        let profile: [String: Any] = ["network": ["enabled": true]]
        tui.serverSends([
            harness.approvalFrame(
                id: 21, method: "item/permissions/requestApproval",
                params: ["cwd": "/work", "reason": "fetch", "permissions": profile]),
            harness.approvalFrame(
                id: 22, method: "item/permissions/requestApproval",
                params: ["cwd": "/work", "reason": "fetch", "permissions": profile]),
            harness.approvalFrame(
                id: 23, method: "item/tool/requestUserInput",
                params: [
                    "questions": [
                        [
                            "id": "color", "header": "Color", "question": "Which?",
                            "isOther": false, "isSecret": false,
                            "options": [
                                ["label": "Red", "description": "warm"],
                                ["label": "Blue", "description": "cool"],
                            ],
                        ]
                    ]
                ]),
            harness.approvalFrame(
                id: 24, method: "item/fileChange/requestApproval", params: ["reason": "edit"]),
        ])
        let accept = try #require(harness.hooks.awaitRequest())
        let decline = try #require(harness.hooks.awaitRequest())
        let question = try #require(harness.hooks.awaitRequest())
        let change = try #require(harness.hooks.awaitRequest())
        #expect(accept.kind == .permissions)
        #expect(question.kind == .userInput)
        #expect(harness.proxy.inject(key: accept.key, decision: .acceptForSession) == .sent)
        #expect(harness.proxy.inject(key: decline.key, decision: .decline) == .sent)
        #expect(
            harness.proxy.inject(key: question.key, decision: .answers(["color": "Blue"])) == .sent)
        // A question needs an answer, not a verdict.
        #expect(harness.proxy.inject(key: change.key, decision: .answers(["x": "y"])) == .refused)
        // A file change is terminal-only: no verdict is sent from Rafu.
        #expect(change.kind == .fileChange)
        #expect(change.terminalOnly)
        #expect(harness.proxy.inject(key: change.key, decision: .cancel) == .refused)
        let answers = harness.serverMessages(upToEcho: tui).filter(Self.isAnswer)
        let byID = Dictionary(
            uniqueKeysWithValues: answers.map {
                (Self.jsonText($0["id"]), Self.jsonText($0["result"]))
            })
        #expect(
            byID["21"] == #"{"permissions":{"network":{"enabled":true}},"scope":"session"}"#)
        #expect(byID["22"] == #"{"permissions":{},"scope":"turn"}"#)
        #expect(byID["23"] == #"{"answers":{"color":{"answers":["Blue"]}}}"#)
        #expect(byID["24"] == nil)
    }

    @Test func aFragmentedOutgoingMessageDelaysTheAnswerUntilItEnds() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 31)])
        let request = try #require(harness.hooks.awaitRequest())
        let first = #"{"id": 77, "method": "fixture/echo", "#
        let second = #""params": {}}"#
        tui.fragment(first, fin: false, opcode: 1)
        // The server saw the first fragment, so the proxy wrote it and is mid-message.
        #expect(
            harness.serverLines.next { $0["frame"] != nil && $0["fin"] as? Bool == false } != nil)
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .busy)
        tui.fragment(second, fin: true, opcode: 0)
        #expect(
            harness.serverLines.next { ($0["message"] as? [String: Any])?["id"] as? Int == 77 }
                != nil)
        // The entry survived the refusal and goes out between messages.
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .sent)
    }

    @Test func endingTheConnectionClearsItsRequests() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        tui.serverSends([harness.approvalFrame(id: 51)])
        let request = try #require(harness.hooks.awaitRequest())
        tui.close()
        #expect(harness.hooks.awaitClear() == request.key)
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .unknown)
    }

    @Test func aNewerConnectionReplacesTheOldOneAndItsRequests() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let first = try harness.tui()
        defer { first.close() }
        first.serverSends([harness.approvalFrame(id: 61)])
        let request = try #require(harness.hooks.awaitRequest())
        let second = try harness.tui()
        defer { second.close() }
        #expect(harness.hooks.awaitClear() == request.key)
        // An ID the old connection held means nothing to the new one.
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .unknown)
    }

    @Test func aStoppedProxyRefusesToAnswer() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 71)])
        let request = try #require(harness.hooks.awaitRequest())
        harness.proxy.stop()
        #expect(harness.proxy.inject(key: request.key, decision: .accept) == .unknown)
    }

    @Test func theAnswerFrameCarriesLongPayloadsAndAMask() throws {
        let paths = (0..<7).map { "/very/long/path/\(String(repeating: "x", count: 200))\($0)" }
        let profile = try JSONSerialization.data(
            withJSONObject: ["fileSystem": ["read": paths]], options: [.sortedKeys])
        let request = CanvasAgentRequest(
            kind: .permissions, permissions: ["Read /a"], terminalOnly: false)
        let frame = try #require(
            CanvasCodexProxy.answerFrame(
                rpcID: "7", request: request, decision: .accept, permissions: profile))
        #expect(frame[0] == 0x81)
        #expect(frame[1] == 0x80 | 126)
        let length = Int(frame[2]) << 8 | Int(frame[3])
        let mask = Array(frame[4..<8])
        let payload = Data(frame[8...].enumerated().map { $0.element ^ mask[$0.offset % 4] })
        #expect(payload.count == length)
        let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["id"] as? Int == 7)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["scope"] as? String == "turn")
        // A permissions request has no cancel, and accepting needs the profile.
        let cancelled = CanvasCodexProxy.answerFrame(
            rpcID: "7", request: request, decision: .cancel, permissions: profile)
        #expect(cancelled == nil)
        let bare = CanvasCodexProxy.answerFrame(
            rpcID: "7", request: request, decision: .accept, permissions: nil)
        #expect(bare == nil)
    }

    // MARK: Supervisor

    /// Stands in for the app: records the operations and returns a set answer.
    private final class AppProbe: Sendable {
        let operations = Mutex<[CanvasBridgeRequest]>([])
        let answer = Mutex<CanvasAgentRequestAnswer?>(nil)
        let opened = DispatchSemaphore(value: 0)
        let polled = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)

        func exchange(_ request: CanvasBridgeRequest) throws -> CanvasBridgeResponse {
            operations.withLock { $0.append(request) }
            switch request.operation {
            case CanvasAgentRequest.openOperation: opened.signal()
            case CanvasAgentRequest.pollOperation:
                polled.signal()
                return CanvasBridgeResponse(approvalDecision: answer.withLock { $0 })
            case CanvasAgentRequest.closeOperation: closed.signal()
            default: break
            }
            return CanvasBridgeResponse()
        }

        func count(_ operation: String) -> Int {
            operations.withLock { $0.filter { $0.operation == operation }.count }
        }
    }

    @Test func theSupervisorOpensPollsAnswersClosesAndStopsItsTimer() throws {
        let probe = AppProbe()
        let supervisor = CanvasCodexApprovalSupervisor(
            token: "private-token", endpoint: "unix:///tmp/endpoint", threadID: "thread-1",
            interval: .milliseconds(20), exchange: { try probe.exchange($0) })
        let harness = try Harness(supervisor: supervisor)
        defer {
            supervisor.stop()
            harness.tearDown()
        }
        #expect(!supervisor.isPolling)
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 90_817_263)])
        #expect(probe.opened.wait(timeout: .now() + 10) == .success)
        let opened = try #require(
            probe.operations.withLock { $0.first { $0.operation == "approvalOpen" } })
        let approval = try #require(opened.approval)
        #expect(approval.command == "echo hi")
        #expect(opened.provider == "codex")
        #expect(opened.endpoint == "unix:///tmp/endpoint")
        #expect(opened.token == "private-token")
        // The JSON-RPC id never leaves the proxy.
        let encoded = String(decoding: try JSONEncoder().encode(opened), as: UTF8.self)
        #expect(!encoded.contains("90817263"))
        // A poll runs while the request waits, and no answer injects nothing.
        #expect(probe.polled.wait(timeout: .now() + 10) == .success)
        #expect(supervisor.isPolling)
        probe.answer.withLock {
            $0 = CanvasAgentRequestAnswer(key: approval.key, decision: .accept)
        }
        #expect(probe.closed.wait(timeout: .now() + 10) == .success)
        supervisor.settle()
        #expect(!supervisor.isPolling)
        // The app kept returning the answer until the close, yet one frame went up.
        let answers = harness.serverMessages(upToEcho: tui).filter(Self.isAnswer)
        #expect(answers.count == 1)
        #expect(Self.jsonText(answers.first?["result"]) == #"{"decision":"accept"}"#)
        #expect(probe.count("approvalClose") == 1)
        let close = try #require(
            probe.operations.withLock { $0.first { $0.operation == "approvalClose" } })
        #expect(close.approvalKey == approval.key)
    }

    @Test func theSupervisorClosesARequestTheTerminalAnsweredAndStopsPolling() throws {
        let probe = AppProbe()
        let supervisor = CanvasCodexApprovalSupervisor(
            token: "t", endpoint: "unix:///tmp/endpoint", threadID: "thread-1",
            interval: .milliseconds(20), exchange: { try probe.exchange($0) })
        let harness = try Harness(supervisor: supervisor)
        defer {
            supervisor.stop()
            harness.tearDown()
        }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 82)])
        #expect(probe.polled.wait(timeout: .now() + 10) == .success)
        tui.send(["id": 82, "result": ["decision": "accept"]])
        #expect(probe.closed.wait(timeout: .now() + 10) == .success)
        supervisor.settle()
        #expect(!supervisor.isPolling)
        #expect(probe.count("approvalClose") == 1)
    }

    @Test func aRequestTheAppRefusesIsNotPolled() throws {
        final class Refusing: Sendable {
            let operations = Mutex<[String]>([])
            let opened = DispatchSemaphore(value: 0)
        }
        let probe = Refusing()
        let supervisor = CanvasCodexApprovalSupervisor(
            token: "t", endpoint: "unix:///tmp/endpoint", threadID: "thread-1",
            interval: .milliseconds(20),
            exchange: { request in
                probe.operations.withLock { $0.append(request.operation) }
                probe.opened.signal()
                return CanvasBridgeResponse(error: "Too many agent requests wait in this terminal.")
            })
        let harness = try Harness(supervisor: supervisor)
        defer {
            supervisor.stop()
            harness.tearDown()
        }
        let tui = try harness.tui()
        defer { tui.close() }
        tui.serverSends([harness.approvalFrame(id: 83)])
        #expect(probe.opened.wait(timeout: .now() + 10) == .success)
        supervisor.settle()
        #expect(!supervisor.isPolling)
        #expect(probe.operations.withLock { $0 } == ["approvalOpen"])
    }
}
