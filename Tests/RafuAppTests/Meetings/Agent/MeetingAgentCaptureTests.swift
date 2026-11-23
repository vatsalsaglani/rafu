import Darwin
import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Hidden meeting agent: Codex tool-list capture")
struct MeetingAgentCaptureTests {
    /// One HTTP request over a plain loopback socket (no proxy, no cache).
    private static func send(_ request: String, port: UInt16) -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return "" }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return "" }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes {
                write(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else { return "" }
            sent += count
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { break }
            response.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: response, as: UTF8.self)
    }

    private static func post(_ body: String) -> String {
        "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer secret\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    @Test("The listener answers the model list, keeps the request body and answers 500")
    func listener() async throws {
        let body = #"{"input":[]}"#
        let captured = try await MeetingAgentCaptureListener.capture(timeLimit: .seconds(10)) {
            port in
            let models = Self.send(
                "GET /v1/models?client_version=0.171.0 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                port: port)
            let responses = Self.send(Self.post(body), port: port)
            return [models, responses]
        }
        #expect(captured.body == Data(body.utf8))
        #expect(captured.value[0].hasPrefix("HTTP/1.1 200 OK"))
        #expect(captured.value[0].hasSuffix(#"{"object":"list","data":[]}"#))
        #expect(captured.value[1].hasPrefix("HTTP/1.1 500"))
    }

    @Test("A body over the limit is not kept, and the listener closes after the work")
    func bounds() async throws {
        let large = String(repeating: "a", count: MeetingAgentLimits.maximumCaptureBodyBytes + 1)
        let captured = try await MeetingAgentCaptureListener.capture(timeLimit: .seconds(10)) {
            port in
            (port, Self.send(Self.post(large), port: port))
        }
        #expect(captured.body == nil)
        // The port is closed once the capture returned.
        #expect(Self.send("GET /v1/models HTTP/1.1\r\n\r\n", port: captured.value.0).isEmpty)
    }

    @Test("A Codex that sends no request fails the probe as tool list unreadable")
    func noRequest() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rafu-capture-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let process = FakeAgentProcessRunner([
            .lines([AgentStreamLines.codexThread, AgentStreamLines.codexTurnStarted], exit: 1)
        ])
        let capture = MeetingAgentCodexToolListCapture(timeLimit: .seconds(5))
        let executable = FakeAgentLocator().locate(.codex)!
        let result = await capture.check(
            executable, version: "0.171.0", environment: MeetingAgentEnvironment.make(),
            runsRoot: base, processRunner: process)
        #expect(result == .failed(reason: .toolListUnreadable))
        let run = process.runs.first
        #expect(run?.spec.arguments.contains(#"model_provider="capture""#) == true)
        #expect(run?.spec.standardInput == Data(MeetingAgentProbeTexts.captureInput.utf8))
        #expect(run?.directoryEntries.isEmpty == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).isEmpty)
    }
}
