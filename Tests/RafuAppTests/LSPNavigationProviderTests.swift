import Foundation
import Testing

@testable import RafuApp

// MARK: - Local scripted-server test helpers
//
// Own private copies of the scripted-server scaffolding, per this repo's
// per-file convention (see `LanguageServerSessionTests.swift` /
// `JSONRPCConnectionTests.swift`).

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

private func performHandshake(
    session: LanguageServerSession, server: InMemoryLanguageServerTransport,
    reader: ServerFrameReader, capabilitiesJSON: String
) async throws {
    async let initializeCall: Void = session.initialize()
    let requestBody = try await reader.nextFrame()
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: requestBody)
    #expect(request.method == "initialize")
    try await serverSend(
        initializeResponseBody(id: request.id, capabilitiesJSON: capabilitiesJSON), via: server)
    let initializedBody = try await reader.nextFrame()
    let initialized = try JSONDecoder().decode(JSONRPCNotification.self, from: initializedBody)
    #expect(initialized.method == "initialized")
    try await initializeCall
}

/// A handshake-completed session plus the scripted-server handles a test drives
/// replies through.
private struct ScriptedSession {
    let session: LanguageServerSession
    let server: InMemoryLanguageServerTransport
    let reader: ServerFrameReader
}

private func makeReadySession(
    rootURI: String, capabilitiesJSON: String = fullCapabilitiesJSON,
    requestTimeout: Duration = .seconds(2)
) async throws -> ScriptedSession {
    let (client, server) = InMemoryLanguageServerTransport.makePair()
    let connection = JSONRPCConnection(transport: client)
    let session = LanguageServerSession(
        connection: connection, serverName: "fake-server", rootURI: rootURI,
        initializationOptions: nil, requestTimeout: requestTimeout)
    let reader = ServerFrameReader(stream: await server.receive())
    try await performHandshake(
        session: session, server: server, reader: reader, capabilitiesJSON: capabilitiesJSON)
    return ScriptedSession(session: session, server: server, reader: reader)
}

/// Opens `text` as `url` on the session and drains the `didOpen` notification.
private func openDocument(
    _ url: URL, text: String, on scripted: ScriptedSession
) async throws {
    await scripted.session.didOpen(
        uri: fileURI(forPath: url.path), languageID: "swift", text: text)
    _ = try await scripted.reader.nextFrame()  // didOpen notification
}

private func write(_ text: String, to url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func expectedUTF16Range(_ range: LSPRange, in text: String) -> NSRange {
    let mirror = DocumentTextMirror(text: text)
    let start = mirror.utf16Offset(for: range.start, encoding: .utf16)!
    let end = mirror.utf16Offset(for: range.end, encoding: .utf16)!
    return NSRange(location: start, length: end - start)
}

// MARK: - Definition

@Test("definition resolves a same-file target to a mapped SymbolCandidate")
func definition_sameFile_roundTrip() async throws {
    try await withTemporaryDirectory { root in
        let aText = "let x = 1\nfoo()\n"
        let aURL = root.appending(path: "a.swift")
        try write(aText, to: aURL)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(aURL, text: aText, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: aURL, position: 4, languageID: "swift", kind: .definition)

        async let answerCall = provider.answer(request)

        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        #expect(decoded.method == "textDocument/definition")
        #expect(decoded.params.position == Position(line: 0, character: 4))

        let targetRange = LSPRange(
            start: Position(line: 1, character: 0), end: Position(line: 1, character: 3))
        let location = Location(uri: fileURI(forPath: aURL.path), range: targetRange)
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: location)),
            via: scripted.server)

        let answer = try #require(await answerCall)
        #expect(answer.tier == .lsp(serverName: "fake-server"))
        #expect(answer.state == .ready)
        #expect(answer.candidates.count == 1)
        let candidate = try #require(answer.candidates.first)
        #expect(candidate.relativePath == "a.swift")
        #expect(candidate.range == expectedUTF16Range(targetRange, in: aText))
        #expect(candidate.previewLine == "foo()")
    }
}

@Test("definition converts a cross-file target's range against the TARGET file")
func definition_crossFile_targetRangeConversion() async throws {
    try await withTemporaryDirectory { root in
        let aText = "call()\n"
        let aURL = root.appending(path: "a.swift")
        try write(aText, to: aURL)
        // Different text/line lengths than `a`, so a mis-conversion against
        // `a` would produce a different offset than against `b`.
        let bText = "struct Widget {}\nfunc build() -> Widget { Widget() }\n"
        let bURL = root.appending(path: "b.swift")
        try write(bText, to: bURL)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(aURL, text: aText, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: aURL, position: 0, languageID: "swift", kind: .definition)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())

        let targetRange = LSPRange(
            start: Position(line: 1, character: 5), end: Position(line: 1, character: 10))
        let location = Location(uri: fileURI(forPath: bURL.path), range: targetRange)
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: location)),
            via: scripted.server)

        let answer = try #require(await answerCall)
        let candidate = try #require(answer.candidates.first)
        #expect(candidate.relativePath == "b.swift")
        #expect(candidate.range == expectedUTF16Range(targetRange, in: bText))
        #expect(candidate.previewLine == "func build() -> Widget { Widget() }")
    }
}

// MARK: - References

@Test("references maps every returned Location, in order")
func references_multipleLocations() async throws {
    try await withTemporaryDirectory { root in
        let text = "alpha\nbeta\ngamma\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .references)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        #expect(decoded.method == "textDocument/references")

        let uri = fileURI(forPath: url.path)
        let locations = (0..<3).map { line in
            Location(
                uri: uri,
                range: LSPRange(
                    start: Position(line: line, character: 0),
                    end: Position(line: line, character: 1)))
        }
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: locations)),
            via: scripted.server)

        let answer = try #require(await answerCall)
        #expect(answer.candidates.count == 3)
        #expect(answer.candidates.map(\.previewLine) == ["alpha", "beta", "gamma"])
        #expect(answer.candidates.allSatisfy { $0.kindLabel == "reference" })
    }
}

// MARK: - Warm-up

@Test("a warming-up server returns .indexing without issuing a request")
func warmUp_returnsIndexing() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        // Scripted $/progress begin flips `isWarmingUp` regardless of any
        // advertised capability.
        let progress = Data(
            #"{"jsonrpc":"2.0","method":"$/progress","params":{"token":"t","value":{"kind":"begin","title":"indexing"}}}"#
                .utf8)
        try await serverSend(progress, via: scripted.server)
        #expect(await waitUntil { await session.isWarmingUp })

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .definition)
        let answer = try #require(await provider.answer(request))
        #expect(answer.state == .indexing)
        #expect(answer.candidates.isEmpty)
        #expect(answer.tier == .lsp(serverName: "fake-server"))
    }
}

// MARK: - Empty vs declined

// NOTE: an authoritative empty is signalled by an empty array `[]`, not by
// `null`. A JSON `null` result currently declines (falls through) because the
// C0 response envelope decodes the result with a non-optional
// `decode(forKey:)`, which Foundation rejects for `null` before
// `LocationsResult.decodeNil()` can map it to `.none`. That is arguably the
// desirable behaviour (an LSP "no definition" falling through to the syntactic
// tier), but it should be confirmed/aligned at integration — see the plan's
// C5 status.
@Test("an authoritative empty ([]) result answers .ready with no candidates")
func emptyResult_authoritativeReady() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .definition)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: [Location]())),
            via: scripted.server)

        let answer = try #require(await answerCall)
        #expect(answer.state == .ready)
        #expect(answer.candidates.isEmpty)
    }
}

// An empty references array is NOT authoritative: sourcekit-lsp without a
// built index answers `textDocument/references` with `[]`, which must fall
// through (nil) to the bounded text tier rather than winning the ladder as a
// misleading "No references". Definition/declaration keep authoritative-empty
// (see `emptyResult_authoritativeReady`).
@Test("empty references ([]) declines (nil), falling through to a lower tier")
func emptyReferences_declines() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .references)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        #expect(decoded.method == "textDocument/references")
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: [Location]())),
            via: scripted.server)

        #expect(try await answerCall == nil)
    }
}

// A references answer whose every target is unreadable collapses to empty and
// must also decline (post-build check), rather than presenting an empty peek.
@Test("references with only unreadable targets declines (nil)")
func referencesAllUnreadable_declines() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .references)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        let missing = fileURI(forPath: root.appending(path: "does-not-exist.swift").path)
        let location = Location(
            uri: missing,
            range: LSPRange(
                start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)))
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: [location])),
            via: scripted.server)

        #expect(try await answerCall == nil)
    }
}

// MARK: - Decline paths

@Test("a server without referencesProvider declines (nil), falling through")
func capabilityDeclined_declines() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let capabilitiesJSON = """
            {"positionEncoding":"utf-16","textDocumentSync":{"openClose":true,"change":2},\
            "definitionProvider":true}
            """
        let scripted = try await makeReadySession(
            rootURI: fileURI(forPath: root.path), capabilitiesJSON: capabilitiesJSON)
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .references)
        #expect(try await provider.answer(request) == nil)
    }
}

@Test("a dead server declines and never throws to the UI")
func killServer_declinesNeverThrows() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        await scripted.server.close()
        #expect(await waitUntil { await session.state == .dead })

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .definition)
        #expect(try await provider.answer(request) == nil)
    }
}

@Test("a request the server never answers declines via the per-request timeout")
func perRequestTimeout_declines() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(
            rootURI: fileURI(forPath: root.path), requestTimeout: .milliseconds(100))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root, answerTimeout: .seconds(5)) { _ in
            session
        }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .definition)
        // Server never replies; the session's own timeout collapses to a
        // decline, which the provider surfaces as nil.
        #expect(try await provider.answer(request) == nil)
    }
}

@Test("an unreadable target file is skipped, leaving an authoritative empty answer")
func unreadableTarget_skipsCandidate() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 0, languageID: "swift", kind: .definition)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        let missing = fileURI(forPath: root.appending(path: "does-not-exist.swift").path)
        let location = Location(
            uri: missing,
            range: LSPRange(
                start: Position(line: 0, character: 0), end: Position(line: 0, character: 1)))
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: location)),
            via: scripted.server)

        let answer = try #require(await answerCall)
        #expect(answer.state == .ready)
        #expect(answer.candidates.isEmpty)
    }
}

// MARK: - Hover

@Test("hover produces a single preview candidate at the request position")
func hover_producesPreviewCandidate() async throws {
    try await withTemporaryDirectory { root in
        let text = "let x = 1\n"
        let url = root.appending(path: "a.swift")
        try write(text, to: url)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(url, text: text, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: url, position: 4, languageID: "swift", kind: .hover)

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        #expect(decoded.method == "textDocument/hover")
        try await serverSend(
            Data(
                #"{"jsonrpc":"2.0","id":\#(jsonIDFragment(decoded.id)),"result":{"contents":{"kind":"markdown","value":"let x: Int"}}}"#
                    .utf8), via: scripted.server)

        let answer = try #require(await answerCall)
        #expect(answer.state == .ready)
        let candidate = try #require(answer.candidates.first)
        #expect(answer.candidates.count == 1)
        #expect(candidate.kindLabel == "hover")
        #expect(candidate.previewLine == "let x: Int")
        #expect(candidate.range == NSRange(location: 4, length: 0))
    }
}

// MARK: - symbolName is display-only

@Test("a bogus symbolName does not change the position-resolved result")
func symbolNameIgnoredForResolution() async throws {
    try await withTemporaryDirectory { root in
        let aText = "let x = 1\nfoo()\n"
        let aURL = root.appending(path: "a.swift")
        try write(aText, to: aURL)

        let scripted = try await makeReadySession(rootURI: fileURI(forPath: root.path))
        let session = scripted.session
        try await openDocument(aURL, text: aText, on: scripted)

        let provider = LSPNavigationProvider(rootURL: root) { _ in session }
        let request = NavigationRequest(
            documentURL: aURL, position: 4, languageID: "swift", kind: .definition,
            symbolName: "totally-bogus-name")

        async let answerCall = provider.answer(request)
        let decoded = try JSONDecoder().decode(
            DecodedRequest<TextDocumentPositionParams>.self,
            from: await scripted.reader.nextFrame())
        // Resolution is by position, unaffected by symbolName.
        #expect(decoded.params.position == Position(line: 0, character: 4))

        let targetRange = LSPRange(
            start: Position(line: 1, character: 0), end: Position(line: 1, character: 3))
        let location = Location(uri: fileURI(forPath: aURL.path), range: targetRange)
        try await serverSend(
            JSONEncoder().encode(ResultResponse(id: decoded.id, result: location)),
            via: scripted.server)

        let answer = try #require(await answerCall)
        let candidate = try #require(answer.candidates.first)
        #expect(candidate.range == expectedUTF16Range(targetRange, in: aText))
        #expect(candidate.name == "totally-bogus-name")  // echoed for display only
    }
}
