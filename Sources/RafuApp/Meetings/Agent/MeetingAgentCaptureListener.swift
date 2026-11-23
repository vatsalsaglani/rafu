import Darwin
import Foundation
import RafuCore
import Synchronization

/// The loopback listener of the Codex tool-list capture. It binds
/// `127.0.0.1` on a port that the system picks, answers `GET /v1/models…`
/// with an empty list and `POST /v1/responses` with status 500, and keeps
/// the first `POST /v1/responses` body. Bounds: at most
/// `maximumCaptureConnections` connections, a header of at most
/// `maximumCaptureHeaderBytes`, a body of at most `maximumCaptureBodyBytes`,
/// and the time limit. It never stores a header, and it is closed when the
/// capture ends (it is never open during a real run).
nonisolated enum MeetingAgentCaptureListener {
    struct Problem: Error {}

    /// Opens the listener, runs `work` with its port, and returns the
    /// captured body (nil when none came) with the value of `work`. The
    /// listener is closed before this returns.
    static func capture<Value: Sendable>(
        timeLimit: Duration, _ work: @Sendable (UInt16) async -> Value
    ) async throws -> (body: Data?, value: Value) {
        let (descriptor, port) = try openSocket()
        let stop = StopFlag()
        let deadline = ContinuousClock.now + timeLimit
        async let body = serve(descriptor, deadline: deadline, stop: stop)
        let value = await work(port)
        stop.set()
        return (await body, value)
    }

    // MARK: - Socket

    private static func openSocket() throws -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Problem() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw Problem()
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            close(descriptor)
            throw Problem()
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }

    /// Set when the work ended: the serving thread stops and closes the
    /// socket.
    final class StopFlag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    /// Serves on a private queue (the work blocks on `poll`), never on the
    /// Swift concurrency pool.
    private static func serve(
        _ descriptor: Int32, deadline: ContinuousClock.Instant, stop: StopFlag
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "dev.vatsalsaglani.rafu.meetings.agent-capture").async {
                let body = serveBlocking(descriptor, deadline: deadline, stop: stop)
                close(descriptor)
                continuation.resume(returning: body)
            }
        }
    }

    private static func serveBlocking(
        _ descriptor: Int32, deadline: ContinuousClock.Instant, stop: StopFlag
    ) -> Data? {
        var connections = 0
        while connections < MeetingAgentLimits.maximumCaptureConnections, !stop.isSet {
            guard let timeout = pollTimeout(until: deadline) else { return nil }
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, timeout)
            if ready < 0, errno != EINTR { return nil }
            guard ready > 0 else { continue }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            connections += 1
            var on: Int32 = 1
            setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let body = answer(client, deadline: deadline)
            close(client)
            if let body { return body }
        }
        return nil
    }

    /// At most 200 ms, so a stop is seen soon; nil after the deadline.
    private static func pollTimeout(until deadline: ContinuousClock.Instant) -> Int32? {
        let left = deadline - ContinuousClock.now
        guard left > .zero else { return nil }
        let milliseconds =
            left.components.seconds * 1_000
            + left.components.attoseconds / 1_000_000_000_000_000
        return Int32(max(1, min(milliseconds, 200)))
    }

    // MARK: - One connection

    /// Reads one request and answers it. Returns the body of a
    /// `POST /v1/responses`, else nil.
    private static func answer(_ client: Int32, deadline: ContinuousClock.Instant) -> Data? {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard buffer.count <= MeetingAgentLimits.maximumCaptureHeaderBytes,
                read(client, into: &buffer, deadline: deadline)
            else { return nil }
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headerEnd else { return nil }
        let header = String(
            decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1]

        if method == "GET", path.hasPrefix("/v1/models") {
            respond(client, status: "200 OK", body: #"{"object":"list","data":[]}"#)
            return nil
        }
        guard method == "POST", path == "/v1/responses" else {
            respond(client, status: "404 Not Found", body: "")
            return nil
        }
        // Only the length is read from the header; nothing else is kept.
        var length: Int?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "transfer-encoding" { return nil }
            if name == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length, length > 0, length <= MeetingAgentLimits.maximumCaptureBodyBytes else {
            respond(client, status: "500 Internal Server Error", body: "")
            return nil
        }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            guard read(client, into: &body, deadline: deadline) else { return nil }
        }
        guard body.count == length else { return nil }
        respond(client, status: "500 Internal Server Error", body: "")
        return body
    }

    /// Appends what one read gave. False at the end, an error or the deadline.
    private static func read(
        _ client: Int32, into data: inout Data, deadline: ContinuousClock.Instant
    )
        -> Bool
    {
        guard let timeout = pollTimeout(until: deadline) else { return false }
        var entry = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        let ready = poll(&entry, 1, timeout)
        if ready == 0 { return true }
        guard ready > 0 else { return errno == EINTR }
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        let count = Darwin.read(client, &chunk, chunk.count)
        guard count > 0 else { return false }
        data.append(contentsOf: chunk[0..<count])
        return true
    }

    private static func respond(_ client: Int32, status: String, body: String) {
        let text =
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            sent += count
        }
    }
}

/// The Codex tool-list capture of a probe (step 2): the final Codex array
/// plus the two capture settings, fixed text on standard input, a new empty
/// folder, and the listener above. No model and no account are used.
nonisolated struct MeetingAgentCodexToolListCapture: MeetingAgentToolListCapturing {
    var timeLimit: Duration = MeetingAgentLimits.captureTimeLimit

    func check(
        _ executable: MeetingAgentExecutable, version: String, environment: [String: String],
        runsRoot: URL, processRunner: any MeetingAgentProcessRunning
    ) async -> MeetingAgentProbeResult? {
        let run: MeetingAgentRunFolders.Run
        do {
            run = try MeetingAgentRunFolders.make(in: runsRoot)
        } catch {
            return .failed(reason: .launchFailed)
        }
        defer { try? FileManager.default.removeItem(at: run.root) }
        let timeLimit = timeLimit
        let captured: (body: Data?, value: MeetingAgentDrive.Result<CodexStreamParser>?)
        do {
            captured = try await MeetingAgentCaptureListener.capture(timeLimit: timeLimit) { port in
                // The resolved file: see `MeetingAgentRunner.runCodex`.
                let spec = MeetingAgentProcessSpec(
                    executableURL: URL(fileURLWithPath: executable.resolvedPath),
                    arguments: MeetingAgentArguments.codexCapture(
                        emptyFolder: run.emptyFolder, port: port),
                    environment: environment, currentDirectoryURL: run.emptyFolder,
                    standardInput: Data(MeetingAgentProbeTexts.captureInput.utf8))
                return try? await MeetingAgentDrive.run(
                    spec, parser: CodexStreamParser(), processRunner: processRunner,
                    timeLimit: timeLimit)
            }
        } catch {
            return .failed(reason: .toolListUnreadable)
        }
        guard let result = captured.value else { return .failed(reason: .launchFailed) }
        if result.parser.unrecognizedSetting { return .failed(reason: .settingNotKnown) }
        guard MeetingAgentRunFolders.isUntouched(run) else { return .failed(reason: .wroteFiles) }
        guard let body = captured.body else { return .failed(reason: .toolListUnreadable) }
        switch MeetingCodexToolListCheck.check(body) {
        case .passed: return nil
        case .differentTools: return .unsupportedVersion(found: version)
        case .unreadable: return .failed(reason: .toolListUnreadable)
        }
    }
}
