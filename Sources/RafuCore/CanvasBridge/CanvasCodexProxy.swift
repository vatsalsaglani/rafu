import Darwin
import Foundation
import Synchronization

/// One TUI-only transport. Navigation revokes the Canvas route before it reaches
/// Codex. Two bounded stream workers retain no transcript or tool output.
final class CanvasCodexProxy: Sendable {
    enum ProxyError: Error { case transport, malformedFrame, timedOut, pendingOverflow }
    enum SuspensionReason: String, Sendable { case sessionChanged, transportLost }
    /// Why the link ended while the terminal was still running. Raw values are
    /// fixed phrases for the supervisor's one stderr line; they carry no data.
    enum LinkLoss: String, Sendable {
        case sessionChange = "the conversation changed"
        case appServerClosed = "the Codex server closed the connection"
        case frame = "a malformed frame"
        case timeout = "a frame did not finish in time"
        case pendingOverflow = "too many unanswered requests"
        case bridgeUnavailable = "Rafu did not confirm a session change"
    }
    private struct State {
        var stopped = false
        var revoked = false
        var lostLink: LinkLoss?
        var listener: (any DispatchSourceRead)?
        var streams: [Int32] = []
        var workers = 0
        var pendingIDs: Set<String> = []
    }
    private let state = Mutex(State())
    private let backend: String
    private let threadID: String
    private let suspend: @Sendable (SuspensionReason) throws -> Void
    private static let maximumBytes = 256 * 1_024

    init(
        frontend: String, backend: String, threadID: String,
        suspend: @escaping @Sendable (SuspensionReason) throws -> Void
    ) throws {
        self.backend = backend
        self.threadID = threadID
        self.suspend = suspend
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ProxyError.transport }
        do {
            var address = try LauncherSocketAddress.make(path: frontend)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, Darwin.listen(listener, 1) == 0,
                fcntl(listener, F_SETFL, O_NONBLOCK) == 0,
                fcntl(listener, F_SETFD, FD_CLOEXEC) == 0
            else { throw ProxyError.transport }
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .global())
            source.setEventHandler { [self] in accept(listener) }
            source.setCancelHandler { Darwin.close(listener) }
            state.withLock { $0.listener = source }
            source.resume()
        } catch {
            Darwin.close(listener)
            throw error
        }
    }

    /// The first noteworthy loss, or nil after a normal terminal exit. The TUI
    /// closing its own socket is not a loss, and neither is anything that follows
    /// `stop()`.
    var lostLink: LinkLoss? { state.withLock { $0.lostLink } }

    private func noteLoss(_ loss: LinkLoss) {
        state.withLock { state in
            if state.lostLink == nil, !state.stopped { state.lostLink = loss }
        }
    }

    func stop() {
        state.withLock { state in
            state.stopped = true
            state.listener?.cancel()
            state.listener = nil
            for descriptor in state.streams { Darwin.shutdown(descriptor, SHUT_RDWR) }
        }
    }

    private func accept(_ listener: Int32) {
        let frontend = Darwin.accept(listener, nil, nil)
        guard frontend >= 0 else { return }
        let upstream = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard upstream >= 0 else {
            Darwin.close(frontend)
            stop()
            return
        }
        do {
            try configure(frontend)
            try configure(upstream)
            var address = try LauncherSocketAddress.make(
                path: String(backend.dropFirst("unix://".count)))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw ProxyError.transport }
                try Self.ready(upstream, event: Int16(POLLOUT), deadline: Self.deadline())
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(upstream, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0
                else {
                    throw ProxyError.transport
                }
            }
            let accepted = state.withLock { state in
                guard !state.stopped, state.streams.isEmpty else { return false }
                state.listener?.cancel()
                state.listener = nil
                state.streams = [frontend, upstream]
                state.workers = 2
                return true
            }
            guard accepted else {
                Darwin.close(frontend)
                Darwin.close(upstream)
                return
            }
            DispatchQueue.global().async { [self] in
                relay(from: frontend, to: upstream, outgoing: true)
            }
            DispatchQueue.global().async { [self] in
                relay(from: upstream, to: frontend, outgoing: false)
            }
        } catch {
            Darwin.close(frontend)
            Darwin.close(upstream)
            stop()
        }
    }

    private func configure(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else { throw ProxyError.transport }
    }

    private func relay(from source: Int32, to destination: Int32, outgoing: Bool) {
        defer {
            stop()
            let descriptors = state.withLock { state -> [Int32] in
                state.workers -= 1
                guard state.workers == 0 else { return [] }
                defer { state.streams = [] }
                return state.streams
            }
            for descriptor in descriptors { Darwin.close(descriptor) }
        }
        do {
            var header = Data()
            let handshakeDeadline = Self.deadline()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard header.count < 8_192 else { throw ProxyError.malformedFrame }
                header.append(try Self.read(source, count: 1, deadline: handshakeDeadline))
            }
            try Self.write(header, to: destination)
            var message = Data()
            var fragmented = false
            var messageDeadline: UInt64?
            while true {
                // An idle terminal has no timeout. Once a frame starts, its entire
                // payload must arrive within ten seconds, including fragmented text.
                var frame = try Self.read(source, count: 1, deadline: messageDeadline)
                let frameDeadline = messageDeadline ?? Self.deadline()
                frame.append(try Self.read(source, count: 1, deadline: frameDeadline))
                let first = frame[0]
                let second = frame[1]
                let opcode = first & 15
                guard first & 0x70 == 0, (second & 0x80 != 0) == outgoing else {
                    throw ProxyError.malformedFrame
                }
                var length = UInt64(second & 127)
                if length == 126 || length == 127 {
                    let bytes = try Self.read(
                        source, count: length == 126 ? 2 : 8, deadline: frameDeadline)
                    frame.append(bytes)
                    length = bytes.reduce(0) { ($0 << 8) | UInt64($1) }
                }
                if !outgoing, opcode == 1, first & 0x80 != 0, !fragmented,
                    length > Self.maximumBytes
                {
                    try streamResponse(
                        from: source, to: destination, header: frame,
                        length: length, deadline: frameDeadline)
                    continue
                }
                guard length <= Self.maximumBytes else { throw ProxyError.malformedFrame }
                let mask =
                    outgoing ? try Self.read(source, count: 4, deadline: frameDeadline) : Data()
                frame.append(mask)
                let raw = try Self.read(source, count: Int(length), deadline: frameDeadline)
                frame.append(raw)
                if opcode == 1 || opcode == 0 {
                    guard (opcode == 1 && !fragmented) || (opcode == 0 && fragmented),
                        message.count + raw.count <= Self.maximumBytes
                    else { throw ProxyError.malformedFrame }
                    let decoded =
                        outgoing
                        ? Data(raw.enumerated().map { $0.element ^ mask[$0.offset % 4] }) : raw
                    message.append(decoded)
                    fragmented = first & 0x80 == 0
                    messageDeadline = fragmented ? frameDeadline : nil
                    if !fragmented {
                        guard
                            let object = try JSONSerialization.jsonObject(with: message)
                                as? [String: Any]
                        else {
                            throw ProxyError.malformedFrame
                        }
                        if let identifier = Self.requestID(object["id"]) {
                            try state.withLock { state in
                                if outgoing, object["method"] != nil {
                                    guard !state.pendingIDs.contains(identifier) else {
                                        throw ProxyError.malformedFrame
                                    }
                                    // A full table is a limit reached, not a bad frame.
                                    guard state.pendingIDs.count < 256 else {
                                        throw ProxyError.pendingOverflow
                                    }
                                    state.pendingIDs.insert(identifier)
                                } else if !outgoing, object["method"] == nil {
                                    state.pendingIDs.remove(identifier)
                                }
                            }
                        }
                        if Self.requiresSuspension(object, threadID: threadID, outgoing: outgoing) {
                            try revoke(.sessionChanged)
                        }
                        message.removeAll(keepingCapacity: false)
                    }
                } else {
                    guard opcode == 8 || opcode == 9 || opcode == 10, length <= 125,
                        first & 0x80 != 0
                    else {
                        throw ProxyError.malformedFrame
                    }
                }
                try Self.write(frame, to: destination)
                if opcode == 8 { return }
            }
        } catch {
            classify(error, outgoing: outgoing)
            // Any transport ambiguity must revoke the route. If IPC is already
            // unavailable, closing both sockets also prevents further TUI turns.
            try? revoke(.transportLost)
        }
    }

    /// Records why a worker ended, so the supervisor can tell the user once the
    /// terminal exits. The TUI closing its own socket is the normal way out.
    private func classify(_ error: any Error, outgoing: Bool) {
        switch error {
        case ProxyError.timedOut: noteLoss(.timeout)
        case ProxyError.pendingOverflow: noteLoss(.pendingOverflow)
        case ProxyError.malformedFrame: noteLoss(.frame)
        case ProxyError.transport: if !outgoing { noteLoss(.appServerClosed) }
        default:
            // A JSON parse error is a frame problem. Anything else came from the
            // revocation call itself.
            noteLoss((error as NSError).domain == NSCocoaErrorDomain ? .frame : .bridgeUnavailable)
        }
    }

    static func requiresSuspension(_ object: [String: Any], threadID: String, outgoing: Bool)
        -> Bool
    {
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        if outgoing {
            // The TUI reads other threads' metadata during normal startup to
            // populate history. This query does not select a conversation.
            // A full-history read still revokes because it can open a cached view.
            let metadataReadMethods: Set<String> = ["thread/read"]
            if metadataReadMethods.contains(method),
                params["includeTurns"] == nil || params["includeTurns"] as? Bool == false
            {
                return false
            }
            // Startup also reads one summary turn from each history entry. The
            // TUI serializes an omitted itemsView as JSON null; both select the
            // protocol's summary default, not a different visible conversation.
            if method == "thread/turns/list" {
                let view = params["itemsView"]
                if view == nil || view is NSNull
                    || ["notLoaded", "summary"].contains(view as? String ?? "")
                {
                    return false
                }
            }
            if method == "thread/start" || method == "thread/fork" || method == "thread/unsubscribe"
            {
                return true
            }
            if let target = params["threadId"] as? String, target != threadID { return true }
        } else {
            // A second runtime can later be selected from a cached view without a
            // fresh resume request. Revoke conservatively when it becomes known.
            if let target = params["threadId"] as? String, target != threadID { return true }
            if let thread = params["thread"] as? [String: Any],
                let target = thread["id"] as? String, target != threadID
            {
                return true
            }
        }
        return false
    }

    private func revoke(_ reason: SuspensionReason) throws {
        try state.withLock { state in
            guard !state.revoked else { return }
            // Serialize both directions until the broker confirms revocation.
            // The final navigation frame cannot reach Codex before this returns.
            try suspend(reason)
            state.revoked = true
        }
        if reason == .sessionChanged { noteLoss(.sessionChange) }
    }

    /// Large result/error envelopes cannot change the selected thread. Match the
    /// response ID before forwarding, and retain at most a small prefix and chunk.
    private func streamResponse(
        from source: Int32, to destination: Int32, header: Data,
        length: UInt64, deadline: UInt64
    ) throws {
        guard length <= 64 * 1_024 * 1_024 else { throw ProxyError.malformedFrame }
        var prefix = Data()
        var identifier: String?
        while prefix.count < min(Int(length), 4_096) {
            prefix.append(try Self.read(source, count: 1, deadline: deadline))
            if prefix.last == 58, let candidate = Self.responseID(prefix) {
                identifier = candidate
                break
            }
        }
        guard let identifier,
            state.withLock({ $0.pendingIDs.remove(identifier) != nil })
        else { throw ProxyError.malformedFrame }
        try Self.write(header, to: destination)
        try Self.write(prefix, to: destination)
        var remaining = Int(length) - prefix.count
        while remaining > 0 {
            let chunk = try Self.read(source, count: min(remaining, 8_192), deadline: deadline)
            try Self.write(chunk, to: destination)
            remaining -= chunk.count
        }
    }

    static func responseID(_ prefix: Data) -> String? {
        guard prefix.count <= 4_096, let text = String(data: prefix, encoding: .utf8) else {
            return nil
        }
        // Accept only the canonical JSON-RPC response envelope. Notifications and
        // requests use method/params and must still pass the full identity check.
        let pattern =
            #"^\s*\{\s*"id"\s*:\s*("(?:[^"\\]|\\.)*"|-?[0-9]+)\s*,\s*"(?:result|error)"\s*:\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text),
            let data = String(text[range]).data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return requestID(value)
    }

    private static func requestID(_ value: Any?) -> String? {
        guard let value, value is String || value is NSNumber,
            let encoded = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]),
            encoded.count <= 256
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func deadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    }

    private static func ready(_ descriptor: Int32, event: Int16, deadline: UInt64?) throws {
        while true {
            let timeout: Int32
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw ProxyError.timedOut }
                timeout = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
            } else {
                timeout = -1
            }
            var pollDescriptor = pollfd(fd: descriptor, events: event, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, timeout)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, pollDescriptor.revents & event != 0 else {
                throw ProxyError.transport
            }
            return
        }
    }

    private static func read(_ descriptor: Int32, count: Int, deadline: UInt64?) throws -> Data {
        var data = Data()
        while data.count < count {
            try ready(descriptor, event: Int16(POLLIN), deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: min(count - data.count, 8_192))
            let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard received > 0 else { throw ProxyError.transport }
            data.append(contentsOf: buffer.prefix(received))
        }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        let deadline = deadline()
        while offset < data.count {
            try ready(descriptor, event: Int16(POLLOUT), deadline: deadline)
            let sent = data.withUnsafeBytes { bytes in
                Darwin.send(
                    descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard sent > 0 else { throw ProxyError.transport }
            offset += sent
        }
    }
}
