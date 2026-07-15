import Foundation
import Testing

@testable import RafuApp

// MARK: - Test doubles
//
// A reduced copy of `LanguageServerManagerTests.swift`'s scripted-server
// apparatus — just enough to observe what the coordinator forwards through
// a live manager into a real (in-memory) LSP session. Each test file keeps
// its own private copy rather than sharing one across files.

private struct RecordedChange: Equatable {
    let uri: String
    let text: String
}

private actor TestServerHandle {
    private(set) var didOpenURIs: [String] = []
    private(set) var didChangeCalls: [RecordedChange] = []
    private var terminationContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasTerminated = false

    func recordDidOpen(uri: String) {
        didOpenURIs.append(uri)
    }

    func recordDidChange(uri: String, text: String) {
        didChangeCalls.append(RecordedChange(uri: uri, text: text))
    }

    func awaitTermination() async {
        if hasTerminated { return }
        await withCheckedContinuation { continuation in
            terminationContinuations.append(continuation)
        }
    }

    /// Resolves `awaitTermination()`. Idempotent — safe to call once the
    /// scripted server's transport ends for any reason.
    func terminate() {
        guard !hasTerminated else { return }
        hasTerminated = true
        let continuations = terminationContinuations
        terminationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class ScriptedServerReader {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private var decoder = JSONRPCFrameDecoder()
    private var pendingBodies: [Data] = []

    init(stream: AsyncThrowingStream<Data, any Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func nextFrame() async throws -> Data {
        while pendingBodies.isEmpty {
            guard let chunk = try await iterator.next() else {
                throw ScriptedServerReaderError.transportEnded
            }
            pendingBodies.append(contentsOf: try decoder.consume(chunk))
        }
        return pendingBodies.removeFirst()
    }
}

private enum ScriptedServerReaderError: Error, Equatable {
    case transportEnded
}

private func idFragment(_ id: JSONRPCID) -> String {
    switch id {
    case .number(let value): return String(value)
    case .string(let value): return "\"\(value)\""
    }
}

private func extractURI(from params: JSONValue?) -> String? {
    guard case .object(let root)? = params,
        case .object(let textDocument)? = root["textDocument"],
        case .string(let uri)? = textDocument["uri"]
    else { return nil }
    return uri
}

private func extractDidChange(from params: JSONValue?) -> (uri: String, text: String)? {
    guard case .object(let root)? = params,
        case .object(let textDocument)? = root["textDocument"],
        case .string(let uri)? = textDocument["uri"],
        case .array(let changes)? = root["contentChanges"],
        case .object(let change)? = changes.first,
        case .string(let text)? = change["text"]
    else { return nil }
    return (uri, text)
}

private func runScriptedServer(server: InMemoryLanguageServerTransport, handle: TestServerHandle)
    async
{
    let reader = ScriptedServerReader(stream: await server.receive())
    while true {
        guard let body = try? await reader.nextFrame() else { break }
        guard let message = try? JSONRPCIncomingMessage.classify(body) else { continue }
        switch message {
        case .request(let request) where request.method == "initialize":
            let responseBody = Data(
                #"{"jsonrpc":"2.0","id":\#(idFragment(request.id)),"result":{"capabilities":{}}}"#
                    .utf8)
            try? await server.send(JSONRPCFrameEncoder.encode(body: responseBody))
        case .request(let request) where request.method == "shutdown":
            let responseBody = Data(
                #"{"jsonrpc":"2.0","id":\#(idFragment(request.id)),"result":null}"#.utf8)
            try? await server.send(JSONRPCFrameEncoder.encode(body: responseBody))
        case .notification(let notification) where notification.method == "textDocument/didOpen":
            if let uri = extractURI(from: notification.params) {
                await handle.recordDidOpen(uri: uri)
            }
        case .notification(let notification)
        where notification.method == "textDocument/didChange":
            if let change = extractDidChange(from: notification.params) {
                await handle.recordDidChange(uri: change.uri, text: change.text)
            }
        default:
            break
        }
    }
    // The transport ended — matches what a real process exiting looks
    // like from `SpawnedLanguageServer.awaitTermination()`'s perspective.
    await handle.terminate()
}

/// One scripted session per languageID (keyed by `serverName`, which every
/// test sets equal to its languageID).
private actor TestLanguageServerSpawner: LanguageServerSpawning {
    private(set) var spawnCount = 0
    private var handlesByServerName: [String: TestServerHandle] = [:]

    func handle(serverName: String) -> TestServerHandle? {
        handlesByServerName[serverName]
    }

    func spawn(resolved: ResolvedLanguageServer, rootURI: String) async throws
        -> SpawnedLanguageServer
    {
        spawnCount += 1
        let (client, server) = InMemoryLanguageServerTransport.makePair()
        let connection = JSONRPCConnection(transport: client)
        let session = LanguageServerSession(
            connection: connection, serverName: resolved.serverName, rootURI: rootURI,
            initializationOptions: nil)
        let handle = TestServerHandle()
        Task { await runScriptedServer(server: server, handle: handle) }
        try await session.initialize()
        handlesByServerName[resolved.serverName] = handle
        return SpawnedLanguageServer(
            session: session, pid: nil,
            awaitTermination: { await handle.awaitTermination() })
    }
}

private struct TestLanguageServerResolver: LanguageServerResolving {
    let entries: [String: ResolvedLanguageServer]

    func resolve(languageID: String) -> ResolvedLanguageServer? {
        entries[languageID]
    }
}

private func makeResolvedServer(languageID: String) -> ResolvedLanguageServer {
    ResolvedLanguageServer(
        serverName: languageID,
        launch: LanguageServerLaunchSpecification(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: nil,
            currentDirectoryURL: nil),
        initializationOptions: nil,
        rssCeilingBytes: nil
    )
}

private func waitUntil(
    timeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(5),
    _ predicate: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await predicate()
}

/// `workspaceDidOpen(root:)` activates the manager via an independent,
/// fire-and-forget `Task` (the frozen hook is non-async), so nothing
/// guarantees it has run yet by the time a test calls
/// `session(forLanguageID:)` immediately afterward. Retries until the
/// manager has caught up (or a real-time budget is exhausted).
@MainActor
private func waitForSession(
    coordinator: LanguageIntelligenceCoordinator, languageID: String
) async -> LanguageServerSession? {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if let session = await coordinator.session(forLanguageID: languageID) {
            return session
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await coordinator.session(forLanguageID: languageID)
}

// MARK: - Tests

@Test("An editDeltas subscription forwards the current text and correct file:// uri")
@MainActor
func editDeltaForwardsCurrentTextAndURI() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let manager = LanguageServerManager(resolver: resolver, spawner: spawner)
    let coordinator = LanguageIntelligenceCoordinator(
        manager: manager, servers: LanguageServerStatusStore())

    coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

    // Pre-warm a live session *before* opening the document, so the
    // manager already has somewhere to forward `didOpen` to directly
    // (rather than through a lazy-start replay, which needs a real
    // `snapshotProvider` this test doesn't configure).
    let session = await waitForSession(coordinator: coordinator, languageID: "swift")
    #expect(session != nil)

    let documentURL = URL(fileURLWithPath: "/workspace/main.swift")
    let document = EditorDocument(url: documentURL)
    var currentText = "let value = 1"
    document.textSnapshotProvider = { currentText }
    coordinator.documentDidOpen(document)

    // `documentDidOpen` starts the `editDeltas()` subscription task
    // independently (it's non-async); give it a real chance to register
    // its continuation before recording a delta, or the delta is lost
    // before anything is listening.
    try? await Task.sleep(for: .milliseconds(20))

    currentText = "let value = 2"
    document.recordEditDelta(editedRange: NSRange(location: 12, length: 1), changeInLength: 0)

    let expectedURI = fileURI(forPath: documentURL.path)
    let forwarded = await waitUntil {
        guard let handle = await spawner.handle(serverName: "swift") else { return false }
        return await handle.didChangeCalls.contains(
            RecordedChange(uri: expectedURI, text: "let value = 2"))
    }
    #expect(forwarded)

    coordinator.documentDidClose(document)
}

@Test("documentDidClose cancels the delta subscription; later deltas are never forwarded")
@MainActor
func documentDidCloseCancelsSubscription() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let manager = LanguageServerManager(resolver: resolver, spawner: spawner)
    let coordinator = LanguageIntelligenceCoordinator(
        manager: manager, servers: LanguageServerStatusStore())

    coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

    let documentURL = URL(fileURLWithPath: "/workspace/main.swift")
    let document = EditorDocument(url: documentURL)
    var currentText = "one"
    document.textSnapshotProvider = { currentText }
    coordinator.documentDidOpen(document)

    _ = await waitForSession(coordinator: coordinator, languageID: "swift")
    coordinator.documentDidClose(document)

    currentText = "two"
    document.recordEditDelta(editedRange: NSRange(location: 0, length: 3), changeInLength: 0)

    // Give any (incorrectly still-alive) subscription a real chance to
    // forward before asserting it never did.
    try? await Task.sleep(for: .milliseconds(100))
    let calls = await spawner.handle(serverName: "swift")?.didChangeCalls ?? []
    #expect(calls.isEmpty)
}

@Test("A document with an unrecognized extension is never subscribed or forwarded to the manager")
@MainActor
func unknownExtensionDocumentNeverSubscribed() async {
    let spawner = TestLanguageServerSpawner()
    let manager = LanguageServerManager(
        resolver: TestLanguageServerResolver(entries: [:]), spawner: spawner)
    let servers = LanguageServerStatusStore()
    let coordinator = LanguageIntelligenceCoordinator(manager: manager, servers: servers)

    coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

    let document = EditorDocument(url: URL(fileURLWithPath: "/workspace/notes.txt"))
    document.textSnapshotProvider = { "hello" }
    coordinator.documentDidOpen(document)
    document.recordEditDelta(editedRange: NSRange(location: 0, length: 5), changeInLength: 0)
    coordinator.documentDidClose(document)

    try? await Task.sleep(for: .milliseconds(50))
    #expect(servers.statuses.isEmpty)
    #expect(await spawner.spawnCount == 0)
}
