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
    private(set) var didOpenCalls: [RecordedChange] = []
    private(set) var didChangeCalls: [RecordedChange] = []
    private var terminationContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasTerminated = false

    func recordDidOpen(uri: String, text: String) {
        didOpenURIs.append(uri)
        didOpenCalls.append(RecordedChange(uri: uri, text: text))
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

private func extractDidOpen(from params: JSONValue?) -> (uri: String, text: String)? {
    guard case .object(let root)? = params,
        case .object(let textDocument)? = root["textDocument"],
        case .string(let uri)? = textDocument["uri"],
        case .string(let text)? = textDocument["text"]
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
            if let opened = extractDidOpen(from: notification.params) {
                await handle.recordDidOpen(uri: opened.uri, text: opened.text)
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
    let servers = LanguageServerStatusStore()
    // B2's edit-forwarding gate reads `servers.statuses[languageID]`
    // before copying any text, so this test's manager must actually push
    // its status into the same store the coordinator reads through — a
    // real `LanguageIntelligenceCoordinator` wires this in `init()`, but
    // the test-seam initializer takes an already-built `manager` and
    // can't retrofit that wiring after the fact.
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner,
        statusSink: { status in servers.update(status) })
    let coordinator = LanguageIntelligenceCoordinator(manager: manager, servers: servers)

    coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

    // Pre-warm a live session *before* opening the document, so the
    // manager already has somewhere to forward `didOpen` to directly
    // (rather than through a lazy-start replay, which needs a real
    // `snapshotProvider` this test doesn't configure).
    let session = await waitForSession(coordinator: coordinator, languageID: "swift")
    #expect(session != nil)
    let statusReady = await waitUntil { servers.statuses["swift"]?.phase == .ready }
    #expect(statusReady)

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

@Test(
    "documentDidOpen reads disk text off-main when the editor hasn't mounted a snapshot provider yet"
)
@MainActor
func documentDidOpenReadsDiskTextWhenProviderIsNil() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "rafu-language-intel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documentURL = root.appending(path: "main.swift")
    let diskContents = "let value = 42\n"
    try Data(diskContents.utf8).write(to: documentURL)

    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let servers = LanguageServerStatusStore()
    // See `editDeltaForwardsCurrentTextAndURI`: wired so B2's gate sees a
    // live status once the pre-warmed session is up.
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner,
        statusSink: { status in servers.update(status) })
    let coordinator = LanguageIntelligenceCoordinator(manager: manager, servers: servers)

    coordinator.workspaceDidOpen(root: root)

    // Pre-warm a live session before opening the document, exactly like
    // `editDeltaForwardsCurrentTextAndURI`, so `didOpen` is delivered
    // directly rather than through a lazy-start replay.
    let session = await waitForSession(coordinator: coordinator, languageID: "swift")
    #expect(session != nil)
    let statusReady = await waitUntil { servers.statuses["swift"]?.phase == .ready }
    #expect(statusReady)

    // The editor has not mounted for this document: `textSnapshotProvider`
    // stays `nil`, matching `WorkspaceSession.trackNewDocument`'s ordering.
    let document = EditorDocument(url: documentURL)
    #expect(document.textSnapshotProvider == nil)
    coordinator.documentDidOpen(document)

    let expectedURI = fileURI(forPath: documentURL.path)
    let recorded = await waitUntil {
        guard let handle = await spawner.handle(serverName: "swift") else { return false }
        return await handle.didOpenCalls.contains(
            RecordedChange(uri: expectedURI, text: diskContents))
    }
    #expect(recorded)

    coordinator.documentDidClose(document)
}

@Test(
    "restartServer clears the stale status row synchronously, then tears down and eagerly re-establishes a live session"
)
@MainActor
func restartServerClearsStaleRowAndReestablishesSession() async {
    let spawner = TestLanguageServerSpawner()
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let servers = LanguageServerStatusStore()
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner,
        statusSink: { status in servers.update(status) })
    let coordinator = LanguageIntelligenceCoordinator(manager: manager, servers: servers)

    coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))
    let session = await waitForSession(coordinator: coordinator, languageID: "swift")
    #expect(session != nil)
    let becameReady = await waitUntil { servers.statuses["swift"]?.phase == .ready }
    #expect(becameReady)
    #expect(await spawner.spawnCount == 1)

    coordinator.restartServer(languageID: "swift")
    // `servers.remove` runs synchronously in `restartServer`, before the
    // teardown/eager-restart `Task` is even scheduled — the stale row
    // must already be gone the instant this call returns.
    #expect(servers.statuses["swift"] == nil)

    let respawned = await waitUntil { (await spawner.spawnCount) == 2 }
    #expect(respawned)
    let readyAgain = await waitUntil { servers.statuses["swift"]?.phase == .ready }
    #expect(readyAgain)
}

@Test(
    "An editDeltas subscription skips forwarding entirely when no status has ever been published for the languageID — no full-buffer copy, no spawn"
)
@MainActor
func editDeltaSkipsForwardingWithNoLiveOrStartingServer() async {
    let spawner = TestLanguageServerSpawner()
    // "swift" resolves to a real server descriptor — this is not an
    // unrecognized-extension case (that path is covered by
    // `unknownExtensionDocumentNeverSubscribed`) — but nothing in this
    // test ever calls `ensureSession`/`session(forLanguageID:)`, so no
    // status is ever pushed and the store stays empty for it.
    let resolver = TestLanguageServerResolver(entries: [
        "swift": makeResolvedServer(languageID: "swift")
    ])
    let servers = LanguageServerStatusStore()
    let manager = LanguageServerManager(
        resolver: resolver, spawner: spawner,
        statusSink: { status in servers.update(status) })
    let coordinator = LanguageIntelligenceCoordinator(manager: manager, servers: servers)

    coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))
    #expect(servers.statuses["swift"] == nil)

    let documentURL = URL(fileURLWithPath: "/workspace/main.swift")
    let document = EditorDocument(url: documentURL)
    var currentText = "let value = 1"
    document.textSnapshotProvider = { currentText }
    coordinator.documentDidOpen(document)

    try? await Task.sleep(for: .milliseconds(20))
    currentText = "let value = 2"
    document.recordEditDelta(editedRange: NSRange(location: 12, length: 1), changeInLength: 0)

    // Give a (incorrectly) forwarding subscription a real chance to reach
    // the manager before asserting it never did.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await spawner.spawnCount == 0)
    #expect(await spawner.handle(serverName: "swift") == nil)

    coordinator.documentDidClose(document)
}
