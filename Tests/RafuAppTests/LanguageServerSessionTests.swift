import Foundation
import Testing

@testable import RafuApp

// MARK: - Local scripted-server test helpers
//
// Mirrors `JSONRPCConnectionTests.swift`'s locally-declared `ServerFrameReader`
// and `serverSend` — each test file keeps its own private copy rather than
// sharing one across files.

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

private struct ResultResponse<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let result: Result
}

private struct DecodedRequest<Params: Decodable>: Decodable {
    let id: JSONRPCID
    let method: String
    let params: Params
}

private struct DecodedNotification<Params: Decodable>: Decodable {
    let method: String
    let params: Params
}

private struct DecodedContentChange: Decodable, Equatable {
    let range: LSPRange?
    let text: String
}

private struct DecodedDidChangeParams: Decodable {
    let textDocument: VersionedTextDocumentIdentifier
    let contentChanges: [DecodedContentChange]
}

private func jsonIDFragment(_ id: JSONRPCID) -> String {
    switch id {
    case .number(let value): return String(value)
    case .string(let value): return "\"\(value)\""
    }
}

private func initializeResponseBody(id: JSONRPCID, capabilitiesJSON: String) -> Data {
    Data(
        #"{"jsonrpc":"2.0","id":\#(jsonIDFragment(id)),"result":{"capabilities":\#(capabilitiesJSON)}}"#
            .utf8)
}

private func nullResultResponseBody(id: JSONRPCID) -> Data {
    Data(#"{"jsonrpc":"2.0","id":\#(jsonIDFragment(id)),"result":null}"#.utf8)
}

/// Polls `predicate` on cooperative `Task.yield()`s (never a fixed sleep)
/// until it's `true` or `maxIterations` is exhausted — the only reliable way
/// to observe a background actor task (`monitorNotifications()`) having
/// processed an `AsyncStream` element it consumes independently of the
/// test's own task.
private func waitUntil(maxIterations: Int = 20_000, _ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<maxIterations {
        if await predicate() { return true }
        await Task.yield()
    }
    return false
}

private let fullCapabilitiesJSON = """
    {"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},\
    "definitionProvider":true,"declarationProvider":true,"referencesProvider":true,\
    "hoverProvider":true,"documentSymbolProvider":true}
    """

/// Drives the `initialize`/`initialized` handshake to completion against a
/// scripted server reachable through `reader`/`server`.
private func performHandshake(
    session: LanguageServerSession,
    server: InMemoryLanguageServerTransport,
    reader: ServerFrameReader,
    capabilitiesJSON: String
) async throws {
    async let initializeCall: Void = session.initialize()

    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestBody)
    #expect(request.method == "initialize")
    try await serverSend(
        initializeResponseBody(id: request.id, capabilitiesJSON: capabilitiesJSON), via: server)

    let initializedBody = try await reader.nextFrame()
    let initializedNotification = try JSONDecoder().decode(
        JSONRPCNotification.self, from: initializedBody)
    #expect(initializedNotification.method == "initialized")

    try await initializeCall
}

// MARK: - Handshake

@Test("initialize() reaches .ready after the initialize/initialized handshake")
func initializeHandshakeReachesReady() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())

    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    #expect(await session.state == .ready)
    #expect(await session.negotiatedEncoding == .utf16)
    #expect(await session.capabilities?.definitionProvider?.isEnabled == true)
}

@Test("A handshake the server never replies to times out, tearing down to .dead")
func handshakeTimeoutTearsDownAndThrows() async throws {
    let (client, _) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil, requestTimeout: .seconds(2), handshakeTimeout: .milliseconds(50)
    )

    // The server side is never read from and never replies — the in-memory
    // transport's send buffer is unbounded, so there's no need to drain it
    // first, and doing so *before* starting `initialize()` would just block
    // forever waiting for a frame nothing has written yet.
    await #expect(throws: LanguageServerSession.SessionError.handshakeTimedOut) {
        try await session.initialize()
    }
    #expect(await session.state == .dead)
}

// MARK: - Capability gating

@Test("A server without referencesProvider declines references but answers definition")
func capabilityGatingDeclinesUnavailableFeature() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())

    let capabilitiesJSON = """
        {"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},\
        "definitionProvider":true}
        """
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: capabilitiesJSON)

    let uri = "file:///a.swift"
    await session.didOpen(uri: uri, languageID: "swift", text: "let x = 1")
    _ = try await reader.nextFrame()  // didOpen notification

    // Declined before any request reaches the wire.
    let referencesResult = await session.references(
        uri: uri, utf16Offset: 4, includeDeclaration: true)
    #expect(referencesResult == nil)

    let expectedLocation = Location(
        uri: "file:///b.swift",
        range: LSPRange(
            start: Position(line: 3, character: 0), end: Position(line: 3, character: 3)))
    async let definitionCall = session.definition(uri: uri, utf16Offset: 4)

    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(
        DecodedRequest<TextDocumentPositionParams>.self, from: requestBody)
    #expect(request.method == "textDocument/definition")
    #expect(request.params.position == Position(line: 0, character: 4))

    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: request.id, result: expectedLocation)),
        via: server)

    #expect(await definitionCall == [expectedLocation])
}

// MARK: - Document synchronization

@Test("didOpen then an incremental didChange sends a correctly ranged wire delta")
func didOpenAndIncrementalDidChangeWireShape() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    let uri = "file:///a.swift"
    let originalText = "let x = 1\nlet y = 2"
    await session.didOpen(uri: uri, languageID: "swift", text: originalText)

    let openBody = try await reader.nextFrame()
    let openNotification = try JSONDecoder().decode(
        DecodedNotification<DidOpenTextDocumentParams>.self, from: openBody)
    #expect(openNotification.method == "textDocument/didOpen")
    #expect(openNotification.params.textDocument.version == 1)
    #expect(openNotification.params.textDocument.text == originalText)

    // Replace the single-character "x" (UTF-16 offset 4, length 1) with "z".
    let newText = "let z = 1\nlet y = 2"
    let delta = DocumentEditDelta(
        range: NSRange(location: 4, length: 1), replacementLength: 1, version: 1)
    await session.didChange(uri: uri, delta: delta, newFullText: newText)

    let changeBody = try await reader.nextFrame()
    let changeNotification = try JSONDecoder().decode(
        DecodedNotification<DecodedDidChangeParams>.self, from: changeBody)
    #expect(changeNotification.method == "textDocument/didChange")
    #expect(changeNotification.params.textDocument.version == 2)
    #expect(changeNotification.params.contentChanges.count == 1)
    #expect(
        changeNotification.params.contentChanges[0]
            == DecodedContentChange(
                range: LSPRange(
                    start: Position(line: 0, character: 4), end: Position(line: 0, character: 5)),
                text: "z"))
}

@Test("A server declaring textDocumentSync .none gets full-text didChange payloads")
func fullSyncFallbackSendsWholeText() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())

    let capabilitiesJSON = """
        {"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":0},\
        "definitionProvider":true}
        """
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: capabilitiesJSON)

    let uri = "file:///a.swift"
    let originalText = "abc"
    await session.didOpen(uri: uri, languageID: "swift", text: originalText)
    _ = try await reader.nextFrame()  // didOpen notification

    let newText = "abcd"
    let delta = DocumentEditDelta(
        range: NSRange(location: 3, length: 0), replacementLength: 1, version: 1)
    await session.didChange(uri: uri, delta: delta, newFullText: newText)

    let changeBody = try await reader.nextFrame()
    let changeNotification = try JSONDecoder().decode(
        DecodedNotification<DecodedDidChangeParams>.self, from: changeBody)
    #expect(changeNotification.params.textDocument.version == 2)
    #expect(
        changeNotification.params.contentChanges == [
            DecodedContentChange(range: nil, text: newText)
        ]
    )
}

@Test("resync always sends a full-text didChange regardless of the negotiated sync kind")
func resyncAlwaysSendsFullText() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    let uri = "file:///a.swift"
    await session.didOpen(uri: uri, languageID: "swift", text: "old text")
    _ = try await reader.nextFrame()  // didOpen notification

    await session.resync(uri: uri, fullText: "reloaded from disk")

    let changeBody = try await reader.nextFrame()
    let changeNotification = try JSONDecoder().decode(
        DecodedNotification<DecodedDidChangeParams>.self, from: changeBody)
    #expect(changeNotification.params.textDocument.version == 2)
    #expect(
        changeNotification.params.contentChanges
            == [DecodedContentChange(range: nil, text: "reloaded from disk")])
}

// MARK: - Navigation

@Test("definition's wire position matches the mirror's UTF-16-offset conversion")
func definitionRoundTripMatchesConvertedPosition() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    let uri = "file:///a.swift"
    let text = "abc\ndef"
    await session.didOpen(uri: uri, languageID: "swift", text: text)
    _ = try await reader.nextFrame()  // didOpen notification

    let expectedPosition = DocumentTextMirror(text: text).position(
        forUTF16Offset: 5, encoding: .utf16)
    #expect(expectedPosition == Position(line: 1, character: 1))

    let expectedLocation = Location(
        uri: uri,
        range: LSPRange(
            start: Position(line: 1, character: 0), end: Position(line: 1, character: 3)))
    async let definitionCall = session.definition(uri: uri, utf16Offset: 5)

    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(
        DecodedRequest<TextDocumentPositionParams>.self, from: requestBody)
    #expect(request.params.position == expectedPosition)

    try await serverSend(
        try JSONEncoder().encode(ResultResponse(id: request.id, result: expectedLocation)),
        via: server)

    #expect(await definitionCall == [expectedLocation])
}

@Test("A request the server never answers declines (nil) after requestTimeout")
func perRequestTimeoutDeclines() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil, requestTimeout: .milliseconds(30)
    )
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    let uri = "file:///a.swift"
    await session.didOpen(uri: uri, languageID: "swift", text: "abc")
    _ = try await reader.nextFrame()  // didOpen notification

    async let definitionCall = session.definition(uri: uri, utf16Offset: 0)
    // Confirm the request really reached the wire, then never answer it.
    _ = try await reader.nextFrame()

    #expect(await definitionCall == nil)
}

// MARK: - `$/progress`

@Test("A $/progress notification flips isWarmingUp, begin to end")
func progressNotificationFlipsWarmingUp() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    #expect(await session.isWarmingUp == false)

    try await serverSend(
        Data(
            #"{"jsonrpc":"2.0","method":"$/progress","params":{"token":1,"value":{"kind":"begin","title":"Indexing"}}}"#
                .utf8), via: server)
    let becameWarm = await waitUntil { await session.isWarmingUp }
    #expect(becameWarm)

    try await serverSend(
        Data(
            #"{"jsonrpc":"2.0","method":"$/progress","params":{"token":1,"value":{"kind":"end"}}}"#
                .utf8), via: server)
    let becameCool = await waitUntil { await !session.isWarmingUp }
    #expect(becameCool)
}

// MARK: - Shutdown and server death

@Test("shutdown() sends shutdown then exit and reaches .dead")
func gracefulShutdownSendsShutdownAndExit() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    async let shutdownCall: Void = session.shutdown()

    let shutdownRequestBody = try await reader.nextFrame()
    let shutdownRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: shutdownRequestBody)
    #expect(shutdownRequest.method == "shutdown")
    try await serverSend(nullResultResponseBody(id: shutdownRequest.id), via: server)

    let exitBody = try await reader.nextFrame()
    let exitNotification = try JSONDecoder().decode(JSONRPCNotification.self, from: exitBody)
    #expect(exitNotification.method == "exit")

    await shutdownCall
    #expect(await session.state == .dead)
}

@Test("The server closing its transport declines subsequent navigation and reaches .dead")
func serverDeathCausesDeclineAndDeadState() async throws {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: "file:///workspace",
        initializationOptions: nil)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: fullCapabilitiesJSON)

    let uri = "file:///a.swift"
    await session.didOpen(uri: uri, languageID: "swift", text: "abc")
    _ = try await reader.nextFrame()  // didOpen notification

    await server.close()

    let becameDead = await waitUntil { await session.state == .dead }
    #expect(becameDead)
    #expect(await session.definition(uri: uri, utf16Offset: 0) == nil)
}
