import Foundation
import Testing

@testable import RafuApp

private struct EchoParams: Codable, Equatable {
    let value: String
}

private struct ResultResponse<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let result: Result
}

private struct ErrorResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let error: JSONRPCErrorObject
}

/// Reads framed JSON-RPC bodies off one side of an
/// `InMemoryLanguageServerTransport` pair, one at a time, buffering any
/// extras a single chunk happened to decode into. Lets each test script a
/// "server" deterministically without a background task or a sleep.
private final class ServerFrameReader {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private var decoder = JSONRPCFrameDecoder()
    private var pendingBodies: [Data] = []

    init(stream: AsyncThrowingStream<Data, any Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func nextFrame() async throws -> Data {
        while pendingBodies.isEmpty {
            guard let chunk = try await iterator.next() else {
                throw ServerFrameReaderError.transportEnded
            }
            pendingBodies.append(contentsOf: try decoder.consume(chunk))
        }
        return pendingBodies.removeFirst()
    }
}

private enum ServerFrameReaderError: Error, Equatable {
    case transportEnded
}

private func serverSend(_ body: Data, via server: InMemoryLanguageServerTransport) async throws {
    try await server.send(JSONRPCFrameEncoder.encode(body: body))
}

@Test("Two concurrent requests are answered out of order with typed results")
func connectionHandlesOutOfOrderResponses() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    async let firstResult: String = connection.sendRequest(
        method: "echo", params: EchoParams(value: "first"))
    async let secondResult: String = connection.sendRequest(
        method: "echo", params: EchoParams(value: "second"))

    let firstRequestBody = try await reader.nextFrame()
    let firstRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: firstRequestBody)
    let secondRequestBody = try await reader.nextFrame()
    let secondRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: secondRequestBody)
    #expect(firstRequest.method == "echo")
    #expect(secondRequest.method == "echo")

    // Reply out of order: answer the second request before the first.
    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: secondRequest.id, result: "second-reply")),
        via: server
    )
    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: firstRequest.id, result: "first-reply")),
        via: server
    )

    #expect(try await firstResult == "first-reply")
    #expect(try await secondResult == "second-reply")
}

@Test("A response carrying an error throws JSONRPCErrorObject with the matching code")
func connectionThrowsServerError() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    async let result: String = connection.sendRequest(
        method: "boom", params: EchoParams(value: "x"))

    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestBody)
    let expectedError = JSONRPCErrorObject(code: -32000, message: "boom", data: nil)
    try await serverSend(
        try JSONEncoder().encode(ErrorResponse(id: request.id, error: expectedError)),
        via: server
    )

    // `#expect(throws:)`'s closure can't capture an `async let` binding
    // directly, so the request is awaited and its outcome asserted by hand.
    do {
        _ = try await result
        Issue.record("Expected sendRequest to throw the server's error")
    } catch let error as JSONRPCErrorObject {
        #expect(error == expectedError)
    } catch {
        Issue.record("Expected JSONRPCErrorObject, got \(error)")
    }
}

@Test("Server-sent notifications are delivered on the notifications stream")
func connectionDeliversServerNotifications() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    var notificationIterator = await connection.notifications.makeAsyncIterator()

    let notificationBody = try JSONEncoder().encode(
        JSONRPCNotificationEnvelope(method: "window/logMessage", params: EchoParams(value: "hi")))
    try await serverSend(notificationBody, via: server)

    let received = try #require(await notificationIterator.next())
    #expect(received.method == "window/logMessage")
    guard case .object(let fields)? = received.params, case .string(let value)? = fields["value"]
    else {
        Issue.record("Expected object params with a string value field")
        return
    }
    #expect(value == "hi")
}

@Test("Cancelling the caller task throws CancellationError and notifies the server")
func connectionPropagatesCancellation() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    let task = Task {
        try await connection.sendRequest(method: "slow", params: EchoParams(value: "x")) as String
    }

    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestBody)

    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }

    let cancelBody = try await reader.nextFrame()
    let cancelNotification = try JSONDecoder().decode(JSONRPCNotification.self, from: cancelBody)
    #expect(cancelNotification.method == "$/cancelRequest")
    guard case .object(let fields)? = cancelNotification.params else {
        Issue.record("Expected $/cancelRequest params to be an object")
        return
    }
    #expect(fields["id"] == JSONValue.number(Double(idNumber(request.id))))
}

@Test("teardown fails all pending requests with connectionClosed exactly once")
func connectionTeardownFailsPendingRequestsOnce() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    async let first: String = connection.sendRequest(method: "a", params: EchoParams(value: "1"))
    async let second: String = connection.sendRequest(method: "b", params: EchoParams(value: "2"))
    _ = try await reader.nextFrame()
    _ = try await reader.nextFrame()

    await connection.teardown()
    // Idempotent: a second call must not attempt to re-resume anything.
    await connection.teardown()

    // `#expect(throws:)`'s closure can't capture an `async let` binding
    // directly, so each request is awaited and its outcome asserted by hand.
    do {
        _ = try await first
        Issue.record("Expected the first pending request to fail on teardown")
    } catch let error as JSONRPCConnection.ConnectionError {
        #expect(error == .connectionClosed)
    } catch {
        Issue.record("Expected connectionClosed, got \(error)")
    }
    do {
        _ = try await second
        Issue.record("Expected the second pending request to fail on teardown")
    } catch let error as JSONRPCConnection.ConnectionError {
        #expect(error == .connectionClosed)
    } catch {
        Issue.record("Expected connectionClosed, got \(error)")
    }
}

@Test("A response for an unknown id is ignored and later traffic still succeeds")
func connectionIgnoresUnknownIDResponses() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: .number(999), result: "ignored")),
        via: server
    )

    async let result: String = connection.sendRequest(
        method: "ping", params: EchoParams(value: "hi"))
    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestBody)
    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: request.id, result: "pong")),
        via: server
    )

    #expect(try await result == "pong")
}

@Test("An incoming server request with no handler receives a methodNotFound reply")
func connectionRepliesMethodNotFoundToIncomingRequests() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    struct IncomingRequest: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID
        let method: String
    }
    try await serverSend(
        try JSONEncoder().encode(
            IncomingRequest(id: .number(42), method: "workspace/configuration")),
        via: server
    )

    let replyBody = try await reader.nextFrame()
    let reply = try JSONDecoder().decode(JSONRPCResponseEnvelope<JSONValue>.self, from: replyBody)
    #expect(reply.id == .number(42))
    #expect(reply.error?.code == JSONRPCErrorObject.methodNotFound)
}

@Test("window/workDoneProgress/create receives a null-result success reply, not -32601")
func connectionRepliesSuccessToWorkDoneProgressCreate() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    struct IncomingRequest: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID
        let method: String
    }

    // The allow-listed method gets a null-result success reply.
    try await serverSend(
        try JSONEncoder().encode(
            IncomingRequest(id: .number(7), method: "window/workDoneProgress/create")),
        via: server
    )
    let successReplyBody = try await reader.nextFrame()
    let successReply = try JSONDecoder().decode(
        JSONRPCResponseEnvelope<JSONValue>.self, from: successReplyBody)
    #expect(successReply.id == .number(7))
    #expect(successReply.error == nil)
    #expect(successReply.hasResult == true)
    #expect(successReply.result == .null)

    // A different method still falls back to -32601 — locks the allow-list
    // scope to exactly this one method.
    try await serverSend(
        try JSONEncoder().encode(
            IncomingRequest(id: .number(8), method: "workspace/configuration")),
        via: server
    )
    let errorReplyBody = try await reader.nextFrame()
    let errorReply = try JSONDecoder().decode(
        JSONRPCResponseEnvelope<JSONValue>.self, from: errorReplyBody)
    #expect(errorReply.id == .number(8))
    #expect(errorReply.error?.code == JSONRPCErrorObject.methodNotFound)
}

@Test("sendRequest after teardown throws connectionClosed immediately")
func connectionSendRequestAfterTeardownThrows() async throws {
    let (client, _) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    await connection.teardown()

    await #expect(throws: JSONRPCConnection.ConnectionError.connectionClosed) {
        let _: String = try await connection.sendRequest(
            method: "ping", params: EchoParams(value: "hi"))
    }
}

@Test("start() spawns only one read loop even when called twice")
func connectionStartIsIdempotent() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    await connection.start()
    await connection.start()
    let reader = ServerFrameReader(stream: await server.receive())

    async let result: String = connection.sendRequest(
        method: "ping", params: EchoParams(value: "hi"))
    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestBody)
    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: request.id, result: "pong")),
        via: server
    )

    #expect(try await result == "pong")
}

private func idNumber(_ id: JSONRPCID) -> Int {
    guard case .number(let value) = id else { return -1 }
    return value
}
