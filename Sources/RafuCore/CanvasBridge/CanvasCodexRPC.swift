import CryptoKit
import Darwin
import Foundation

/// A bounded control connection to the private server. It never submits a turn.
public nonisolated final class CanvasCodexRPC {
    public enum RPCError: Error, Equatable { case transport, protocolViolation, rejected, timeout }
    private let descriptor: Int32
    private let deadline: UInt64
    private var pending = Data()
    private var nextID = 0
    private static let maximumBytes = 256 * 1_024

    public init(endpoint: String, timeout: TimeInterval = 15) throws {
        try CanvasCodexSession.validateEndpoint(endpoint)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RPCError.transport }
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        do {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw RPCError.transport }
            var address = try LauncherSocketAddress.make(
                path: String(endpoint.dropFirst("unix://".count)))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw RPCError.transport }
                try awaitReady(Int16(POLLOUT))
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0
                else {
                    throw RPCError.transport
                }
            }
            var noSignal: Int32 = 1
            guard
                setsockopt(
                    descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                    socklen_t(MemoryLayout<Int32>.size)) == 0
            else {
                throw RPCError.transport
            }
            try upgrade()
            _ = try request(
                "initialize",
                params: [
                    "clientInfo": ["name": "rafu_terminal", "title": "Rafu", "version": "1.0"]
                ])
            try writeJSON(["method": "initialized"])
        } catch {
            // All stored properties are initialized. deinit owns the descriptor
            // even when the handshake fails; closing here would close it twice.
            throw error
        }
    }

    deinit { Darwin.close(descriptor) }

    /// Naming materializes the otherwise empty draft. Resume can then attach the TUI
    /// to this exact thread without a prompt or an inference request.
    public func createThread(cwd: String) throws -> String {
        let result = try request("thread/start", params: ["cwd": cwd, "ephemeral": false])
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
            UUID(uuidString: id) != nil
        else { throw RPCError.protocolViolation }
        _ = try request("thread/name/set", params: ["threadId": id, "name": "Rafu terminal"])
        return id
    }

    public func resumeThread(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw RPCError.protocolViolation }
        _ = try request("thread/resume", params: ["threadId": id, "excludeTurns": true])
    }

    private func upgrade() throws {
        let key = Data(UUID().uuidString.utf8.prefix(16)).base64EncodedString()
        let header =
            "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try writeBytes(Data(header.utf8))
        let terminator = Data("\r\n\r\n".utf8)
        while pending.range(of: terminator) == nil {
            guard pending.count < 8_192 else { throw RPCError.protocolViolation }
            try readMore()
        }
        let end = pending.range(of: terminator)!.upperBound
        let response = String(decoding: pending.prefix(end), as: UTF8.self)
        pending.removeFirst(end)
        let expected = Data(
            Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()
        let lines = response.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("HTTP/1.1 101 ") == true,
            lines.contains(where: { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "sec-websocket-accept"
                    && parts[1].trimmingCharacters(in: .whitespaces) == expected
            })
        else { throw RPCError.protocolViolation }
    }

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try writeJSON(["id": id, "method": method, "params": params])
        for _ in 0..<256 {
            let message = try readMessage()
            guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any]
            else {
                throw RPCError.protocolViolation
            }
            guard object["id"] as? Int == id else { continue }
            guard object["error"] == nil else { throw RPCError.rejected }
            guard let result = object["result"] as? [String: Any] else {
                throw RPCError.protocolViolation
            }
            return result
        }
        throw RPCError.protocolViolation
    }

    private func writeJSON(_ value: [String: Any]) throws {
        try writeFrame(opcode: 1, payload: JSONSerialization.data(withJSONObject: value))
    }

    private func writeFrame(opcode: UInt8, payload: Data) throws {
        guard payload.count <= Self.maximumBytes else { throw RPCError.protocolViolation }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65_535 {
            frame.append(contentsOf: [
                0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff),
            ])
        } else {
            frame.append(0x80 | 127)
            let size = UInt64(payload.count)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((size >> ($0 * 8)) & 0xff) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try writeBytes(frame)
    }

    private func readMessage() throws -> Data {
        var message = Data()
        var started = false
        for _ in 0..<256 {
            let header = try take(2)
            let first = header[header.startIndex]
            let second = header[header.startIndex + 1]
            guard first & 0x70 == 0, second & 0x80 == 0 else { throw RPCError.protocolViolation }
            let opcode = first & 0x0f
            var length = UInt64(second & 0x7f)
            if length == 126 {
                length = try take(2).reduce(0) { ($0 << 8) | UInt64($1) }
            } else if length == 127 {
                length = try take(8).reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard length <= Self.maximumBytes else { throw RPCError.protocolViolation }
            let payload = try take(Int(length))
            if opcode == 8 { throw RPCError.transport }
            if opcode == 9 {
                guard length <= 125, first & 0x80 != 0 else { throw RPCError.protocolViolation }
                try writeFrame(opcode: 10, payload: payload)
                continue
            }
            if opcode == 10 { continue }
            guard (opcode == 1 && !started) || (opcode == 0 && started) else {
                throw RPCError.protocolViolation
            }
            started = true
            guard message.count + payload.count <= Self.maximumBytes else {
                throw RPCError.protocolViolation
            }
            message.append(payload)
            if first & 0x80 != 0 { return message }
        }
        throw RPCError.protocolViolation
    }

    private func take(_ count: Int) throws -> Data {
        while pending.count < count { try readMore() }
        let result = Data(pending.prefix(count))
        pending.removeFirst(count)
        return result
    }

    private func readMore() throws {
        try awaitReady(Int16(POLLIN))
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard count > 0, pending.count + count <= Self.maximumBytes + 16 else {
            throw RPCError.transport
        }
        pending.append(contentsOf: buffer.prefix(count))
    }

    private func writeBytes(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            try awaitReady(Int16(POLLOUT))
            let count = data.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw RPCError.transport }
            sent += count
        }
    }

    private func awaitReady(_ event: Int16) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw RPCError.timeout }
        var descriptor = pollfd(fd: descriptor, events: event, revents: 0)
        let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
        let result = Darwin.poll(&descriptor, 1, milliseconds)
        if result < 0 && errno == EINTR {
            try awaitReady(event)
            return
        }
        guard result > 0 else { throw result == 0 ? RPCError.timeout : RPCError.transport }
        guard descriptor.revents & event != 0 else { throw RPCError.transport }
    }
}
