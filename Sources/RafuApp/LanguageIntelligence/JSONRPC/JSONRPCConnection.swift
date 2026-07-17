import Foundation

/// Composes `JSONRPCFrameDecoder` (pure framing) and a `LanguageServerTransport`
/// (bytes) into a JSON-RPC 2.0 client connection: request/response
/// correlation, `$/cancelRequest` propagation, server-to-client
/// notifications, and a scoped reply to server-to-client requests — a
/// null-result success for `window/workDoneProgress/create` (the one
/// request Rafu answers), and a `-32601` auto-reply for every other method
/// Rafu doesn't (yet) implement a handler for.
actor JSONRPCConnection {
    nonisolated enum ConnectionError: Error, Equatable {
        case connectionClosed
        case protocolViolation(byteCount: Int)
    }

    private let transport: any LanguageServerTransport
    private var framing: JSONRPCFrameDecoder
    private var pending: [JSONRPCID: CheckedContinuation<Data, any Error>] = [:]
    private var cancelledIDs: Set<JSONRPCID> = []
    private var nextID = 1
    private var isTornDown = false
    private var readTask: Task<Void, Never>?
    private let notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation

    /// Server-to-client notifications (e.g. `textDocument/publishDiagnostics`).
    let notifications: AsyncStream<JSONRPCNotification>

    init(
        transport: any LanguageServerTransport,
        framing: JSONRPCFrameDecoder = JSONRPCFrameDecoder()
    ) {
        self.transport = transport
        self.framing = framing
        let (stream, continuation) = AsyncStream<JSONRPCNotification>.makeStream()
        self.notifications = stream
        self.notificationContinuation = continuation
    }

    /// Spawns the single read-loop task that drains `transport.receive()`
    /// and routes decoded frames. Idempotent: a second call is a no-op.
    func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    /// Sends a request and suspends until the matching response arrives (or
    /// the request is cancelled, or the connection tears down).
    func sendRequest<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P?
    ) async throws -> R {
        guard !isTornDown else { throw ConnectionError.connectionClosed }

        let id = JSONRPCID.number(nextID)
        nextID += 1
        let framed = try encodeFrame(JSONRPCRequestEnvelope(id: id, method: method, params: params))

        let body: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                // No `await` occurs between the `isTornDown` guard above and
                // this registration, so `teardown()` cannot have drained
                // `pending` in between — either this id was pre-cancelled
                // (checked below) or it will be seen by a future drain.
                if cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                Task { await self.performWrite(framed, failing: id) }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }

        let envelope = try JSONDecoder().decode(JSONRPCResponseEnvelope<R>.self, from: body)
        if let error = envelope.error {
            throw error
        }
        guard envelope.hasResult, let result = envelope.result else {
            throw ConnectionError.protocolViolation(byteCount: body.count)
        }
        return result
    }

    /// Sends a notification; no reply is expected either way.
    func sendNotification<P: Encodable & Sendable>(method: String, params: P?) async throws {
        guard !isTornDown else { throw ConnectionError.connectionClosed }
        let framed = try encodeFrame(JSONRPCNotificationEnvelope(method: method, params: params))
        try await transport.send(framed)
    }

    /// Idempotent teardown: fails every pending request with
    /// `.connectionClosed`, finishes the notification stream, and closes
    /// the transport. Never rely on `deinit` for this — actors have no
    /// synchronous teardown hook that can await `transport.close()`.
    func teardown() async {
        guard !isTornDown else { return }
        isTornDown = true
        readTask?.cancel()
        readTask = nil

        // Drain into a local array and clear `pending` first so a
        // continuation's resumption (which may reentrantly call back into
        // this actor) can never observe — and double-fail — an entry this
        // same teardown is still in the middle of resolving.
        let drained = pending
        pending.removeAll()
        for continuation in drained.values {
            continuation.resume(throwing: ConnectionError.connectionClosed)
        }

        notificationContinuation.finish()
        await transport.close()
    }

    private func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
        JSONRPCFrameEncoder.encode(body: try JSONEncoder().encode(value))
    }

    private func performWrite(_ framed: Data, failing id: JSONRPCID) async {
        do {
            try await transport.send(framed)
        } catch {
            if let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Cancels a pending (or not-yet-registered) request: resumes it with
    /// `CancellationError` if it's still pending and best-effort notifies
    /// the server via `$/cancelRequest`; otherwise records the id so the
    /// registration race in `sendRequest` can resolve it immediately.
    private func cancelRequest(id: JSONRPCID) async {
        guard let continuation = pending.removeValue(forKey: id) else {
            cancelledIDs.insert(id)
            return
        }
        continuation.resume(throwing: CancellationError())
        try? await sendNotification(method: "$/cancelRequest", params: CancelParams(id: id))
    }

    private func runReadLoop() async {
        do {
            for try await chunk in await transport.receive() {
                for body in try framing.consume(chunk) {
                    try await route(body)
                }
            }
        } catch {
            // Any framing/transport/protocol failure ends the connection
            // the same way a clean EOF does: fall through to teardown.
        }
        await teardown()
    }

    private func route(_ body: Data) async throws {
        let message: JSONRPCIncomingMessage
        do {
            message = try JSONRPCIncomingMessage.classify(body)
        } catch {
            throw ConnectionError.protocolViolation(byteCount: body.count)
        }
        switch message {
        case .response(let id, let responseBody):
            // An unknown/stale id (already resolved, cancelled, or never
            // ours) is dropped silently — never logged, never a crash.
            pending.removeValue(forKey: id)?.resume(returning: responseBody)
        case .notification(let notification):
            notificationContinuation.yield(notification)
        case .request(let request):
            await handleIncomingRequest(request)
        }
    }

    /// Routes every incoming server-to-client request through this one
    /// method. Deliberately minimal — a server→client security surface: only
    /// `window/workDoneProgress/create` gets a real (null-result success)
    /// reply, since answering it is what lets a real server begin sending
    /// `$/progress` (which drives `LanguageServerSession.isWarmingUp`).
    /// Every other method still gets the default `-32601` reply.
    private func handleIncomingRequest(_ request: JSONRPCRequest) async {
        guard request.method == "window/workDoneProgress/create" else {
            let envelope = JSONRPCErrorResponseEnvelope(
                id: request.id,
                error: JSONRPCErrorObject(
                    code: JSONRPCErrorObject.methodNotFound,
                    message: "No handler registered for \(request.method)",
                    data: nil
                )
            )
            guard let framed = try? encodeFrame(envelope) else { return }
            try? await transport.send(framed)
            return
        }
        guard let framed = try? encodeFrame(JSONRPCSuccessResponseEnvelope(id: request.id)) else {
            return
        }
        try? await transport.send(framed)
    }
}

/// `$/cancelRequest` params: `{"id": <the cancelled request's id>}`.
private nonisolated struct CancelParams: Encodable {
    let id: JSONRPCID
}
