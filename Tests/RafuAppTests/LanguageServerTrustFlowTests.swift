import Foundation
import Testing

@testable import RafuApp

// MARK: - Test doubles
//
// A reduced copy of `LanguageIntelligenceCoordinatorTests.swift`'s scripted
// -server apparatus — just enough to complete a real `initialize`/`shutdown`
// handshake over `InMemoryLanguageServerTransport`, so `ensureSession`
// actually returns a live session once `InstalledServerResolver` resolves.
// Each test file keeps its own private copy rather than sharing one across
// files (matching that file's own convention).

private actor TestServerHandle {
    private var terminationContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasTerminated = false

    func awaitTermination() async {
        if hasTerminated { return }
        await withCheckedContinuation { continuation in
            terminationContinuations.append(continuation)
        }
    }

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

/// Answers `initialize` and `shutdown` only — enough for
/// `LanguageServerSession.initialize()`/`shutdown()` to complete, without
/// caring about document sync or navigation.
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
        default:
            break
        }
    }
    await handle.terminate()
}

private actor TestLanguageServerSpawner: LanguageServerSpawning {
    func spawn(resolved: ResolvedLanguageServer, rootURI: String) async throws
        -> SpawnedLanguageServer
    {
        let (client, server) = InMemoryLanguageServerTransport.makePair()
        let connection = JSONRPCConnection(transport: client)
        let session = LanguageServerSession(
            connection: connection, serverName: resolved.serverName, rootURI: rootURI,
            initializationOptions: nil)
        let handle = TestServerHandle()
        Task { await runScriptedServer(server: server, handle: handle) }
        try await session.initialize()
        return SpawnedLanguageServer(
            session: session, pid: nil,
            awaitTermination: { await handle.awaitTermination() })
    }
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

/// Places an executable fixture exactly where `InstallLayout` /
/// `CuratedCatalog`'s "marksman" entry expects an installed binary, so
/// `InstalledServerResolver.resolve(languageID: "markdown")` succeeds the
/// instant it's also trusted.
private func installFixtureMarksman(layout: InstallLayout) throws {
    let binaryURL = layout.serverDirectory(id: "marksman").appending(path: "marksman")
    try FileManager.default.createDirectory(
        at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho marksman\n".utf8).write(to: binaryURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
}

@MainActor
private func makeCoordinator(
    trustDirectory: URL, userEntryDirectory: URL, layoutDirectory: URL
) -> LanguageIntelligenceCoordinator {
    let box = LanguageServerResolverBox()
    let manager = LanguageServerManager(
        resolver: DynamicLanguageServerResolver(box: box), spawner: TestLanguageServerSpawner())
    return LanguageIntelligenceCoordinator(
        manager: manager,
        servers: LanguageServerStatusStore(),
        resolverBox: box,
        trustStore: WorkspaceTrustStore(baseDirectory: trustDirectory),
        userEntryStore: UserEntryStore(baseDirectory: userEntryDirectory),
        layout: InstallLayout(baseDirectory: layoutDirectory)
    )
}

// MARK: - Tests

@Suite("Language server trust flow")
struct LanguageServerTrustFlowTests {
    @Test(
        "An installed but untrusted server declines and raises a pending trust request"
    )
    func untrustedServerDeclinesAndRaisesPendingRequest() async throws {
        try await withTemporaryDirectory { trustDirectory in
            try await withTemporaryDirectory { userEntryDirectory in
                try await withTemporaryDirectory { layoutDirectory in
                    let layout = InstallLayout(baseDirectory: layoutDirectory)
                    try installFixtureMarksman(layout: layout)

                    let coordinator = await makeCoordinator(
                        trustDirectory: trustDirectory, userEntryDirectory: userEntryDirectory,
                        layoutDirectory: layoutDirectory)
                    await coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

                    let session = await coordinator.session(forLanguageID: "markdown")
                    #expect(session == nil)

                    let raised = await waitUntil {
                        coordinator.pendingTrustRequest?.serverID == "marksman"
                    }
                    #expect(raised)
                    let pending = await coordinator.pendingTrustRequest
                    #expect(pending?.languageID == "markdown")
                }
            }
        }
    }

    @Test("approveTrust persists approval, clears the pending request, and resolves")
    func approveTrustResolves() async throws {
        try await withTemporaryDirectory { trustDirectory in
            try await withTemporaryDirectory { userEntryDirectory in
                try await withTemporaryDirectory { layoutDirectory in
                    let layout = InstallLayout(baseDirectory: layoutDirectory)
                    try installFixtureMarksman(layout: layout)

                    let coordinator = await makeCoordinator(
                        trustDirectory: trustDirectory, userEntryDirectory: userEntryDirectory,
                        layoutDirectory: layoutDirectory)
                    await coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

                    _ = await coordinator.session(forLanguageID: "markdown")
                    let raised = await waitUntil {
                        coordinator.pendingTrustRequest?.serverID == "marksman"
                    }
                    #expect(raised)

                    let request = try #require(await coordinator.pendingTrustRequest)
                    await coordinator.approveTrust(request)
                    let pendingAfterApprove = await coordinator.pendingTrustRequest
                    #expect(pendingAfterApprove == nil)

                    let resolvedSession = await waitUntil {
                        await coordinator.session(forLanguageID: "markdown") != nil
                    }
                    #expect(resolvedSession)

                    // Persisted for this workspace: a fresh store read agrees.
                    let trustFile = try await WorkspaceTrustStore(baseDirectory: trustDirectory)
                        .load()
                    #expect(
                        trustFile.approvals[
                            URL(fileURLWithPath: "/workspace").standardizedFileURL.path]?
                            .contains("marksman") == true)
                }
            }
        }
    }

    @Test("declineTrust is remembered: repeated session requests never re-raise a pending request")
    func declineTrustIsRemembered() async throws {
        try await withTemporaryDirectory { trustDirectory in
            try await withTemporaryDirectory { userEntryDirectory in
                try await withTemporaryDirectory { layoutDirectory in
                    let layout = InstallLayout(baseDirectory: layoutDirectory)
                    try installFixtureMarksman(layout: layout)

                    let coordinator = await makeCoordinator(
                        trustDirectory: trustDirectory, userEntryDirectory: userEntryDirectory,
                        layoutDirectory: layoutDirectory)
                    await coordinator.workspaceDidOpen(root: URL(fileURLWithPath: "/workspace"))

                    _ = await coordinator.session(forLanguageID: "markdown")
                    let raised = await waitUntil {
                        coordinator.pendingTrustRequest?.serverID == "marksman"
                    }
                    #expect(raised)

                    let request = try #require(await coordinator.pendingTrustRequest)
                    await coordinator.declineTrust(request)
                    let pendingAfterDecline = await coordinator.pendingTrustRequest
                    #expect(pendingAfterDecline == nil)

                    let session = await coordinator.session(forLanguageID: "markdown")
                    #expect(session == nil)
                    let pendingAfterSecondRequest = await coordinator.pendingTrustRequest
                    #expect(pendingAfterSecondRequest == nil)
                }
            }
        }
    }
}
